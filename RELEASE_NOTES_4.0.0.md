# Aurora Downloader 4.0.0 (48) — Release Notes

## What's new (Play Store listing — under 500 chars)

- Private Vault: reliable biometric/PIN unlock, clearer locked/unlocked states, and
  vault data now stays out of Android Auto Backup so it can never lock you out
- Find on page: working match navigation with a live count — no more crashes
- Save page: no more freezes on large pages, and saved pages now open properly
- Block element: blocks apply instantly without reloading, with a per-site list
  in Settings to undo any block
- FFmpeg engine downloads on demand from Play — smaller install, same Ultra tools
- Fresh look at reliability: crash fixes and dependency refresh

## Full changelog (GitHub-style)

### Private Vault (Pro)
- Unlock now actually prompts for biometrics/PIN on entry (was fail-closed silent)
- Fixed `must be a FragmentActivity` crash when the fingerprint dialog opened
  (`FlutterFragmentActivity` base)
- Clearer lock/unlock states and error snackbars instead of silent failures
- Vault + secure storage excluded from Android Auto Backup: a device restore can
  no longer strand the encrypted vault (Keystore-bound master key) in a
  permanent-lockout state
- Only completed downloads can be moved to the vault — a file can never be
  deleted from under a seeding/paused torrent
- Secure-window (screenshot blocking) verified wired into the vault

### Browser Tools
- **Find on page**: Next/Prev now navigate with the actual query (the highlight
  previously never moved), the bar shows a real match count, and the counter
  loop that could break WebView rendering is gone
- **Save page**: captures large pages in chunks — the tab no longer freezes on
  big DOMs — and saved pages open correctly from the Saved Pages list
- **Block element**: same-host picks apply immediately (no reload needed), Undo
  restores instantly, the toast has a visible Undo button, and Settings →
  Adblock gains a per-site "Blocked elements" list with one-tap undo per rule

### Distribution (Play Store)
- Play builds ship as a lean base AAB: FFmpeg (~10 MB of native libs) is an
  on-demand module downloaded on first Ultra-tier FFmpeg Studio use; torrent and
  media-player engines are on-demand modules too
- Mid-process module installs trigger an automatic app restart so the freshly
  downloaded native libraries load correctly
- GitHub / sideload builds stay fat (no billing, no on-demand downloads) —
  enforced mechanically by the build channel

### Dependencies
- 11 within-constraint upgrades: jni 1.0.3, jni_flutter 1.0.2, connectivity_plus
  7.3.1, flutter_local_notifications 22.2.0, in_app_purchase storekit, and more
- Vault security stack verified current: local_auth ^3.0.2 (latest),
  flutter_secure_storage 10.3.1

### Build
- 4.0.0+48, play channel, obfuscated, split debug info
- Signing: upload keystore (UPLOAD.RSA verified in the bundle)
