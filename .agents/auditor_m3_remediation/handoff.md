# Forensic Audit Report & Handoff Report

**Work Product**: Milestone 3 implementation of `aurora_downloader`
**Profile**: General Project (Development Mode)
**Verdict**: CLEAN

---

### Phase Results

- **Source Code Analysis**: PASS — No hardcoded test results, facade implementations, or pre-populated artifact violations found.
- **Behavioral Verification**: PASS — `flutter test` completes successfully. All 43 tests pass.
- **Adblocking Filter**: PASS — List of 15 ad/tracker domains matches the requirement. Popup suppression and UI counter increment work authentically.
- **Header Preservation**: PASS — Custom headers (like `Cookie`, `Referer`) are captured by the browser controller and correctly mapped and enqueued to the downloader's `DownloadTask`.
- **Deduplication Cache**: PASS — Slide window cache logic (1-second timer-based eviction) avoids duplicate URL streams authentically.
- **Content-Disposition Parser**: PASS — Parses both `filename` and `filename*` correctly according to RFC 6266 (preferring `filename*` with UTF-8 decoding).

---

## 1. Observation

- **Adblocking Logic**: Located in `lib/sniffer/browser_controller.dart`, lines 61-105 (and duplicated in `MockBrowserController` lines 227-271). It contains 15 popular ad/tracker domains:
  ```dart
  final adDomains = [
    'doubleclick.net',
    'googleads.g.doubleclick.net',
    'adcolony.com',
    'ads.google.com',
    'popads.net',
    'ads.yahoo.com',
    'adservice.google.com',
    'quantserve.com',
    'scorecardresearch.com',
    'adnxs.com',
    'outbrain.com',
    'taboola.com',
    'criteo.com',
    'pubmatic.com',
    'casalemedia.com',
  ];
  ```
- **Popup Suppression**: Located in `lib/sniffer/browser_controller.dart`, lines 113-115, where `window.open` is overridden to post a message to `AdBlockerChannel`. In `lib/sniffer/sniffer_screen.dart`, lines 75-81, the JS channel intercepts this message:
  ```dart
  _controller.addJavaScriptChannel('AdBlockerChannel', onMessageReceived: (message) {
    if (message == 'popup_blocked') {
      setState(() {
        _controller.incrementBlockedPopups();
      });
    }
  });
  ```
- **Preserved Headers**: Located in `lib/sniffer/sniffer_screen.dart`, lines 409-423, when enqueuing:
  ```dart
  final Map<String, String> taskHeaders = Map<String, String>.from(_controller.currentHeaders);
  final hasReferer = taskHeaders.keys.any((k) => k.toLowerCase() == 'referer');
  if (!hasReferer && currentUrl != null) {
    taskHeaders['Referer'] = currentUrl;
  }
  // ...
  final task = DownloadTask(
    // ...
    headers: taskHeaders,
  );
  ```
  These are then used in network requests in `lib/downloader/download_splitter.dart`, lines 65, 89-91, and 285-290.
- **Slide Window Cache Deduplication**: Located in `lib/sniffer/media_sniffer_engine.dart`, lines 53-76:
  ```dart
  // De-duplication cache logic
  if (_urlCache.contains(url)) {
    return;
  }
  // ...
  if (type != null) {
    _urlCache.add(url);

    _evictionTimers[url]?.cancel();
    _evictionTimers[url] = Timer(const Duration(seconds: 1), () {
      _urlCache.remove(url);
      _evictionTimers.remove(url);
    });
  ```
- **Content-Disposition Parser**: Located in `lib/sniffer/media_sniffer_engine.dart`, lines 96-131:
  ```dart
  String? _parseContentDispositionFilename(String contentDisposition) {
    try {
      final starMatch = RegExp(
        r"filename\*=(?:utf|UTF)-8''([^;\n\s]+)",
        caseSensitive: false,
      ).firstMatch(contentDisposition);
      if (starMatch != null) {
        final encoded = starMatch.group(1);
        if (encoded != null) {
          final decoded = Uri.decodeComponent(encoded);
          final cleaned = decoded.replaceAll('"', '').trim();
          if (cleaned.isNotEmpty) {
            return cleaned;
          }
        }
      }

      final normalMatch = RegExp(
        r'filename\s*=\s*([^;\n]+)',
        caseSensitive: false,
      ).firstMatch(contentDisposition);
      if (normalMatch != null) {
        String val = normalMatch.group(1)!.trim();
        if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
          val = val.substring(1, val.length - 1);
        } else if (val.startsWith("'") && val.endsWith("'") && val.length >= 2) {
          val = val.substring(1, val.length - 1);
        }
        val = val.trim();
        if (val.isNotEmpty) {
          return val;
        }
      }
    } catch (_) {}
    return null;
  }
  ```
- **Test Executions**: Executed `flutter test` via background task, which finished with `All tests passed!`. Below is the raw output log of the Milestone 3 test targets:
  ```
  00:05 +6: D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_1_test.dart: Challenger M3-1 Empirical Verification Tests Adblocking filter logic with 15 different ad/tracker domains
  00:06 +7: D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_1_test.dart: Challenger M3-1 Empirical Verification Tests Popup suppression increments counter and reflects in UI
  00:08 +8: D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_2_test.dart: Milestone 3 Deduplication & Headers Tests Simulate high volume of duplicate media URLs within 1 second
  00:08 +9: D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_2_test.dart: Milestone 3 Deduplication & Headers Tests Verify after deduplication window expires, a new request with the same URL is successfully emitted
  00:10 +10: D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_2_test.dart: Milestone 3 Deduplication & Headers Tests Custom headers (Cookie, Referer) are successfully preserved and mapped to the enqueued DownloadTask
  ```

---

## 2. Logic Chain

1. **Adblocker**: By matching the incoming URL host against the list of 15 predefined ad/tracker domains (e.g. `doubleclick.net`, `adnxs.com`), and returning `true` inside `shouldBlockUrl`, the controller intercepts and prevents navigation requests or requests that are part of ad delivery. The popup counts are updated when the JS channel captures `popup_blocked`.
2. **Deduplication**: By keeping a `Set<String> _urlCache` and checking `_urlCache.contains(url)`, duplicates are immediately rejected. The use of a standard `Timer` configured with a 1-second duration ensures that after 1 second has elapsed, the timer fires and executes `_urlCache.remove(url)`. This permits the same URL to be sniffed again once the 1-second window expires, proving that the slide window logic is implemented authentically.
3. **Header Preservation**: By converting the browser's current headers `_controller.currentHeaders` into the task headers, resolving missing `Referer` fields using `currentUrl`, and then assigning these to `DownloadTask.headers`, they are successfully enqueued. Inside `DownloadSplitter`, they are attached to the actual http connection via `request.headers.addAll(task.headers!)`, ensuring they are preserved during the download phase.
4. **Filename Parsing**: By executing a case-insensitive regex check for `filename*` first (preferring it as per RFC 6266) and decoding it via `Uri.decodeComponent`, it parses international/special characters accurately. If missing, it falls back to parsing `filename` using `[^;\n]+` regex and stripping enclosing double/single quotes.

---

## 3. Caveats

- **Webview Limits**: While headers passed to `loadRequest` are stored and mapped, standard WebView APIs do not expose headers of individual assets loaded *within* the page (such as images/scripts) dynamically. The sniffer handles this by fallback mechanisms, e.g., mapping the page's main URL as the `Referer` if it's missing. This is a platform constraint, not an implementation violation.
- **Network Mode**: The audit is performed in `CODE_ONLY` network mode, meaning tests rely on mocks and local test execution. Mocks correctly simulate actual HTTP streams and behaviors.

---

## 4. Conclusion

The Milestone 3 implementation is **CLEAN**. All tasks (Adblocker, headers mapping, slide window cache, Content-Disposition parsing) are implemented using authentic, production-ready logic. There is no evidence of hardcoded test result bypasses, facade implementations, or cheating.

---

## 5. Verification Method

To independently verify the audit:
1. Navigate to the project root: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`
2. Run command:
   ```powershell
   flutter test
   ```
3. Inspect the code in `lib/sniffer/media_sniffer_engine.dart` and `lib/sniffer/browser_controller.dart` to verify that no fake static checks are in place.
