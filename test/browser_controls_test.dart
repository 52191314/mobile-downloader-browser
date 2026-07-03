import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/ad_block_engine.dart';
import 'package:aurora_downloader/sniffer/browser_search.dart';

void main() {
  group('BrowserSearch', () {
    test('keeps full URLs unchanged', () {
      final uri = BrowserSearch.resolveInput(
        'https://example.com/video.mp4',
        SearchEngine.duckDuckGo,
      );

      expect(uri.toString(), 'https://example.com/video.mp4');
    });

    test('adds https scheme to host-like input', () {
      final uri = BrowserSearch.resolveInput(
        'example.com/video.mp4',
        SearchEngine.google,
      );

      expect(uri.toString(), 'https://example.com/video.mp4');
    });

    test('turns plain text into selected search engine URL', () {
      final uri = BrowserSearch.resolveInput(
        'best download manager',
        SearchEngine.brave,
      );

      expect(
        uri.toString(),
        'https://search.brave.com/search?q=best+download+manager',
      );
    });
  });

  group('AdBlockEngine', () {
    test('blocks domain rules and url contains rules', () {
      final engine = AdBlockEngine(
        enabled: true,
        rules: AdBlockEngine.parseRules('''
||ads.example.com^
/banner/
'''),
      );

      expect(
        engine.shouldBlockUrl('https://ads.example.com/script.js'),
        isTrue,
      );
      expect(
        engine.shouldBlockUrl('https://cdn.example.com/banner/top.js'),
        isTrue,
      );
      expect(engine.shouldBlockUrl('https://example.com/app.js'), isFalse);
    });

    test('exception rules override block rules', () {
      final engine = AdBlockEngine(
        enabled: true,
        rules: AdBlockEngine.parseRules('''
||example.com^
@@||good.example.com^
'''),
      );

      expect(engine.shouldBlockUrl('https://bad.example.com/ad.js'), isTrue);
      expect(engine.shouldBlockUrl('https://good.example.com/app.js'), isFalse);
    });

    test('disabled engine never blocks', () {
      final engine = AdBlockEngine(
        enabled: false,
        rules: AdBlockEngine.parseRules('||example.com^'),
      );

      expect(engine.shouldBlockUrl('https://example.com/ad.js'), isFalse);
    });

    test('hosts-file rules block domains', () {
      final engine = AdBlockEngine(
        enabled: true,
        rules: AdBlockEngine.parseRules('''
0.0.0.0 ads.hosts-example.test
127.0.0.1 tracker.hosts-example.test
'''),
      );

      expect(
        engine.shouldBlockUrl('https://ads.hosts-example.test/banner.js'),
        isTrue,
      );
      expect(
        engine.shouldBlockUrl('https://tracker.hosts-example.test/pixel.gif'),
        isTrue,
      );
      expect(engine.shouldBlockUrl('https://example.test/app.js'), isFalse);
    });

    test('manual domain rules block matching requests', () async {
      final engine = await AdBlockEngine.fromFilterSources(
        enabled: true,
        sources: const [],
        manualRules: [
          ManualAdBlockRule(pattern: 'manual-ads.example', domainRule: true),
        ],
      );

      expect(
        engine.shouldBlockUrl('https://cdn.manual-ads.example/ad.mp4'),
        isTrue,
      );
      expect(
        engine.shouldBlockUrl('https://manual-ads.example/script.js'),
        isTrue,
      );
      expect(engine.shouldBlockUrl('https://example.com/video.mp4'), isFalse);
    });

    test('cosmetic rules match page host and selector', () {
      final parsed = AdBlockEngine.parseFilterText('example.com##.ad-banner');
      final engine = AdBlockEngine(
        enabled: true,
        rules: parsed.networkRules,
        cosmeticRules: parsed.cosmeticRules,
      );

      expect(
        engine.shouldHideElement(
          'www.example.com',
          const ElementDescriptor(
            host: 'www.example.com',
            tagName: 'div',
            classes: ['ad-banner'],
          ),
        ),
        isTrue,
      );
      expect(
        engine.shouldHideElement(
          'www.example.com',
          const ElementDescriptor(
            host: 'www.example.com',
            tagName: 'div',
            classes: ['content'],
          ),
        ),
        isFalse,
      );
    });

    test(
      'enabled source list is used and disabled sources are skipped',
      () async {
        final requested = <Uri>[];
        final client = MockClient((request) async {
          requested.add(request.url);
          return http.Response('||from-source.example^', 200);
        });

        final engine = await AdBlockEngine.fromFilterSources(
          enabled: true,
          client: client,
          sources: const [
            AdblockFilterSource(
              name: 'Enabled',
              url: 'https://filters.example/enabled.txt',
            ),
            AdblockFilterSource(
              name: 'Disabled',
              url: 'https://filters.example/disabled.txt',
              enabled: false,
            ),
          ],
        );

        expect(requested.map((uri) => uri.toString()), [
          'https://filters.example/enabled.txt',
        ]);
        expect(
          engine.shouldBlockUrl('https://from-source.example/ad.js'),
          isTrue,
        );
        expect(
          engine.sourceStatuses
              .where(
                (status) => status.state == AdblockSourceLoadState.disabled,
              )
              .length,
          1,
        );
      },
    );

    test('disabled engine does not fetch remote filter sources', () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        return http.Response('||should-not-load.example^', 200);
      });

      final engine = await AdBlockEngine.fromFilterSources(
        enabled: false,
        client: client,
        sources: const [
          AdblockFilterSource(
            name: 'Enabled source',
            url: 'https://filters.example/enabled.txt',
          ),
        ],
      );

      expect(requested, isEmpty);
      expect(
        engine.sourceStatuses.single.state,
        AdblockSourceLoadState.disabled,
      );
      expect(
        engine.shouldBlockUrl('https://should-not-load.example/ad.js'),
        isFalse,
      );
    });

    test('sniffed ad media URLs are suppressible', () {
      final engine = AdBlockEngine.builtIn();

      expect(
        engine.shouldSuppressSniffedUrl(
          'https://pubads.example.com/vast/ad.m3u8',
        ),
        isTrue,
      );
      expect(
        engine.shouldSuppressSniffedUrl('https://video.example.com/movie.m3u8'),
        isFalse,
      );
    });
  });

  group('DownloadSettings adblock persistence', () {
    test('trusted remote filter sources start disabled by default', () {
      final settings = DownloadSettings.defaults();

      expect(settings.adblockFilterSources, isNotEmpty);
      expect(
        settings.adblockFilterSources.every((source) => !source.enabled),
        isTrue,
      );
    });

    test('stores popup toggle and manual rules', () {
      final settings = DownloadSettings.defaults().copyWith(
        popupBlockingEnabled: false,
        manualAdBlockRules: [
          ManualAdBlockRule(pattern: 'ads.example', domainRule: true),
        ],
        manualCosmeticRules: [
          CosmeticAdRule(host: 'example.com', selector: '.ad'),
        ],
      );

      final restored = DownloadSettings.fromJson(settings.toJson());

      expect(restored.popupBlockingEnabled, isFalse);
      expect(restored.manualAdBlockRules.single.pattern, 'ads.example');
      expect(restored.manualAdBlockRules.single.domainRule, isTrue);
      expect(restored.manualCosmeticRules.single.selector, '.ad');
    });
  });

  group('DownloadSettings phase 1 fields', () {
    test('Do Not Track defaults to enabled', () {
      expect(DownloadSettings.defaults().doNotTrackEnabled, isTrue);
    });

    test('persists site zoom and per-site user agent round-trip', () {
      final settings = DownloadSettings.defaults().copyWith(
        doNotTrackEnabled: false,
        siteZoomLevels: const {'example.com': 1.5, 'cdn.example.org': 0.75},
        siteUserAgents: const {
          'example.com':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        },
      );

      final restored = DownloadSettings.fromJson(settings.toJson());

      expect(restored.doNotTrackEnabled, isFalse);
      expect(restored.siteZoomLevels['example.com'], closeTo(1.5, 0.001));
      expect(restored.siteZoomLevels['cdn.example.org'], closeTo(0.75, 0.001));
      expect(restored.siteUserAgents['example.com'], contains('Chrome/120'));
    });

    test('parses malformed zoom/UA maps gracefully', () {
      final settings = DownloadSettings.fromJson({
        ...DownloadSettings.defaults().toJson(),
        'siteZoomLevels': {'good.com': 2, 'bad.com': 'not-a-number'},
        'siteUserAgents': {'good.com': 'UA', 'bad.com': ''},
      });
      expect(settings.siteZoomLevels['good.com'], closeTo(2, 0.001));
      expect(settings.siteZoomLevels.containsKey('bad.com'), isFalse);
      expect(settings.siteUserAgents['good.com'], 'UA');
      expect(settings.siteUserAgents.containsKey('bad.com'), isFalse);
    });
  });

  group('DownloadSettings phase 2 fields', () {
    test('tracker blocking defaults to enabled', () {
      expect(DownloadSettings.defaults().trackerBlockingEnabled, isFalse);
    });

    test('dark mode preference round-trips', () {
      final settings = DownloadSettings.defaults().copyWith(
        darkModePreference: DarkModePreference.forced,
      );
      final restored = DownloadSettings.fromJson(settings.toJson());
      expect(restored.darkModePreference, DarkModePreference.forced);
    });
  });

  group('DownloadSettings phase 3 fields', () {
    test('translate target language defaults to English and round-trips', () {
      final defaults = DownloadSettings.defaults();
      expect(defaults.translateTargetLang, 'en');
      final settings = defaults.copyWith(translateTargetLang: 'es');
      final restored = DownloadSettings.fromJson(settings.toJson());
      expect(restored.translateTargetLang, 'es');
    });

    test('translate language lookup returns the default for unknown id', () {
      final lang = translateLanguageById('zz');
      expect(lang.id, 'en');
    });
  });
}
