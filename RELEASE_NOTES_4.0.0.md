# Aurora Downloader 4.0.0 (48) — Release Notes

## What's new in 4.0.1 (52)

- **Automation API enqueue fix**: `POST /v1/tasks` is now fully wired to the download queue and
  returns a real `savePath` under the app's completed-downloads directory (previously a broken
  `/tmp/<id>` placeholder)
- **Automation API default off**: the server no longer auto-starts on every launch — it only
  starts if you previously enabled it in Settings (persisted toggle, Ultra tier), and now enforces
  a rate limit (60 requests / 10 s) and a 64 KB body size limit
- **Aurora Watcher notifications**: new items now fire a local notification on a dedicated
  `aurora_watcher` channel in addition to being auto-enqueued
- Build: 4.0.1+52, play channel

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
- Mid-process module installs ask before restarting the app — no more silent
  relaunch mid-download. Choose "Restart now" or "Not now" (the download stays
  queued and resumes after a manual restart)
- Native libraries now load mmap'd straight from the APK (extractNativeLibs
  off): roughly 24 MB less storage used, faster installs
- GitHub / sideload builds stay fat (no billing, no on-demand downloads) —
  enforced mechanically by the build channel

### Dependencies
- 11 within-constraint upgrades: jni 1.0.3, jni_flutter 1.0.2, connectivity_plus
  7.3.1, flutter_local_notifications 22.2.0, in_app_purchase storekit, and more
- Vault security stack verified current: local_auth ^3.0.2 (latest),
  flutter_secure_storage 10.3.1

## What's new in 4.0.0+50 (after the initial 4.0.0+48 release)

- **Blocked-redirect dialog gains "Always block on this site"**: pick it once
  and that site's redirects to that destination are silently cancelled forever
  (per-source-site list, managed by the invisible-redirect blocker)
- **Notification elapsed timer fixed**: the download notification's stopwatch
  no longer resets to 0 every few seconds — it now counts from when the
  download started
- **Dialog hardening** (found by a full popup audit): duplicate "Save partial
  file?" prompts can no longer stack, back-button no longer escapes mandatory
  dialogs, add-to-queue can't be dismissed mid-submit, and stale-context
  crashes after async work are gone
- Logging internals simplified (removed the in-app diagnostics logger — logcat
  is the supported debug channel)

### Build
- 4.0.0+50, play channel, obfuscated, split debug info
- Signing: upload keystore (UPLOAD.RSA verified in the bundle)
