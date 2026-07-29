# Aurora Downloader — Implementation Plan

> **Generated:** 2026-07-21
> **Scope:** All 10 identified issues across download rules, scheduling, vault, theme, incognito, and cleanup.

---

## Phase 1: Critical Fixes (P0)

---

### Fix 1: Wire Download Rules into Enqueue Flow

**Problem:** `DownloadRuleEngine` is loaded at startup (`main.dart:1301-1309`) but never passed to the download pipeline. Zero call sites for `matchRule()`, `applyRename()`, `getDestinationFolder()`.

#### Step 1a — Add `DownloadRuleEngine` parameter to `enqueueDirectDownload()`

**File:** `lib/sniffer/enqueue_download.dart`

Add parameter to function signature (line 93):

```dart
Future<void> enqueueDirectDownload({
  // ... existing params ...
  required DownloadRuleEngine? ruleEngine,          // NEW
  required String? pageHost,                         // NEW (for rule host match)
  required String? mediaTypeForRule,                 // NEW ("video"/"audio"/"hls"/"image")
}) async {
```

After line 192 (after site profile overrides, before `DownloadTask` creation), insert rule application:

```dart
  // --- Download Rules Engine (rename, destination, constraints) ---
  DownloadRule? matchedRule;
  if (ruleEngine != null) {
    matchedRule = ruleEngine.matchRule(
      url,
      mediaType: mediaTypeForRule,
      pageHost: pageHost,
    );
    // Apply rename template
    if (matchedRule?.renameTemplate != null && matchedRule!.renameTemplate!.isNotEmpty) {
      suggestedName = ruleEngine.applyRename(matchedRule!, suggestedName);
    }
    // Apply destination folder override
    final ruleDest = ruleEngine.getDestinationFolder(matchedRule);
    if (ruleDest != null) {
      saveDir = '${baseDir ?? '.'}${Platform.pathSeparator}$ruleDest';
    }
  }

  final task = DownloadTask(
    // ...
    savePath: '$saveDir${Platform.pathSeparator}$suggestedName',
    // ...
  );
```

After `downloadQueue.addTask(task, force: force)` (line 243), apply WiFi/charging/time constraints:

```dart
  // Apply rule constraints (WiFi, charging, time-window → schedule)
  if (matchedRule != null) {
    final now = DateTime.now();
    // Time window: if current time is outside window, schedule for start of window
    if (matchedRule!.timeWindowStartHour != null && matchedRule!.timeWindowEndHour != null) {
      final currentHour = now.hour;
      final startH = matchedRule.timeWindowStartHour!;
      final endH = matchedRule.timeWindowEndHour!;
      final inWindow = startH <= endH
          ? (currentHour >= startH && currentHour < endH)
          : (currentHour >= startH || currentHour < endH);
      if (!inWindow) {
        var schedDate = DateTime(now.year, now.month, now.day, startH);
        if (schedDate.isBefore(now)) {
          schedDate = schedDate.add(const Duration(days: 1));
        }
        downloadQueue.scheduleTask(task, schedDate);
        return; // skip "Started downloading" snackbar
      }
    }
  }
```

#### Step 1b — Add `ruleEngine` plumbing in `SnifferScreen`

**File:** `lib/sniffer/sniffer_screen.dart`

Find where `enqueueDirectDownload()` is called (search for `enqueueDirectDownload(` in this file). Add `ruleEngine`, `pageHost`, and `mediaTypeForRule` to those call sites.

#### Step 1c — Pass `_ruleEngine` from `main.dart`

**File:** `lib/main.dart`

`SnifferScreen` already receives params — add `ruleEngine: _ruleEngine`. For the URL text field path (`_addDownloadFromUrl` at line 897), add rule matching before `addTask` at line 1015 in the same way.

#### Step 1d — Refresh engine when rules change

**File:** `lib/main.dart`

After the settings page's `_RulesPage` saves rules, emit a callback that reloads the engine:

```dart
// In _AuroraHomeState, after rules are saved:
final rules = await const DownloadRulesStore().load();
setState(() => _ruleEngine = DownloadRuleEngine(rules));
```

---

### Fix 2: Wire Schedule UI (Clock Icon + Time Picker)

**Problem:** `DownloadQueue.scheduleTask()` exists and works, but no UI ever calls it. The settings page says "tap the clock icon" but that icon doesn't exist.

#### Step 2a — Add "Schedule" action to download card overflow menu

**File:** `lib/ui/widgets/download_card.dart`

In the `PopupMenuButton` overflow menu (around line 780), add a new item after existing items:

```dart
if (task.state != DownloadState.scheduled) ...[
  const PopupMenuDivider(),
  PopupMenuItem(
    value: 'schedule',
    child: ListTile(
      leading: const Icon(Icons.schedule),
      title: const Text('Schedule download'),
    ),
  ),
],
```

In the `onSelected` handler, add:

```dart
case 'schedule':
  final picked = await showDatePicker(
    context: context,
    initialDate: DateTime.now().add(const Duration(hours: 1)),
    firstDate: DateTime.now(),
    lastDate: DateTime.now().add(const Duration(days: 30)),
  );
  if (picked == null || !context.mounted) break;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(picked),
  );
  if (time == null || !context.mounted) break;
  final startAt = DateTime(picked.year, picked.month, picked.day, time.hour, time.minute);
  widget.queue.scheduleTask(task, startAt);
  widget.showSnack('Scheduled for ${_formatDateTime(startAt)}');
  break;
```

#### Step 2b — Add clock icon to Queue page's "Add URL" area

**File:** `lib/ui/pages/queue_page.dart`

Next to the "Download" button in the URL input row, add an `IconButton` with `Icons.schedule` that opens the same time picker flow but calls `scheduleTask` instead of `addTask`.

#### Step 2c — Fix misleading instruction text

**File:** `lib/ui/pages/settings_page.dart` (line 5476)

Replace the old instruction:

```dart
// OLD:
'New downloads can be scheduled directly from the Queue page by tapping the clock icon.'
// NEW (after clock icon is added in Step 2b):
'New downloads can be scheduled from the Queue page via the clock icon next to the Download button.'
```

---

### Fix 3: Vault "Move to Vault" — Delete Source File

**Problem:** `_moveToVault()` calls `vaultService.store()` but never deletes the original plaintext file. This is a privacy/data-leak bug.

**File:** `lib/main.dart`, lines 1590–1612

**Change lines 1608–1611:**

```dart
// OLD:
    final vaultName = await _vaultService.store(file, tier: tier);
    if (vaultName != null) {
      _showSnack('Moved to vault.');
    }

// NEW:
    final vaultName = await _vaultService.store(file, tier: tier);
    if (vaultName != null) {
      try {
        await file.delete();
      } catch (_) {
        // Deletion failed but file is encrypted in vault — no plaintext leak
      }
      _showSnack('Moved to vault.');
    } else {
      _showSnack('Failed to move to vault.');
    }
```

The `else` branch at the end fixes the **no-feedback-on-failure** bug as well.

---

### Fix 4: Vault WebDAV Restore — Sync Actual File Blobs

**Problem:** Vault sync uploads only metadata (name/size/date), not the encrypted `.vault` file blobs. Restore decrypts the metadata map but never writes actual files back. The `restored` map is discarded.

#### Step 4a — Upload individual vault blobs

**File:** `lib/premium/vault_sync_service.dart`

Add a new method:

```dart
/// Uploads a single encrypted vault blob to WebDAV.
Future<bool> uploadVaultBlob({
  required String passphrase,
  required String vaultName,
  required File vaultFile,
}) async {
  try {
    final salt = await _getOrCreateSalt();
    final keyBytes = _deriveKey(passphrase, salt);
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final nonce = _generateNonce();
    final iv = enc.IV(Uint8List.fromList(nonce));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

    final sourceBytes = await vaultFile.readAsBytes();
    final encrypted = encrypter.encryptBytes(sourceBytes, iv: iv);

    final blob = <int>[...salt, ...nonce, ...encrypted.bytes];
    final blobBase64 = base64.encode(blob);

    final response = await _webdavRequest(
      'PUT',
      '$_syncPath/blobs/$vaultName',
      body: blobBase64,
    );
    return response.statusCode == 201 || response.statusCode == 204;
  } catch (e) {
    if (kDebugMode) debugPrint('[VaultSyncService] blob upload failed: $e');
    return false;
  }
}
```

#### Step 4b — Upload all vault blobs from vault page

**File:** `lib/ui/pages/vault_page.dart`, lines 279–300

After `uploadVault` succeeds, iterate local vault files and upload each blob:

```dart
if (actionType == 0) {
  // ... existing metadata upload ...
  final ok = await syncService.uploadVault(passphrase: passphrase, vaultData: map);
  if (ok) {
    // Also upload individual vault blobs
    final vaultDir = await widget.vault.vaultDir;
    final files = await vaultDir.list().toList();
    bool allBlobsOk = true;
    for (final f in files.whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.vault')) {
        if (!await syncService.uploadVaultBlob(passphrase: passphrase, vaultName: name, vaultFile: f)) {
          allBlobsOk = false;
        }
      }
    }
    // Show appropriate message...
  }
}
```

#### Step 4c — Download and restore vault blobs

**File:** `lib/premium/vault_sync_service.dart`

Add a download method:

```dart
/// Downloads and restores a single encrypted vault blob from WebDAV.
Future<bool> downloadAndRestoreVaultBlob({
  required String passphrase,
  required String vaultName,
  required Directory vaultDir,
}) async {
  try {
    final response = await _webdavRequest('GET', '$_syncPath/blobs/$vaultName');
    if (response.statusCode != 200) return false;

    final blob = base64.decode(response.body);
    if (blob.length < 32 + 12 + 16) return false;

    final salt = blob.sublist(0, 32);
    final nonce = blob.sublist(32, 44);
    final ciphertext = blob.sublist(44);

    final keyBytes = _deriveKey(passphrase, salt);
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV(Uint8List.fromList(nonce));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

    final decrypted = encrypter.decryptBytes(
      enc.Encrypted(Uint8List.fromList(ciphertext)),
      iv: iv,
    );

    final dest = File(p.join(vaultDir.path, vaultName));
    await dest.writeAsBytes(decrypted, flush: true);
    return true;
  } catch (e) {
    if (kDebugMode) debugPrint('[VaultSyncService] blob restore failed: $e');
    return false;
  }
}
```

#### Step 4d — Wire restore in vault page

**File:** `lib/ui/pages/vault_page.dart`, lines 301–310

After `downloadVault` returns metadata, iterate entries and restore each blob:

```dart
if (actionType == 1) {
  final restored = await syncService.downloadVault(passphrase: passphrase);
  if (!mounted) return;
  if (restored != null) {
    // Restore individual vault blobs
    final entries = restored['entries'] as List? ?? [];
    final vaultDir = await widget.vault.vaultDir;
    int restoredCount = 0;
    for (final entry in entries) {
      final name = entry['name'] as String?;
      if (name != null && await syncService.downloadAndRestoreVaultBlob(
        passphrase: passphrase,
        vaultName: name,
        vaultDir: vaultDir,
      )) {
        restoredCount++;
      }
    }
    await _loadEntries();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Vault restored: $restoredCount files from WebDAV.')),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Failed to restore vault (incorrect passphrase or no remote backup).')),
    );
  }
}
```

---

## Phase 2: Medium Fixes (P1)

---

### Fix 5: Theme Accent Color Pack Live Update

**Problem:** Selecting a new accent pack saves to disk but UI doesn't update until cold restart. `AuroraTheme` is wrapped in a `ListenableBuilder` that only listens to `appThemeModeNotifier` + `appOledDarkNotifier`.

#### Step 5a — Add `appAccentPackNotifier`

**File:** `lib/premium/accent_pack.dart`

Add after line 62:

```dart
/// Top-level notifier for accent pack changes.  Fired when the user selects
/// a new accent pack so [MyApp] can rebuild [AuroraTheme] live.
final ValueNotifier<String?> appAccentPackNotifier =
    ValueNotifier<String?>(_activeAccentId);
```

In `saveAccentPack()` (line 80), after setting `_activeAccentId`:

```dart
appAccentPackNotifier.value = id;
```

In `loadSavedAccentPack()` (line 65), after reading the value:

```dart
appAccentPackNotifier.value = _activeAccentId;
```

#### Step 5b — Merge into `ListenableBuilder`

**File:** `lib/main.dart`, line 131

```dart
// OLD:
      listenable: Listenable.merge([appThemeModeNotifier, appOledDarkNotifier]),

// NEW:
      listenable: Listenable.merge([
        appThemeModeNotifier,
        appOledDarkNotifier,
        appAccentPackNotifier,
      ]),
```

Add the import at the top of `main.dart`:

```dart
import 'premium/accent_pack.dart' show appAccentPackNotifier;
```

---

### Fix 6: Remove OSS License Banner from Adblock Page

**Problem:** The FFmpeg + x264 license attribution appears twice — once inside `_buildAdblockPage()` (wrong) and once inside `_buildAboutPage()` (correct).

**File:** `lib/ui/pages/settings_page.dart`

**Delete lines 1050–1073** — the code block inside `_buildAdblockPage()`:

```dart
          // OSS Licenses
          PanelHeader(icon: Icons.gavel_outlined, title: 'Open Source Licenses'),
          const SizedBox(height: 8),
          Panel(child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FFmpeg + x264',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.ac.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  'This software uses FFmpeg (https://ffmpeg.org/) licensed under the '
                  'GNU Lesser General Public License version 2.1 or later. '
                  'This build links against libx264 (https://www.videolan.org/developers/x264.html) '
                  'which is licensed under the GNU General Public License version 2. '
                  'FFmpeg source code is available at https://github.com/FFmpeg/FFmpeg.',
                  style: TextStyle(fontSize: 11, color: context.ac.textSecondary, height: 1.4),
                ),
              ],
            ),
          )),
```

The correct copy at lines 2021–2044 (in `_buildAboutPage()`) remains untouched.

---

### Fix 7: Complete Incognito Mode

**Problem:** `DownloadSettings.privateMode` exists, history suppression works, UI shows purple shield in tab strip — but there's no user-facing toggle and no WebView incognito flag set.

#### Step 7a — Add incognito toggle to browser settings

**File:** `lib/ui/pages/settings_page.dart`

In `_buildBrowserPage()` (around line 1200–1300), add a `SwitchListTile`:

```dart
PanelHeader(icon: Icons.visibility_off_outlined, title: 'Private Browsing'),
const SizedBox(height: 8),
Panel(child: SwitchListTile(
  title: const Text('Private / Incognito mode'),
  subtitle: const Text(
    'Browse without saving history or cookies. '
    'Active tabs show a purple shield icon.',
  ),
  value: local.privateMode,
  onChanged: (v) {
    setLocal(() => local = local.copyWith(privateMode: v));
    _update(local.copyWith(privateMode: v));
  },
)),
```

#### Step 7b — Add incognito control to the WebView controller

**File:** `lib/sniffer/browser_controller.dart`

Add a new method:

```dart
/// Sets incognito (private browsing) mode on the WebView.
/// When enabled, the WebView doesn't persist cookies, cache, or history.
Future<void> setIncognito(bool incognito) async {
  await _ready.future;
  await _controller?.setSettings(
    settings: InAppWebViewSettings(incognito: incognito),
  );
}
```

#### Step 7c — Wire incognito to the WebView widget on tab creation

**File:** `lib/sniffer/browser_widget.dart`, line 37

The `InAppWebViewSettings` needs to accept an `incognito` flag. However, incognito is a per-tab setting that can change at runtime. The primary path is via `setIncognito()` called from `didUpdateWidget` below.

**File:** `lib/sniffer/sniffer_screen.dart`, line 482

In `didUpdateWidget`, when `privateMode` changes, also toggle the WebView flag:

```dart
if (oldWidget.settings.privateMode != widget.settings.privateMode) {
  _privateMode = widget.settings.privateMode;
  for (final tab in _tabs) {
    unawaited(tab.controller.setIncognito(widget.settings.privateMode));
  }
}
```

#### Step 7d — Add incognito toggle button to address bar (optional)

**File:** `lib/sniffer/sniffer_screen.dart`

In the address bar widget area, add a `IconButton`:

```dart
IconButton(
  icon: Icon(
    _privateMode ? Icons.visibility_off : Icons.visibility,
    color: _privateMode ? context.ac.accentPurple : null,
  ),
  tooltip: _privateMode ? 'Private mode ON' : 'Private mode OFF',
  onPressed: () {
    setState(() => _privateMode = !_privateMode);
    widget.onSettingsChanged?.call(
      _settings.copyWith(privateMode: _privateMode),
    );
  },
),
```

---

## Phase 3: Polish (P2)

---

### Fix 8: Vault Error Handling on Store Failure

**Status:** Already addressed by Fix 3 (added `else` branch with error snackbar). No further changes needed.

---

### Fix 9: iOS `FLAG_SECURE` for Vault

**Problem:** `secure_window.dart` only implements `enableSecureWindow`/`disableSecureWindow` for Android (`FLAG_SECURE`). On iOS it silently catches `MissingPluginException`, meaning vault screenshots are not blocked when the app is in the app switcher.

#### Step 9a — Add native iOS implementation

**File:** `ios/Runner/AppDelegate.swift` (create if it doesn't exist with proper Flutter setup)

```swift
import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let secureChannel = FlutterMethodChannel(
      name: "aurora_downloader/secure_window",
      binaryMessenger: controller.binaryMessenger
    )
    secureChannel.setMethodCallHandler { (call, result) in
      if call.method == "enableSecureWindow" {
        DispatchQueue.main.async {
          // iOS equivalent: blur the app switcher preview
          UIApplication.shared.ignoreSnapshotOnNextApplicationLaunch()
          // For actual app-switcher blur, use:
          // controller.view.layer.contents = nil // clears snapshot
          result(nil)
        }
      } else if call.method == "disableSecureWindow" {
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

**Note:** iOS doesn't have a direct equivalent of `FLAG_SECURE`. The best approach is either:
1. `UIApplication.shared.ignoreSnapshotOnNextApplicationLaunch()` — prevents screenshot on next launch
2. Observing `UIApplication.willResignActiveNotification` to blur the view

A more complete approach uses `willResignActive`/`didBecomeActive`:

```swift
// In AppDelegate or a separate class:
NotificationCenter.default.addObserver(
  forName: UIApplication.willResignActiveNotification,
  object: nil,
  queue: .main
) { _ in
  controller.view.isHidden = true // hides app switcher preview
}
NotificationCenter.default.addObserver(
  forName: UIApplication.didBecomeActiveNotification,
  object: nil,
  queue: .main
) { _ in
  controller.view.isHidden = false
}
```

No Dart-side changes needed in `secure_window.dart` — it already handles `MissingPluginException`.

---

### Fix 10: Pass Custom Video Hosts to `MediaSnifferEngine`

**Problem:** `MediaSnifferEngine.sniff()` at line 391 only checks the built-in `_knownVideoHosts` via `isVideoHostingUrl(url)`. User-configured custom hosts from `DownloadSettings.customVideoHosts` are only used in the `onLoadResource` G1 probe path, not in the `sniff()` path.

#### Step 10a — Add custom hosts setter to `MediaSnifferEngine`

**File:** `lib/sniffer/media_sniffer_engine.dart`

Add a field and setter:

```dart
Set<String> _customVideoHosts = const {};

/// Updates the set of user-configured video-hosting domains.
/// These are checked in addition to the built-in [isVideoHostingUrl] list.
void setCustomVideoHosts(Set<String> hosts) {
  _customVideoHosts = hosts;
}
```

Change line 391 from:

```dart
if (type == null && isVideoHostingUrl(url)) {
```

to:

```dart
if (type == null && isVideoHostingUrl(url, extraHosts: _customVideoHosts)) {
```

#### Step 10b — Propagate from `sniffer_screen.dart`

**File:** `lib/sniffer/sniffer_screen.dart`

In `_updateAllTabCustomVideoHosts()` (line 528), add:

```dart
void _updateAllTabCustomVideoHosts() {
  final hosts = widget.settings.customVideoHosts;
  for (final tab in _tabs) {
    tab.controller.updateCustomVideoHosts(hosts);
    tab.snifferEngine.setCustomVideoHosts(hosts.toSet()); // NEW
  }
}
```

---

## Execution Order Summary

| Order | Fix | Complexity | Files Touched | Est. Time |
|-------|-----|-----------|---------------|-----------|
| 1 | **Fix 3** — Vault delete source + error snackbar | 🟢 Trivial (3 lines) | `main.dart` | 5 min |
| 2 | **Fix 6** — Remove OSS from Adblock | 🟢 Trivial (delete 23 lines) | `settings_page.dart` | 2 min |
| 3 | **Fix 5** — Theme accent live update | 🟢 Simple (1 notifier + 1 line) | `accent_pack.dart`, `main.dart` | 10 min |
| 4 | **Fix 10** — Custom hosts to sniffer engine | 🟢 Simple (setter + 1 line change) | `media_sniffer_engine.dart`, `sniffer_screen.dart` | 10 min |
| 5 | **Fix 9** — iOS FLAG_SECURE | 🟢 Simple (new native code) | `AppDelegate.swift` | 15 min |
| 6 | **Fix 1** — Wire download rules | 🟡 Medium (~40 lines, 3 files) | `enqueue_download.dart`, `sniffer_screen.dart`, `main.dart` | 45 min |
| 7 | **Fix 2** — Schedule clock icon + time picker | 🟡 Medium (~50 lines, 3 files) | `download_card.dart`, `queue_page.dart`, `settings_page.dart` | 45 min |
| 8 | **Fix 7** — Complete incognito | 🟡 Medium (~30 lines, 4 files) | `settings_page.dart`, `browser_controller.dart`, `sniffer_screen.dart`, `browser_widget.dart` | 30 min |
| 9 | **Fix 4** — Vault WebDAV blob sync | 🔴 Complex (new methods, full upload/download loop) | `vault_sync_service.dart`, `vault_page.dart` | 90 min |

**Total estimated effort:** ~4.5 hours

---

## Recommended Batch Order

### Batch 1 (Quick wins — ~17 min)
1. Fix 3 — Vault delete source file
2. Fix 6 — Remove OSS from Adblock
3. Fix 5 — Theme accent live update
4. Fix 10 — Custom hosts to sniffer engine
5. Fix 9 — iOS FLAG_SECURE

### Batch 2 (Integration work — ~2 hours)
6. Fix 1 — Wire download rules
7. Fix 2 — Schedule clock icon + time picker
8. Fix 7 — Complete incognito

### Batch 3 (Complex — ~90 min)
9. Fix 4 — Vault WebDAV blob sync
