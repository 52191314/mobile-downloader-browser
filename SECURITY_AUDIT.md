# Aurora Downloader — Security & Weakness Assessment

**Date:** 2026-07-20  
**Scope:** Full Dart/Flutter + Android native codebase (~200+ files)  
**Method:** 6 parallel audit agents (browser, crypto, native, premium/parser, network servers, downloader) + personal verification of all Critical/High findings against source.  

**Severity distribution:**

| Severity | Count | Key areas |
|----------|-------|-----------|
| 🔴 Critical/High | 6 | Torrent path traversal, bencode DoS, plaintext credit cards, unencrypted backup, forgeable entitlements, unsanitised method channels |
| 🟠 Medium | 13 | LAN log server exposure, intent:// navigation, WebView surface area, policy bypasses, HLS key-in-clear, parser OOM/overflow, SSRF |
| 🟡 Low / D-i-D | ~15 | Content-Disposition chars, proxy URI corruption, JPEG RangeError, recovery key visible, metadata leaks |

**Status legend:** ✅ = personally verified against source, 🔎 = agent-reported with code quotation, ✋ = re-verified by me.

---

## 🔴 Critical / High — Fix First

### H1. Torrent path traversal → arbitrary file write ✅✋

**Files:** [`lib/downloader/torrent_metadata.dart:132-139`](lib/downloader/torrent_metadata.dart) + [`lib/downloader/torrent_downloader.dart:511-515`](lib/downloader/torrent_downloader.dart)

Torrent `info.files[].path` components are joined with `/` and written without any sanitization:

```dart
// torrent_metadata.dart:132-139
final path = pathList
    .map((p) {
      if (p is! Uint8List) throw FormatException('Invalid path component in file entry');
      return utf8.decode(p);
    })
    .join('/');

// torrent_downloader.dart:511-515
final targetPath = metadata!.isMultiFile
    ? '${task.savePath}/${fileInfo.path}'
    : task.savePath;
await _writeBytesAt(targetPath, fileWriteOffset, segment);

// _writeBytesAt:521-531 does parent.create(recursive: true)
final parent = file.parent;
if (!await parent.exists()) {
  await parent.create(recursive: true);
}
```

**Exploitation:** A malicious `.torrent` (poisoned magnet, MITM'd `.torrent` fetch — see M7) with `path: ["..","..","Android","media","evil.exe"]` escapes the download directory. On devices with broad storage access (legacy Android or `MANAGE_EXTERNAL_STORAGE`) this writes to any writable shared path; at minimum it overwrites the app's own files (queue state, settings, other completed downloads).

**Fix:**
1. Normalize each path component; reject `..`, `.`, empty strings, and separator-containing components (`/`, `\`, `:`).
2. At the write site, resolve `targetPath` to its canonical path and assert `canonicalPath.startsWith(canonicalSaveRoot)` (same pattern used in `lan_file_server.dart:_resolveAllowedPath`).
3. Add a `maxPathComponents` cap (e.g. 64) to guard against deeply nested zip-bombs.

---

### H2. Bencode decoder: unbounded recursion + unbounded heap allocation → DoS 🔎

**File:** [`lib/downloader/bencode_decoder.dart:82-118`](lib/downloader/bencode_decoder.dart)

```dart
// ~line 82-103 — length prefix parsed without upper bound
len = len * 10 + (char - 48);        // unbounded multiplication
final data = _bytes.sublist(_pos, _pos + len);   // OOM

// ~line 106-118 — recursive descent without depth cap
List<dynamic> _parseList() {
  _pos++; // skip 'l'
  final list = <dynamic>[];
  while (_pos < _bytes.length && _bytes[_pos] != 101) {
    list.add(_parseAny());   // ← recursion, no depth check
  }
  …
}
```

**Exploitation:** Any magnet or `.torrent` passes through this parser. ~5k nested lists (e.g. `l` repeated) overflow the Dart C stack (`StackOverflowError`, killing the process). A few hundred bytes can claim gigabytes via the string-length prefix (`s9999999999999999...`). On top of H1's traversal, this means **any torrent file can crash the app or OOM-kill it**.

**Fix:**
- Cap recursion depth at 64 (throw `FormatException` if exceeded).
- Cap string/byte-string length at `min(decodedLen, remainingBytes, 256 MB)`.
- Run parsing inside the worker isolate (it already uses one — verify coverage) so a crash can't take down the UI isolate.

---

### H3. Plaintext credit cards in autofill store 🔎

**File:** [`lib/sniffer/autofill_store.dart:88-124, 151-163`](lib/sniffer/autofill_store.dart)

```dart
// ~line 88
Map<String, dynamic> toJson() => {
  'cardNumber': cardNumber,      // plaintext
  'cardName': cardName,
  'cardExpiry': cardExpiry,
  …
};

// ~line 151
Future<void> save() async {
  final json = jsonEncode(profiles.map((p) => p.toJson()).toList());
  final file = File(path);       // app support dir — no encryption
  await file.writeAsString(json);
}
```

`AutofillStore.load()` has **no biometric gate** (contrast with `VaultService` which requires biometric + fails closed).

**Compounding factor:** `AndroidManifest.xml` does **not** declare `android:allowBackup`, which defaults to `true`. On API 24–30 (your `minSdk` is 24), `adb backup` extracts app-private files, including `autofill_profiles.json`, to any USB-authorized PC.

**Fix:**
1. Encrypt autofill data with a Keystore-backed key before writing to disk — use `flutter_secure_storage` or the same pattern as `VaultService`.
2. Gate read access behind `local_auth` (biometric/PIN).
3. Set `android:allowBackup="false"` and/or `android:fullBackupContent="@xml/backup_rules"` / `android:dataExtractionRules` to exclude sensitive files.

---

### H4. Auto-backup exports browsing history + queue to public Downloads without encryption ✅✋

**File:** [`lib/backup/auto_backup_service.dart:118-157`](lib/backup/auto_backup_service.dart)

```dart
// ~line 134-140 — browsing history is explicitly included
if (decoded is Map) {
  for (final key in ['favorites', 'folders', 'history', 'savedPages']) {
    if (decoded.containsKey(key)) {
      consolidatedMap[key] = decoded[key];
    }
  }
}

// ~line 153 — pushed to public MediaStore Downloads
final ok = await PublicDownloadsService.backupFileToDownloads(
  sourcePath: temp.path,
  displayName: displayName,
  relativePath: '$autoBackupRootRelative/$timestamp',
);
```

The consolidated JSON contains `downloadQueue` (media URLs, filenames, metadata), full browsing `history`, `savedPages`, `favorites`, `tabs`, `tabGroups`, and `settings` — all in **unencrypted** JSON written to a world-readable public directory (`Download/Aurora Downloader/Auto Backup/<timestamp>/`). Any app with `READ_EXTERNAL_STORAGE` (or the scoped-storage equivalent) can read the user's complete browsing/download history.

**Fix:**
- Encrypt backup contents with a derivation from the vault key, or a Keystore-wrapped symmetric key.
- At minimum, provide a user toggle to exclude browsing history and saved pages, and warn about the privacy implications of unencrypted backups.
- Consider writing to app-private storage and using MediaStore only for user-initiated export.

---

### H5. Pro entitlement forgeable via local file edit 🔎

**Files:** [`lib/premium/pro_entitlement_store.dart:60-73`](lib/premium/pro_entitlement_store.dart) + [`lib/premium/play_billing_service.dart:266-300`](lib/premium/play_billing_service.dart)

```dart
// pro_entitlement_store.dart:60-73
Future<ProEntitlement?> loadCachedEntitlement() async {
  try {
    final file = File(_filePath);
    if (!await file.exists()) return null;
    final json = json.decode(await file.readAsString());
    return ProEntitlement.fromJson(json);   // no signature/authentication check
  } …
}
```

`pro_entitlement.json` is unsigned plaintext:
```json
{"schemaVersion":2,"tier":"ultra","source":"play","ownedProductIds":["aurora_pro_unlock"],"lastReconcileOk":true}
```

On the `github` (non-Play) channel, there is no server-side reconciliation at all. ADB backup/restore of this file instantly escalates to Pro/Ultra.

On the `play` channel, purchases are granted entirely client-side — `PlayBillingService` calls `entitlement.grantFromProductId()` on `PurchaseStatus.purchased` without verifying against the Play Developer API server-side. A rooted device with Frida/Xposed can spoof `PurchaseDetails` with `status: purchased, productID: aurora_pro_unlock`.

**Fix (pragmatic for a FOSS app):**
- HMAC the entitlement file with a device-bound Keystore key (detect tampering, though the key is on-device).
- Verify offline purchase signatures using the Play public key (free, no backend needed).
- Never grant tier from cached file alone — always attempt reconciliation first.

---

### H6. Kotlin method-channel paths unsanitised (defence-in-depth) 🔎

**Files:** [`NativeDownloadEngine.kt:201-202`](android/app/src/main/kotlin/com/personal/aurora_downloader/NativeDownloadEngine.kt), [`MainActivity.kt:555, 1135`](android/app/src/main/kotlin/com/personal/aurora_downloader/MainActivity.kt)

```kotlin
// NativeDownloadEngine.kt:201-202
val outFile = File(filePath)    // filePath from Dart, unvalidated
outFile.parentFile?.mkdirs()

// MainActivity.kt:~1135
muxer = MediaMuxer(destPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)  // destPath from Dart
extractor.setDataSource(sourcePath)   // sourcePath from Dart, unvalidated
```

Today only your Dart isolate calls these methods. But if the Dart isolate is ever compromised (tainted dependency, supply-chain attack on a package, or code injection via the WebView-to-Dart bridge), each of these becomes an arbitrary file read/write/overwrite primitive **with no native-side guard**.

**Fix:** Add a canonical-path jail check on the Kotlin side:
```kotlin
val canonical = File(path).canonicalPath
val allowed = listOf(
    context.filesDir.canonicalPath,
    context.cacheDir.canonicalPath,
    context.getExternalFilesDir(null)?.canonicalPath   // if used
).filterNotNull()
if (!allowed.any { canonical.startsWith(it) }) throw SecurityException("Path not allowed: $canonical")
```

---

## 🟠 Medium

| # | Status | Location | Issue | Exploitation / Impact |
|---|--------|----------|-------|-----------------------|
| **M1** | ✅ | removed 2026-08-05 | Both log servers (`lib/utils/log_server.dart`, `lib/log_server.dart`) bound **`0.0.0.0`** with no auth/TLS and exposed live download activity to the LAN in debug builds. **Resolved by removal** — the entire logging subsystem (AuroraLog, DownloadLogger, both servers, Diagnostics UI) was deleted and archived under `archive/diagnostics_logging_2026-08-05/`; all call sites are now plain `debugPrint`. No server binds any port anymore. |
| **M2** | 🔎 | [`browser_controller.dart:1028-1041`](lib/sniffer/browser_controller.dart) | `shouldOverrideUrlLoadingCallback` does **not block non-HTTP schemes**. Only the cross-origin redirect check is performed; `intent://`, `tel:`, `file://`, `market://`, `sms:`, `geo:` navigations proceed. | A malicious page (or ad) can launch arbitrary Android intents — open apps, send SMS, call numbers, open settings. **Fix:** whitelist `http`/`https` schemes; handle `intent://` defensively (require user confirmation for non-http navigations). |
| **M3** | 🔎 | [`browser_widget.dart:44-45`](lib/sniffer/browser_widget.dart) | WebView `allowFileAccess: true` + `allowContentAccess: true`. Combined with a page that can navigate to `file:///` or `content://` URIs, this broadens the attack surface unnecessarily. | `content://` accesses ContentProvider data; `file://` can read local files if combined with a navigation bypass. **Fix:** disable both unless a specific feature requires them. |
| **M4** | 🔎 | [`compliance/restricted_media_policy.dart:264-279`](lib/compliance/restricted_media_policy.dart) + redirect paths | Play-compliance domain block is bypassable via **trailing dot** (`youtube.com.` — `Uri.host` preserves it, suffix match fails), **IP literals** (no DNS resolution performed), **IDN punycode homographs**, and **post-enqueue redirects** (policy checked at enqueue time, not at each redirect hop). | Store-policy/liability risk: blocked sites are downloadable through trivial URL variants. **Fix:** normalize trailing dot, attempt DNS resolution of the IP family, re-evaluate policy at every redirect hop. |
| **M5** | 🔎 | [`idm_backup_parser.dart:78-101`](lib/sniffer/idm_backup_parser.dart) | Imported `.1dmbak` fields `name`/`dir` are used to construct `savePath` without sanitization (`../../x`), and `uri` is injected into the download queue with no validation (`file://`, intranet URLs). | Social-engineering a user to import a crafted backup → traversal write + fetch of internal resources. **Fix:** apply `FilenameService.sanitize` to imported names, reject `file://` URIs, validate against a URL allowlist. |
| **M6** | 🔎 | [`hls_downloader.dart:1239-1292`](lib/downloader/hls_downloader.dart) | HLS AES-128 key URI inherits the playlist scheme — an `http://` playlist fetches the decryption key **in cleartext**. | MITM on the network can obtain the 16-byte AES key and decrypt all media segments. **Fix:** reject key URIs over plain HTTP; warn/upgrade when the playlist is HTTP but key would be fetchable in cleartext. |
| **M7** | 🔎 | [`torrent_downloader.dart:259-286`](lib/downloader/torrent_downloader.dart) | `.torrent` file fetched via plain HTTP with **no integrity verification** against the expected info hash. | MITM replaces the torrent with crafted metadata → pairs with H1 for arbitrary file write. **Fix:** verify fetched `.torrent` SHA-1 against the magnet's info hash before parsing. |
| **M8** | 🔎 | [`webdav_backup_service.dart:88, 337`](lib/premium/webdav_backup_service.dart) | Stock `http.Client` follows redirects *after* `validateWebdavUrl` — a trusted/compromised HTTPS server can 302 to an internal HTTP host and Digest credentials follow. Also: PROPFIND response is read entirely with no size cap (OOM). | SSRF with forwarded credentials; OOM from oversized XML response. **Fix:** disable auto-redirects on the WebDAV client, validate each hop, cap PROPFIND response at a reasonable size (e.g. 4 MB). |
| **M9** | 🔎 | [`AndroidManifest.xml`](android/app/src/main/AndroidManifest.xml) (no `allowBackup`), [`proguard-rules.pro:18`](android/app/proguard-rules.pro) | `allowBackup` defaults to `true` (see H3 chain for data exfiltration). ProGuard: `-keep class com.personal.aurora_downloader.** { *; }` disables obfuscation of your own Kotlin — trivial reverse-engineering of billing/download glue. | **Fix:** set `allowBackup="false"` + `dataExtractionRules`; narrow the keep rule to only what reflection needs. |
| **M10** | 🔎 | [`DownloadForegroundService.kt:86`](android/app/src/main/kotlin/com/personal/aurora_downloader/DownloadForegroundService.kt) | Notification `VISIBILITY_PUBLIC` includes the active filename on the lock screen. | A passer-by sees `private_video.mp4 — 45%` on the lock screen. **Fix:** use `VISIBILITY_PRIVATE` or redact filename for the public surface. |
| **M11** | 🔎 | [`browser_controller.dart:1576-1590`](lib/sniffer/browser_controller.dart) + `autofill_store` | `fillForm` injects card data into page DOM; after filling, page JS can read filled values or intercept `input`/`change` events. Combined with H3 (plaintext storage) and heuristic-only safe browsing (single-thread, 8 TLDs, one GitHub blocklist), the phishing risk is elevated. | User-triggered (Dart→JS), so a page cannot initiate, but a page could observe the injected data after user chooses to autofill a malicious field. **Fix:** require explicit per-site confirmation before filling card fields in the autofill UI. |
| **M12** | 🔎 | [`headless_webview_fetcher.dart:203`](lib/downloader/headless_webview_fetcher.dart) | URL embedded into a JavaScript string expression with only `\` and `'` escaping — U+2028/U+2029 (Unicode line terminators) and crafted `\'` sequences can break out. | Hard to exploit in practice but indicates a pattern that should use `jsonEncode` universally for JS string embedding. **Fix:** use `jsonEncode(url)` instead of manual escaping. |
| **M13** | 🔎 | [`vault_service.dart:268-276`](lib/premium/vault_service.dart) | Legacy AES-CBC fallback for old vault files has **no MAC** — ciphertext can be silently tampered with. | An attacker who can write files to the vault directory (limited: requires root or the app's UID) could corrupt decrypted output. **Fix:** add a one-time migration pass that re-encrypts CBC blobs to GCM on unlock. |

---

## 🟡 Low / Defense-in-depth (selection)

| # | Status | Location | Issue |
|---|--------|----------|-------|
| L1 | 🔎 | [`lan_file_server.dart:216-226`](lib/premium/lan_file_server.dart) | Content-Disposition filename strips only `\r\n"` — allows `%00` (null byte), `\`, `;`, `(`. Quoted value limits damage but can confuse HTTP intermediaries. |
| L2 | 🔎 | [`lan_file_server.dart:113`](lib/premium/lan_file_server.dart) | No per-request read timeout — slow-loris client can hold one of 4 concurrent slots for 10 minutes (max idle). |
| L3 | 🔎 | [`download_queue.dart:187-204`](lib/downloader/download_queue.dart) | Proxy username/password interpolated raw into findProxy string — `@` and `:` in password corrupt the proxy URI parsing. |
| L4 | 🔎 | [`media_binary_parsers.dart:203-208`](lib/sniffer/media_binary_parsers.dart) | JPEG SOF marker reads `bytes[i+7]` and `bytes[i+8]` with only `i < len-5` guard → `RangeError` on truncated files. |
| L5 | 🔎 | [`vault_page.dart:322-325`](lib/ui/pages/vault_page.dart) | Recovery key (AES-256-GCM master key) shown as selectable plaintext. FLAG_SECURE prevents screenshots, but shoulder-surfing is possible. |
| L6 | 🔎 | [`session_recovery.dart:74-81`](lib/sniffer/session_recovery.dart) | Open tab URLs persisted in plaintext JSON (app-private dir). |
| L7 | 🔎 | [`webdav_backup_service.dart:432+`](lib/premium/webdav_backup_service.dart) | `debugPrint` of backup metadata (filenames, operation status) not guarded by `kDebugMode`. |
| L8 | 🔎 | `bencode_decoder.dart:43-79` | Negative-zero and leading-zero checks are correct (well done), but there's no size cap on `pieces` byte string in torrent metadata (only modulo-20 check). |
| L9 | 🔎 | [`MainActivity.kt`](android/app/src/main/kotlin/com/personal/aurora_downloader/MainActivity.kt) exported (see info box) | `MainActivity` is `exported="true"` without an `intent-filter` — explicit intents from any app launch it. `getInitialUrl()` forwards `intent.data` to Dart — validate against a scheme/host allowlist. |
| L10 | ✅✋ | [`android/key.properties`](android/key.properties) on disk | Signing key and credentials exist on the local filesystem (properly gitignored). Machine compromise = signing key compromise. Consider CI-managed signing. |

---

## ✅ What's done well (keep these patterns)

| Area | Strength | File reference |
|------|----------|----------------|
| **LAN file server** | Canonical-path jail with symlink re-validation, single-use `Random.secure()` tokens, per-IP rate limiting, entitlement re-check. **Gold standard — replicate this pattern at the torrent writer and Kotlin method channels.** | `lan_file_server.dart` |
| **Vault** | AES-256-GCM with per-file random nonces, Keystore-backed keys, biometric gate that **fails closed**, session key dropped on `AppLifecycleState.paused`, FLAG_SECURE. | `vault_service.dart`, `vault_page.dart` |
| **WebDAV** | HTTPS enforcement except RFC1918, credentials in `flutter_secure_storage`, strict backup-name regex (`^aurora_backup_[A-Za-z0-9._-]+$`), restore key whitelist + 8 MiB size caps, **no `badCertificateCallback`** anywhere in the codebase. | `webdav_backup_service.dart` |
| **Build channel** | Compile-time `String.fromEnvironment` with safe `github` default — no runtime flag-flipping. | `build_channel.dart` |
| **Release signing** | **Fails closed** — throws `GradleException` if `key.properties` is missing in release build. R8 + resource shrinking enabled. | `app/build.gradle.kts:70-77` |
| **Service security** | `DownloadForegroundService` is `exported="false"`. No custom TrustManager. No `REQUEST_INSTALL_PACKAGES`. No `usesCleartextTraffic` (defaults to secure on API 28+). No `FileProvider`. | `AndroidManifest.xml`, `NativeDownloadEngine.kt` |
| **Filename sanitization (HTTP)** | `FilenameService.sanitize` strips `\ / : * ? " < \|` + control chars + trailing dots/spaces; `uniquePath` prevents silent overwrites. Applied uniformly in the HTTP pipeline. | `filename_service.dart` |
| **De-duplication** | URL normalization (strips UTM params) before enqueue to avoid duplicate downloads. | `download_queue.dart:1381-1399` |
| **No XML parser** | DASH MPD is regex-parsed (not a real XML parser) — XXE and entity-bomb attacks are structurally impossible. | `dash_playlist_parser.dart` |

---

## Exploit chains

**Chain 1 — Remote torrent compromise (no device access required)**
```
Malicious magnet/torrent →
  M7: .torrent fetched over HTTP, not verified →
  H2: bencode decodes (survives recursion/length limits after fix) →
  H1: path "..\..\..\sdcard\malicious.txt" escapes save dir →
  arbitrary file write in app/external storage
```
→ **Impact:** overwrite other completed downloads, inject files into user's Documents.

**Chain 2 — Physical/USB compromise**
```
USB debugging or ADB access →
  H3: adb backup extracts autofill_profiles.json (plaintext credit cards) +
  H5: adb backup/restore injects pro_entitlement.json ("tier":"ultra") +
  L6: session_recovery.json (open tab URLs)
```
→ **Impact:** credential + privacy exfiltration, permanent Pro unlock.

**Chain 3 — Debug build LAN exposure** _(resolved 2026-08-05 — logging subsystem removed, no server binds any port)_
```
Debug build on same Wi-Fi →
  M1: LogServer on 0.0.0.0:8080, unauthenticated, HTML page + WebSocket live stream →
  logs contain download URLs, file paths, user activity
  (malicious webpage can connect via WebSocket — no origin check)
```
→ **Impact:** real-time surveillance of user's downloads and browsing from any LAN device or visited website. _(Moot: both log servers deleted.)_

**Chain 4 — Sniffer browser → device (no device access)**
```
Malicious page loaded in sniffer browser →
  M2: navigates main frame to intent://evil.com#Intent;... →
  launches arbitrary Android intent →
  intercept SMS, open settings, launch apps
```
→ **Impact:** can be severe depending on available intent handlers.

---

## Remediation roadmap

### Week 1 — Remote-exploitable prevents
1. **H1** — Torrent path jail: normalize + validate each path component + canonical-path assertion at write site.
2. **H2** — Bencode depth cap (64), length cap (256 MB, or at least `≤ remainingBytes`), ensure running inside the worker isolate.
3. **M2** — Scheme whitelist in `shouldOverrideUrlLoading` (block non-http/https).

### Week 2 — Data-at-rest + manifest cleanup
4. **H3** — Encrypt autofill data; gate behind `local_auth`; set `allowBackup="false"` + extraction rules.
5. **H5** — HMAC `pro_entitlement.json` with a device-bound Keystore key; verify offline purchase signatures.
6. **M9** — Set `allowBackup`; narrow the ProGuard keep rule.
7. **M5** — Sanitize imported IDM backup filenames and URLs.

### Week 3 — Network hardening + policy
8. **M1** — Guard log servers internally; default to `127.0.0.1`; require a token for LAN access.
9. **M4** — Normalize trailing dot on restricted domains; resolve IPs; re-evaluate policy on each redirect.
10. **M8** — Disable auto-redirects on WebDAV client; cap PROPFIND response size.
11. **M6/M7** — Reject HTTP key URIs in HLS; verify `.torrent` integrity against info hash.

### Week 4 — Defense-in-depth
12. **H6** — Add canonical-path jail on Kotlin method channels.
13. **M3** — Disable `allowFileAccess`/`allowContentAccess` on WebView.
14. **M10** — Set notification `VISIBILITY_PRIVATE`.
15. **M11** — Warn before filling credit card fields in autofill.
16. **M12** — Replace manual JS escaping with `jsonEncode` across all `evaluateJavascript` call sites.
17. **M13** — Migrate legacy CBC vault blobs to GCM on unlock.
18. **L1-L10** — Address remaining low-severity issues as time permits.

---

**Highest-leverage single fix:** H1 torrent path traversal — it's remote-content-triggered, requires no device access, and chains with M7 into a full arbitrary-file-write primitive. The `_resolveAllowedPath` pattern from the LAN server already exists as a reference implementation.
