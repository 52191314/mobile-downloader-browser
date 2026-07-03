# Handoff Report - Milestone 3 Verification

## 1. Observation

- **Adblocker List Limit**: In `lib/sniffer/browser_controller.dart`, lines 59-65 (for SnifferWebViewControllerImpl) and lines 192-198 (for MockBrowserController), the domains blocked are restricted to:
```dart
      final adDomains = [
        'doubleclick.net',
        'adcolony.com',
        'googleads.g.doubleclick.net',
        'ads.google.com',
        'popads.net',
      ];
```
- **Lack of Blocked Popups UI Counter**: Inside `lib/sniffer/sniffer_screen.dart`, when a popup is blocked, the JS channel triggers `_controller.incrementBlockedPopups();` (lines 75-79), but the value of `blockedPopupsCount` is never rendered or used in any UI Widget or text element.
- **Custom Headers Absence in UI**: In `lib/sniffer/sniffer_screen.dart`, lines 114-125, the browser load request is called without headers:
```dart
  void _loadAddress() {
    final address = _addressController.text.trim();
    if (address.isEmpty) return;

    Uri? uri = Uri.tryParse(address);
    if (uri != null) {
      if (!uri.hasScheme) {
        uri = Uri.parse('https://$address');
      }
      _controller.loadRequest(uri);
    }
  }
```
There is no UI input field or settings panel to supply headers.
- **Test Failure**: Running `flutter test test/challenger_m3_1_test.dart` output:
```
00:00 +0 -1: Challenger M3-1 Empirical Verification Tests Adblocking filter logic with 15 different ad/tracker domains [E]
  Expected: true
    Actual: <false>
  Domain ads.yahoo.com was expected to be blocked by the adblocker filter.
  
00:02 +0 -2: Challenger M3-1 Empirical Verification Tests Popup suppression increments counter and reflects in UI [E]
  Expected: exactly one matching candidate
  Actual: _TextContainingWidgetFinder:<Found 0 widgets with text containing 3: []>
   Which: means none were found but one was expected
  UI was expected to display the number of blocked popups (3).
```

## 2. Logic Chain

1. **Adblocking Limit**:
   - The user requested testing adblocking with 15 tracker domains (e.g. `ads.yahoo.com`).
   - The implementation (both mock and real controllers) checks if the host is equal to, ends with, or contains any domain in `adDomains`.
   - Since `adDomains` only contains 5 domains, domains like `ads.yahoo.com` return `false` from `shouldBlockUrl`.
   - Thus, the test failed as expected, demonstrating that the adblocker filter logic is incomplete and fails to block standard tracker domains beyond the 5 hardcoded ones.

2. **Popup UI Display**:
   - The custom popup blocking handler correctly listens to `popup_blocked` events and increments the count inside `MockBrowserController`.
   - However, because there is no widget displaying `blockedPopupsCount` in `lib/sniffer/sniffer_screen.dart`, `find.textContaining('3')` finds 0 matching widgets.
   - Thus, the test failed, demonstrating that the UI fails to reflect/render the blocked popups count to the user.

3. **Custom Headers Config**:
   - While `SnifferBrowserController.loadRequest` supports a `headers` parameter, `SnifferScreen` never supplies it when navigations occur.
   - There is no custom headers configuration panel or header injection mechanism, indicating the custom headers feature is currently unintegrated in the application's UI/browser flow.

## 3. Caveats

- We utilized `MockBrowserController` inside widget tests instead of launching a physical WebView instance, as widget/unit tests run in a headless environment. However, since `SnifferWebViewControllerImpl` shares the identical `shouldBlockUrl` method and list, the behavior is identical.

## 4. Conclusion

Milestone 3 has several key implementation gaps and bugs:
1. **Adblocking** is restricted to only 5 hardcoded domains.
2. **Popup suppression counter** exists in state but is completely missing from the UI.
3. **Custom Headers** are implemented in the controller interface but completely missing from the UI and address loading logic.

These issues are empirically verified and reproducible by running `test/challenger_m3_1_test.dart`.

## 5. Verification Method

To reproduce the findings, execute the following command in the project root (`D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`):
```powershell
flutter test test/challenger_m3_1_test.dart
```

This will run the two empirical verification tests which are designed to verify the correct functioning of these features, and show the exact failures detailed in this report.
