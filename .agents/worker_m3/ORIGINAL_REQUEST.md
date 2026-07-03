## 2026-06-18T00:01:31Z
You are a Worker subagent (teamwork_preview_worker).
Your task is to implement the Built-in Browser & Media Sniffer (Milestone 3 / R2) and extend the download engine to support custom HTTP headers.
Specifically:
1. Update pubspec.yaml to add the dependency: webview_flutter: ^4.13.1. Run `flutter pub get` and verify it succeeds.
2. Extend DownloadTask (lib/downloader/models.dart) and DownloadSplitter (lib/downloader/download_splitter.dart) to accept and forward custom HTTP request headers (e.g. Map<String, String>? headers, such as Cookie, User-Agent, Referer). Verify that the existing unit tests in test/downloader_test.dart still compile and pass successfully.
3. Implement the browser controller interfaces and classes in lib/sniffer/ (or structured directories):
   - SnifferBrowserController abstract interface.
   - SnifferWebViewControllerImpl production implementation (wrapping WebViewController).
   - MockBrowserController for unit/widget tests.
4. Implement MediaSnifferEngine (or MediaSnifferService) matching video (.mp4, .m3u8, etc.), audio (.mp3, etc.), documents (.pdf, .epub, etc.), and archives (.zip, etc.) using RegExp patterns, with de-duplication cache logic to avoid UI spamming.
5. Implement the UI components:
   - BrowserWidget: wrapping the native WebViewWidget (in production) or showing Key('mock_webview_placeholder') (in tests/mock environment).
   - SnifferScreen: address bar text field, webview, media sniffer drawer/panel showing detected links with a floating sniffer action button.
   - Add to Download Queue AlertDialog: prompted when tapping download on a sniffed item, allowing user to rename file, choose priority (Low, Medium, High), and add to DownloadQueue.
6. Implement the unit and widget tests under test/sniffer_test.dart and test/sniffer_screen_test.dart verifying sniffer extension matching, de-duplication, address bar navigation, JS channel interception, and queue addition.
7. Run `flutter test` and ensure all tests pass (100% pass rate).
8. Create a handoff file at D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\worker_m3\handoff.md detailing your changes and test outputs.
9. Send a message to the caller (main agent, id: 3e4d9f3c-76f4-4325-9a43-a009ab5cee90) when completed.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

## 2026-06-18T00:03:55Z
**Context**: Milestone 3 (R2): Built-in Browser & Sniffer implementation.
**Content**: The parent agent has updated the project requirements. An Adblocker filter is now required in the built-in browser (R2).
Specifically:
1. In your browser implementation, implement an adblocker mechanism. Since you are using our mockable `SnifferBrowserController` abstraction (which wraps `webview_flutter` or similar), make sure the controller's navigation delegation or JavaScript injection blocks common ad network domains (such as `doubleclick.net`, `adcolony.com`, `googleads.g.doubleclick.net`) and suppresses popups (e.g. by overriding `window.open` or preventing unauthorized redirects).
2. Integrate this adblocking logic directly into your browser widget and controller code.
3. Update your unit and widget tests under test/sniffer_test.dart and test/sniffer_screen_test.dart to verify that ad domains are successfully blocked and popups are suppressed.
**Action**: Please integrate these adblocking features and tests into your current implementation and report back in your handoff.

