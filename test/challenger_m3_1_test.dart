import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/browser_controller.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/sniffer_screen.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  group('Challenger M3-1 Empirical Verification Tests', () {
    late MockBrowserController controller;
    late DownloadQueue downloadQueue;
    late MediaSnifferEngine snifferEngine;

    setUp(() {
      controller = MockBrowserController(initialUrl: 'https://example.com');
      downloadQueue = DownloadQueue();
      snifferEngine = MediaSnifferEngine();
    });

    tearDown(() {
      snifferEngine.dispose();
    });

    test('Adblocking filter logic with 15 different ad/tracker domains', () async {
      final adTrackerDomains = [
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

      final standardDomains = [
        'wikipedia.org',
        'flutter.dev',
        'github.com',
        'pub.dev',
      ];

      // Enable adblocker
      controller.adBlockerEnabled = true;

      // 1. Assert ad/tracker domains are blocked (should fail on domains not in the hardcoded list of 5)
      for (final domain in adTrackerDomains) {
        final url = 'https://$domain/some-path';
        final isBlocked = controller.shouldBlockUrl(url);
        expect(
          isBlocked,
          isTrue,
          reason:
              'Domain $domain was expected to be blocked by the adblocker filter.',
        );
      }

      // 2. Assert standard domains are NOT blocked
      for (final domain in standardDomains) {
        final url = 'https://$domain/some-path';
        final isBlocked = controller.shouldBlockUrl(url);
        expect(
          isBlocked,
          isFalse,
          reason:
              'Standard domain $domain was incorrectly blocked by the adblocker filter.',
        );
      }
    });

    testWidgets('Popup suppression increments counter and reflects in UI', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: controller,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      // Verify starting condition
      expect(controller.blockedPopupsCount, 0);

      // Trigger custom popup blocking handler inside MockBrowserController multiple times (3 times)
      controller.simulateJavaScriptMessage('AdBlockerChannel', 'popup_blocked');
      controller.simulateJavaScriptMessage('AdBlockerChannel', 'popup_blocked');
      controller.simulateJavaScriptMessage('AdBlockerChannel', 'popup_blocked');
      await tester.pumpAndSettle();

      // Assert that the blocked popup counter increases in controller
      expect(controller.blockedPopupsCount, 3);

      // Assert that the UI reflects the count (this should fail since the UI doesn't render it)
      await tester.tap(find.byKey(const Key('browser_menu_button')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Blocked popups: 3'),
        findsOneWidget,
        reason: 'Browser menu should display the number of blocked popups (3).',
      );
    });
  });
}
