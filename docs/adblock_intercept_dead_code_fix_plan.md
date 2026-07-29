# Fix: Dead compliance-policy computation in `shouldInterceptRequestCallback`

| Field | Value |
|-------|-------|
| **Date** | 2026-07-25 |
| **Status** | Plan only (not implemented) |
| **Goal** | Remove wasted per-request work in the WebView resource-interception hot path (fires on every non-main-frame HTTP request, on every page, for every tab — active on Play builds specifically, since `RestrictedMediaPolicy.enforcementEnabled` is gated to `BuildChannel.isPlay`). No behavior change. |
| **Risk** | Very low — deleting unused locals, and converting a getter to a precomputed field with identical output. |
| **Files** | `lib/sniffer/browser_controller.dart`, `lib/compliance/restricted_media_policy.dart` |

---

## Background

`shouldInterceptRequestCallback` (`browser_controller.dart:743`) is wired via `useShouldInterceptRequest: true` (`browser_widget.dart:43`), so it runs on every subresource request (images, scripts, styles, XHR) on every page load, for every tab. Digging into it turned up a block of computation that runs on this hot path but whose result is never used — see finding below.

## Finding

**`browser_controller.dart:754-770`**, inside `shouldInterceptRequestCallback`:

```dart
if (_onHlsPlaylistIntercepted != null &&
    request.isForMainFrame != true &&
    request.method == 'GET') {
  final reqUrl = request.url.toString();
  final hardOff = RestrictedMediaPolicy.shouldHardOffSniffing(_currentUrl);
  final urlBlocked = RestrictedMediaPolicy.isBlocked(
    mediaUrl: reqUrl,
    sourcePageUrl: _currentUrl,
  );
  // HLS body capture removed — JS channel (browser_guard.js) fills
  // hlsPlaylistCache on every playlist fetch with live cookies, and the
  // enricher's 4-tier ladder (cache → WebView JS → Dart HTTP → headless)
  // handles everything else. The old native _captureHlsPlaylistBody had
  // no cookies and added a redundant GET for every m3u8.
}
```

`hardOff` and `urlBlocked` are computed and **never read**. The capture logic that used to consume them was already removed (per the comment), but the computation feeding it wasn't deleted alongside it.

This isn't free work: `isBlocked` → `evaluate` → `_matchesAnyRestriction` (`restricted_media_policy.dart:221`) runs `Uri.tryParse` on the media/page URLs, then loops over all 6 platform groups (YouTube, TikTok, Meta, Netflix, Spotify, Twitch), and for each group calls `group.allHosts` — a **getter that reallocates a new spread list on every call** (`[...surfaceHosts, ...mediaHosts]`, `restricted_media_policy.dart:355`), not a precomputed field. One wasted call costs up to 12 fresh list allocations plus suffix-matching loops, thrown away immediately.

`setOnHlsPlaylistIntercepted` is wired unconditionally for every tab (`tab_callback_binder.dart:504`), so `_onHlsPlaylistIntercepted != null` is always true — this isn't a rare edge case, it fires on effectively 100% of intercepted requests.

`RestrictedMediaPolicy.enforcementEnabled => BuildChannel.isPlay` (`restricted_media_policy.dart:38`) — on GitHub builds this short-circuits to a cheap no-op; on **Play builds** (the ones launching in a week on this branch) it runs at full cost.

---

## Step 1 — Delete dead computation in `shouldInterceptRequestCallback`

**File:** `lib/sniffer/browser_controller.dart:754-770`

Remove the whole `if (_onHlsPlaylistIntercepted != null && ...)` block shown above.

**Verify before deleting:** confirm no other side effect is hiding in that block (there isn't — `reqUrl`, `hardOff`, `urlBlocked` are all local, nothing escapes the block, nothing outside reads them).

---

## Step 2 — Precompute `allHosts` instead of reallocating on every call

**File:** `lib/compliance/restricted_media_policy.dart:344-356`

Current: `allHosts` is a getter that reallocates on every call — and it's called from the *other* real call sites too (`_matchesAnyGroup`, `_groupMatches`, used from `browser_controller.dart:1144/1148` and elsewhere), so fixing it helps beyond just Step 1.

```dart
class _PlatformGroup {
  final RestrictedMediaReason reason;
  final List<String> surfaceHosts;
  final List<String> mediaHosts;
  final List<String> allHosts; // precomputed, not a getter

  _PlatformGroup({
    required this.reason,
    required this.surfaceHosts,
    required this.mediaHosts,
  }) : allHosts = [...surfaceHosts, ...mediaHosts];
}
```

Note: this drops the `const` constructor (list spreads at construction time can't be `const`), so also drop `const` from the `_groups` list literal if it's currently declared `const [...]` (check around `restricted_media_policy.dart:43`). `_groups` is only built once at class-load, so losing `const` costs nothing at runtime — it's not on any hot path.

---

## Step 3 — Verify

1. `flutter analyze` — confirm no lints from removed unused locals or the constructor change.
2. Grep for any other reads of `_PlatformGroup.allHosts` to confirm the field vs. getter change preserves identical output.
3. Manual smoke test: load a page with several subresources (images/scripts) in the Play-channel debug build (`flutter build apk --debug --dart-define=AURORA_BUILD_CHANNEL=play`) and confirm ad-block/compliance behavior is unchanged (nothing should differ — this is pure dead-code removal).
4. Check `test/` for a `restricted_media_policy_test.dart` and rerun it to confirm the `allHosts` change doesn't alter matching results.

---

*End of plan.*
