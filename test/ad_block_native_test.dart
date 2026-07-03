import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/ad_block_engine_native.dart';
import 'package:aurora_downloader/settings/download_settings.dart';

void main() {
  group('AdBlockEngine Native Integration & Fallback Tests', () {
    test('Rule serialization correctness', () {
      final rules = AdBlockEngine.parseRules(r'''
        ||googleads.g.doubleclick.net^
        @@||example.com^$document
        *ads*
        /regex-[0-9]+/
      ''');

      expect(rules.length, equals(4));

      final serialized = AdBlockEngine.serializeRules(rules);
      expect(serialized, contains('||googleads.g.doubleclick.net^'));
      expect(serialized, contains('@@||example.com^'));
      expect(serialized, contains('ads'));
      expect(serialized, contains('regex-[0-9]+'));
    });

    test('Cosmetic rule serialization correctness', () {
      final rules = AdBlockEngine.parseRules('');
      final cosmetics = [
        CosmeticAdRule(host: 'example.com', selector: '.ad-banner'),
        CosmeticAdRule(host: '', selector: '#ad-box'),
      ];
      final serialized = AdBlockEngine.serializeRules(rules, cosmeticRules: cosmetics);
      expect(serialized, contains('example.com##.ad-banner'));
      expect(serialized, contains('###ad-box'));
    });

    test('Graceful fallback when native .so is not available', () {
      // On desktop test runners (Windows/macOS/Linux), DynamicLibrary.open('libaurora_adblock.so')
      // is expected to fail. The engine must fall back to the Dart implementation.
      final engine = AdBlockEngine.builtIn(enabled: true);

      // Verify that blocking behaves correctly via Dart fallback
      expect(engine.shouldBlockUrl('https://doubleclick.net/ad'), isTrue);
      expect(engine.shouldBlockUrl('https://googleads.g.doubleclick.net/test'), isTrue);
      expect(engine.shouldBlockUrl('https://example.com/ok'), isFalse);
    });

    test('AdBlockRule matches behavior is intact', () {
      final engine = AdBlockEngine(
        enabled: true,
        rules: AdBlockEngine.parseRules('''
          ||googleads.g.doubleclick.net^
          @@||example.com^
        '''),
      );

      expect(engine.shouldBlockUrl('http://googleads.g.doubleclick.net/path'), isTrue);
      expect(engine.shouldBlockUrl('http://sub.googleads.g.doubleclick.net/path'), isTrue);
      expect(engine.shouldBlockUrl('http://example.com/ad'), isFalse);
    });

    test('Element hiding matches behavior is intact', () {
      final engine = AdBlockEngine(
        enabled: true,
        rules: const [],
        cosmeticRules: [
          CosmeticAdRule(host: 'example.com', selector: '.ad-banner'),
          CosmeticAdRule(host: '', selector: '#ad-box'),
        ],
      );

      expect(
        engine.shouldHideElement(
          'example.com',
          const ElementDescriptor(host: 'example.com', classes: ['ad-banner']),
        ),
        isTrue,
      );
      expect(
        engine.shouldHideElement(
          'other.com',
          const ElementDescriptor(host: 'other.com', id: 'ad-box'),
        ),
        isTrue,
      );
      expect(
        engine.shouldHideElement(
          'other.com',
          const ElementDescriptor(host: 'other.com', classes: ['ad-banner']),
        ),
        isFalse,
      );
    });

    test('Exact match anchoring behavior (Dart fallback)', () {
      final engine = AdBlockEngine(
        enabled: true,
        rules: AdBlockEngine.parseRules('|http://example.com/|'),
      );
      expect(engine.shouldBlockUrl('http://example.com/'), isTrue);
    });
  });
}
