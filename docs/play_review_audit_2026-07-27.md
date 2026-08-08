# Play Review Audit — Aurora Downloader (strict)

| Field | Value |
|-------|-------|
| **Date** | 2026-07-27 |
| **Branch** | `Play-Console-Launch` |
| **Version** | `2.4.5` / versionCode `29` (`android/local.properties`) |
| **Scope** | Code + Console declarations as they would be submitted today, judged against what actually gets rejected — not a general security review |
| **Verdict** | **No confirmed blockers.** One submission gate with a hard date (`targetSdk`), two policy-friction items worth fixing before first review, and some WebView security debt. |
| **Revision** | Rev 2 — findings 1, 2, 3 of rev 1 were **withdrawn as incorrect** after owner challenge. See §0. |

This audit deliberately looks for gaps *not already covered* by `play_store_compliance.md` and `play_console_app_content.md`. Those two docs are good on YouTube blocking, billing channel, storage, and listing copy — that ground is not re-litigated here.

---

## Summary table

| # | Finding | Severity | Type |
|---|---|---|---|
| ~~1~~ | ~~Data Safety declares Drive sync "cancelled"; the app ships it live~~ | **Withdrawn** | Auditor error — §0 |
| ~~2~~ | ~~Drive sync ships with no OAuth client ID → reviewer hits an error~~ | **Withdrawn** | Auditor error — §0 |
| ~~3~~ | ~~Foreground-service declaration + demo video not prepared~~ | **Withdrawn** | Already done in Console — §0 |
| 4 | `targetSdk` inherited from Flutter, not pinned | **High** | Submission gate |
| 5 | Battery-optimisation exemption prompted proactively at launch | **High** | Policy friction |
| 6 | 14 JS bridges on the untrusted WebView with no origin check | **High** | DNA / WebView security |
| 7 | `allowFileAccess` + `allowContentAccess` true on the browser WebView | **Medium** | DNA / WebView security |
| 8 | License server transmits `installId` — undeclared | **Medium** | Declaration accuracy (conditional) |
| 9 | Torrent/magnet intake in the Play build | **Medium** | Reviewer framing (judgement call) |
| 10 | Android 15 caps `dataSync` FGS at 6h/24h | **Medium** | Functional |
| 11 | `extractNativeLibs="true"` | **Low** | Size only |

---

## 0. Withdrawn findings (rev 1 errors)

### 0.1 Drive sync is correctly archived — findings 1 and 2 withdrawn

Rev 1 claimed the Data Safety declaration of "Drive sync cancelled" contradicted a live, reachable Drive feature. **That was wrong.** Drive sync is archived behind a single flag:

```dart
const bool kDriveSyncEnabled = false;   // lib/premium/premium_flags.dart:7
```

It gates every surface:

| Surface | Location |
|---|---|
| Settings nav item → `_buildDrivePage()` | `settings_page.dart:400` |
| Pro feature-list row | `settings_page.dart:2650` |
| About-page marketing copy | `settings_page.dart:2255` |

With the nav item gone, `_DriveSyncPageContent` (`settings_page.dart:2844`) **has no construction site anywhere in the tree** — it is dead code, so the Connect button rev 1 cited is unreachable.

The non-UI path is also inert. `_driveSyncService.attachQueue()` runs unconditionally at `main.dart:422`, but `syncCompletedTask` bails at `drive_sync_service.dart:482-484` unless `isConnected`, and `_status` only reaches `connected` via `connect()` (`:429-435`) whose sole caller is the dead page. `autoSyncEnabled` defaults `true` but cannot act without an authenticated client. **No sign-in occurs, no network request is made, no data leaves the device.**

So the Data Safety form and the reviewer note in `play_console_app_content.md` are **accurate as written**. Finding 2 (missing OAuth client ID) is moot for the same reason — unreachable code cannot present a broken button.

The flag's own doc comment also pre-empts rev 1's recommendation, and is the better design:

> *"Prefer the flag over scattering `BuildChannel.isPlay` checks."*

One flag beats a channel check per call site, and it is already documented as intentional in `docs/feature_wiring_and_implementation_status.md:71`.

**Residual note, not a finding:** the `google_sign_in` / `googleapis` dependencies and the Drive code still ship in the binary as dead weight. No policy impact — Play judges behaviour, not unreachable symbols — but if `kDriveSyncEnabled` stays `false` long-term, deleting the code and the four pubspec entries would cut binary size and remove the trap that caused this audit error.

### 0.3 Content-rating row was asserted, not checked — withdrawn 2026-07-28

The "Things that are correct" table claimed **18+, correctly not under-rated**.
The live listing reads **Rated for 3+**, interactive elements *Unrestricted
Internet, In-App Purchases*.

Two errors compounded:

1. **Console state was inferred from repo docs again** — the exact mistake rev 2
   recorded as its lesson. `play_console_app_content.md:145` specifies target
   age 18+, and this audit read that as the *content rating* and asserted it as
   verified fact.
2. **The prediction was wrong anyway.** IARC rates the app's **own** content, and
   a browser ships none. `Unrestricted Internet` is an *interactive element*
   descriptor, disclosed separately, and does not raise the age rating. Chrome,
   Firefox, Opera and Samsung Internet all carry Everyone/3+ with it. The live
   3+ is the correct, expected outcome — `play_console_app_content.md:137`'s
   "expect Teen or Mature 17+" is the line that was wrong.

**What still needs checking:** target audience is a *separate* Console section
and is not visible on the public listing. A 3+ rating plus a child-inclusive
target audience pulls the app into Families policy, which an unrestricted browser
cannot satisfy. Verify Policy → App content → Target audience reads 18+.

**Standing rule:** any row in this audit describing Console state must carry the
date it was checked in Console, or be marked unverified. Three of this audit's
errors now share one root cause.

### 0.2 Foreground-service declaration — finding 3 withdrawn

Owner confirms the FGS declaration is already filed in Play Console. Rev 1 inferred Console state from the absence of a section in `play_console_app_content.md`, which was not a valid inference. **Not a blocker.**

Worth doing anyway, as documentation hygiene only: add a §11 to that doc recording what was declared and the demo-video URL, so the next audit does not re-raise this. The Android 15 runtime cap on `dataSync` is a separate, still-open item — see finding 10.

---

## 4. `targetSdk` is inherited, not pinned — HIGH

```kotlin
compileSdk = 36
minSdk = 24
targetSdk = flutter.targetSdkVersion   // android/app/build.gradle.kts
```

`flutter.targetSdkVersion` resolves from whatever Flutter SDK is on the build machine (`D:\flutter`). Dart `^3.8.1` implies a Flutter ~3.32 vintage, whose default is API 35. That currently satisfies Play's API-35 floor for new submissions, but:

- The value silently changes with a Flutter upgrade — a property you do not want floating in a release build.
- Play raises the floor for **new** apps to API 36 on **31 Aug 2026**, roughly five weeks out. A first submission that slips past that date fails on a config line nobody re-read.

**Action:** pin `targetSdk = 36` explicitly and smoke-test. `compileSdk` is already 36, so the toolchain is in place.

---

## 5. Battery-optimisation exemption prompted at launch — HIGH

`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is declared, and `lib/main.dart:600-648` prompts for it **proactively after launch**, with `_showBatteryOptRequestDialog()` followed by the system dialog. `neverAskBatteryOpt` suppresses it, but the default path nags — and `main.dart:643` notes *"Next cold start may ask again (by design)."*

Google's position is that this permission is acceptable only where core functionality is genuinely incompatible with Doze. Aurora's downloads already run under a `dataSync` foreground service, which is the sanctioned mechanism — so the exemption is a reliability *nicety*, not a necessity, and proactive prompting for it is a recognised rejection trigger. Repeated prompting across cold starts makes it worse.

**Action:** in the Play channel, drop the launch-time prompt entirely and rely on the `BatteryOptimizationTile` that already exists at `lib/ui/pages/settings_page.dart:4146` — user-initiated, in context, no nag. Keep the current behaviour in the GitHub channel if you want it. Consider whether the permission is worth declaring at all for the Play build.

---

## 6. JS bridges on the untrusted WebView have no origin validation — HIGH

`lib/sniffer/controllers/tab_callback_binder.dart:301-471` registers **14 JavaScript channels** on the main browsing WebView — `MediaSnifferChannel`, `MediaSniffer`, `AdBlockerChannel`, `PopupBlockerChannel`, `InvisibleRedirectChannel`, `ElementPickerChannel`, `LinkContextChannel`, `AuroraPlayChannel`, `VideoFloatChannel`, `MediaMetaChannel`, `MediaSnifferDataChannel`, `PageMetaChannel`, `IframeSrcChannel`, `HlsPlaylistChannel`.

The dispatcher performs no origin check:

```dart
void _registerChannel(String name, void Function(String message) callback) {
  _controller?.addJavaScriptHandler(
    handlerName: name,
    callback: (args) {
      if (args.isNotEmpty) callback(args[0].toString());
    },
  );
}   // lib/sniffer/browser_controller.dart:1451-1460
```

Any page can invoke any handler via `window.flutter_inappwebview.callHandler(...)`. The sharpest edge is `IframeSrcChannel` → `_host.sniffIframeContent(tab, url)` (`:455-461`): a hostile page hands Aurora an arbitrary URL that the app then fetches **with the WebView's session context**. That is an SSRF-shaped primitive pointed at the user's LAN (`http://192.168.1.1/...`) and, given finding 7, at `file://`. `AuroraPlayChannel` lets a page drive the in-app player to an attacker-chosen URL.

Honest severity: this is not RCE, and downloads still require a user tap, so it is real security debt rather than a certain rejection. But Device and Network Abuse explicitly covers WebView security, and the Console pre-launch report runs automated security scans — this is the kind of thing that produces a warning that then has to be argued.

**Correction to rev 1's proposed fix.** Rev 1 said to "validate the caller's origin inside `_registerChannel`." That is not implementable and would not work:

- `flutter_inappwebview` 6.1.5 types the callback as `JavaScriptHandlerCallback(List<dynamic> arguments)` — **no origin, requestUrl, or isMainFrame is passed**. The bridge cannot tell who called it.
- Even with origin available it would be useless here: the hostile page *is* the current page, so an origin check against the current URL always passes.

**Implemented instead — payload validation** (`lib/sniffer/bridge_url_guard.dart`, 15 unit tests in `test/sniffer/bridge_url_guard_test.dart`):

`isAllowedBridgeUrl(url, pageUrl:)` now gates `MediaSnifferChannel`, `MediaSniffer`, and `IframeSrcChannel`. It rejects any scheme other than `http`/`https` (killing `file:`, `content:`, `data:`, `blob:`, `javascript:`, `intent:`) and applies a **relational** private-network rule: a private/loopback/link-local target is allowed only when the requesting page is itself on a private host. That blocks the remote-page → LAN pivot (`192.168.1.1/admin`, `169.254.169.254` metadata, `127.0.0.1:8080` — which is the Automation API's own port) while preserving legitimate LAN browsing, e.g. sniffing a Jellyfin server at `192.168.1.50`.

**Still open:** `AuroraPlayChannel`, `MediaMetaChannel`, `MediaSnifferDataChannel`, `HlsPlaylistChannel`, and `PageMetaChannel` carry JSON payloads rather than bare URLs, so the guard does not yet cover the URLs nested inside them. Applying it there means threading validation through `_decodeJsInBackground` consumers — a follow-up, deliberately not half-done here.

---

## 7. Over-permissive WebView settings — MEDIUM

```dart
allowFileAccess: true,
allowContentAccess: true,   // lib/sniffer/browser_widget.dart:45-46
```

This is the general-purpose browser rendering arbitrary untrusted pages. `allowFileAccess: true` lets a page navigate to and render `file://` URLs; `allowContentAccess: true` extends that to `content://`. The genuinely catastrophic pair (`allowFileAccessFromFileURLs`, `allowUniversalAccessFromFileURLs`) is correctly left at default false, which caps the damage — but neither flag has a justification for a web browser, and both amplify finding 6.

**Action:** set both to `false` on the browsing WebView. If some local-file feature depends on them, isolate that in a separate WebView instance rather than the one loading the open web.

---

## 8. License server transmits `installId` — MEDIUM, conditional

`lib/premium/license/license_api_client.dart:96-117` POSTs `packageName`, `installId`, and Play `purchaseToken`s to the license host. A persistent per-install identifier leaving the device is **"Device or other IDs" — collected**, and the purchase token is purchase history. `play_console_app_content.md` §7 currently says only *"Advertising ID: No. Purchase token handled by Play"* — which understates it.

This is **conditional**: `LicenseConfig.isEnabled` requires `BuildChannel.isPlay` **and** a non-empty `AURORA_LICENSE_URL` **and** at least one compiled trusted key, and `_bakedKeys` is currently an empty list (`license_config.dart:76-78`). So a build today transmits nothing and the present declaration is defensible.

**Action:** if `AURORA_LICENSE_URL` is set for this submission, update Data Safety to declare Device-or-other-IDs collection and add a deletion path (the server holds records keyed by `installId`, which is a deletion obligation). If not set, leave as-is and add a note to the doc so this is not forgotten at the release that enables it. The `toString()` redaction at `license_api_client.dart:30-31` is the right instinct — keep it.

---

## 9. Torrent/magnet intake in the Play build — MEDIUM, judgement call

`libtorrent_flutter` ships in the Play AAB with magnet-link intake. Nothing in Play policy prohibits BitTorrent clients, and plenty exist on the Store.

**Verified 2026-07-28 — Aurora is on the safe side of the enforceable line.** What
Play's IP policy actually reaches is apps that *surface* infringing content:
built-in search over torrent indexes, curated lists, bundled site shortcuts.
`lib/downloader/magnet_link.dart` and `torrent_downloader.dart` are transport
only — a grep for indexer and known-site patterns across `lib/` returns nothing.
The user brings their own magnet link.

Note too that omitting torrent from store assets does not conceal it from review
— the reviewer installs and uses the app. Screenshot framing is a marketing
choice, not risk mitigation; `play_store_listing.md` was corrected accordingly.

The risk is **framing, not a rule.** A human reviewer assessing an app that combines (a) a media sniffer that strips video off arbitrary sites, (b) a torrent client, and (c) an ad blocker, is being handed a mental model of a piracy toolkit — and Intellectual Property enforcement is discretionary. `play_store_compliance.md` §3 already identifies "clear product framing" as the goal; torrent support is the feature most in tension with it.

**Action:** a decision to make deliberately rather than by default. Gating magnet/torrent out of the Play channel — same one-line `BuildChannel.isPlay` pattern — measurably lowers first-review risk while the GitHub build keeps full capability. If you keep it, ensure no screenshot or listing line pairs "torrent" with "video download."

---

## 10. `dataSync` FGS is time-capped on Android 15 — MEDIUM, functional

Android 15 limits `dataSync` foreground services to roughly 6 hours in any 24-hour window, after which the system stops the service. For a download manager on a slow connection or a large torrent, that is a real truncation, not a theoretical one. Not a policy problem — a user-visible reliability one, and the actual reason the battery-optimisation prompt in finding 5 exists.

**Action:** verify behaviour on an Android 15/16 device with a deliberately long download. Handle the stop gracefully — persist progress and surface a resumable state rather than failing the task. This is also the honest justification text for the finding 3 declaration.

---

## 11. `extractNativeLibs="true"` — LOW

`AndroidManifest.xml:17`. Increases installed size and download size versus letting the platform map libraries from the APK. No policy impact; worth flipping to `false` unless something depends on extracted `.so` paths — check the `libaurora_adblock.so` and FFmpeg module loaders before changing.

---

## Things that are correct — do not "fix" these

| Area | Why it is right |
|---|---|
| Drive feature archival | Single `kDriveSyncEnabled` flag gating all three surfaces, documented as intentional, with the dead page left un-instantiated. Cleaner than per-call-site channel checks — see §0.1 |
| Drive OAuth scope | `drive.DriveApi.driveFileScope` (`drive_sync_service.dart:145`) is `drive.file` — non-sensitive, no CASA assessment, no OAuth verification burden. The expensive full-`drive` scope was correctly avoided. Relevant if the flag is ever flipped back on |
| License server model | Server-side verification of **Play** purchases, gated on `BuildChannel.isPlay` (`license_config.dart:102`) — legitimate entitlement hardening, not an alternative purchase path. No Payments violation |
| Restricted media policy | Six platform groups with surface + CDN + Referer + Origin matching, channel-gated. Ahead of `play_store_compliance.md`, which still describes it as YouTube-only — **that doc is stale, the code is fine** |
| Storage | No `MANAGE_EXTERNAL_STORAGE`; `WRITE_EXTERNAL_STORAGE` capped at `maxSdkVersion="28"`; MediaStore writes |
| Package visibility | Explicit `<queries>` entries, no `QUERY_ALL_PACKAGES` |
| Automation API | Loopback-only, Ultra-gated, default off, hashed token in secure storage |
| LAN file server | Binds the specific LAN IPv4 rather than `0.0.0.0`, single-use tokens, absolute TTL |
| ~~Content rating / target audience~~ | ~~18+, unrestricted-web = Yes, no Families enrolment. Correctly not under-rated~~ — **withdrawn 2026-07-28, see §0.3** |
| Ads declaration | In-app ad *blocking* correctly not declared as containing ads |

---

## Ordered pre-submission checklist

**Blockers**

*None confirmed. Rev 1's three blockers were withdrawn — see §0.*

**Pre-existing build blocker — resolved 2026-07-27**

0. ~~`external_app_prompt_sheet.dart` instantiates `ExternalAppsPrefsPage`, which existed nowhere~~ — **fixed by finishing the feature.** Everything else was already wired (overflow-menu entry, `SettingsSection.externalApps`, the prompt sheet, and `ExternalAppPreferenceStore` with `allDecisions`/`setDecision`/`clearAll`); only the page was missing. Added `ExternalAppsPrefsPage` to `settings_page.dart`, replaced the `SettingsSection.externalApps` "Coming soon." stub, and added `externalAppDisplayNameForKey` / `externalAppSubtitleForKey` to the store so the settings UI can label persisted keys without duplicating the label maps. 6 widget tests in `test/ui/external_apps_prefs_page_test.dart`. **`flutter analyze` is now error-free.**

**High — done 2026-07-27**

1. ~~Pin `targetSdk = 36`~~ — **done**, `android/app/build.gradle.kts`, with the 31 Aug 2026 rationale in a comment
2. ~~Remove the launch-time battery-optimisation prompt in the Play channel~~ — **done**, `BuildChannel.isPlay` early return in `_promptBatteryOptIfNeeded`; the settings tile remains the on-demand path
3. ~~Harden the JS bridge~~ — **done** via payload validation, not origin validation (see finding 6 for why the original plan was wrong)
4. ~~Set `allowFileAccess: false`, `allowContentAccess: false`~~ — **done**, `browser_widget.dart`

**Medium — open**

5. Decide torrent-in-Play deliberately; record the decision
6. Confirm `AURORA_LICENSE_URL` state for this build; update Data Safety if set
7. Test a >6h download on Android 15/16; handle FGS stop gracefully
8. Documentation only: record the filed FGS declaration in `play_console_app_content.md` §11
9. Extend `isAllowedBridgeUrl` to the JSON-payload channels (finding 6, "still open")

**Then the items `play_store_compliance.md` already lists**

9. Live privacy policy URL (`docs/privacy.html` + `.nojekyll` suggests Pages is ready — publish and verify in incognito)
10. Replace `YOUR_EMAIL` throughout the privacy policy
11. Activate IAP `aurora_pro_unlock`; internal-test purchase + restore
12. Screenshots with no branded platforms
13. Refresh the stale "Other locked platforms — Not solved" verdict row in `play_store_compliance.md`

---

## Revision history

| Rev | Date | Change |
|---|---|---|
| 1 | 2026-07-27 | Initial audit. Claimed three blockers |
| 2 | 2026-07-27 | Findings 1, 2, 3 withdrawn after owner challenge — Drive is flag-archived (`kDriveSyncEnabled`), FGS already declared in Console. Verdict changed to no confirmed blockers. Lesson: check for feature flags and dead-code archival before asserting a surface is reachable; do not infer Console state from repo docs |
| 4 | 2026-07-28 | Content-rating row withdrawn (§0.3) after the live listing showed **3+**, not 18+ — Console state inferred from repo docs for the third time. Finding 9 reframed: torrent is **not** a policy violation and Aurora is transport-only (no search/indexer), verified in `magnet_link.dart` / `torrent_downloader.dart`; residual risk is reviewer gestalt. New standing rule: Console-state claims carry a checked-in-Console date or are marked unverified |
| 3 | 2026-07-27 | Findings 4, 5, 6, 7 fixed. Finding 6's remedy corrected: origin validation is impossible on `flutter_inappwebview` 6.1.5 and would not have helped — replaced with payload validation in `bridge_url_guard.dart`. Dead Drive code removed entirely (4 packages, 11 transitive deps). Recorded the pre-existing `ExternalAppsPrefsPage` build blocker |
| 5 | 2026-08-08 | **Status note — rev 2's "Drive is flag-archived" is historical, not current.** `kDriveSyncEnabled` was flipped back to `true` in commit d2584a2 (2026-08-02) after GCP OAuth verification; Drive sync is live again (`lib/sync/drive_sync_service.dart` wired at `lib/main.dart:363`, `google_sign_in` back in pubspec). The 2026-07-27 archival conclusion was correct at the time — it became stale on 08-02. See `play_store_listing.md` and `play_console_app_content.md` (2026-08-08 revisions) for the current state |

---

## Verification run (rev 3)

| Check | Result |
|---|---|
| `flutter test` | **204 passed** (183 baseline + 15 bridge-guard + 6 external-apps) |
| `flutter analyze` — error level | **0 errors** |
| `flutter analyze` — total issues | 313, all info/warning. Net +1 vs the 312 baseline: −1 error resolved, +2 `depend_on_referenced_packages` infos from the new test's `path_provider_platform_interface` / `plugin_platform_interface` imports — the same lint the existing `test/onboarding_experiment_test.dart` already carries |
| `flutter build` | **Still not run** — no device/emulator in this environment. The `targetSdk 36` bump is compile-verified only |

`PUB_CACHE` was pointing at `E:\DevTools\PubCache` on an unmounted drive. Moved to `D:\DevTools\PubCache` (18,331 files / 0.28 GB, robocopy-verified) and set at User scope; the old `C:\Users\Xian\AppData\Local\Pub\Cache` copy is retained as a rollback and can be deleted.

---

*Audit performed by reading source. Items 5–9 remain open; 7 and the IAP purchase flow require on-device verification before sign-off.*
