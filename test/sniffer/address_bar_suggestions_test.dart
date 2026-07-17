import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/sniffer/controllers/address_bar_controller.dart';

void main() {
  group('AddressBarController URL heuristic', () {
    // Expose private helper via the same rules by exercising refresh
    // through a thin wrapper: we only assert public behavior.

    test('multi-word queries are treated as search (not navigable URL)', () {
      // Spaces must never look like navigable URLs — otherwise remote
      // search suggestions are skipped entirely.
      expect(
        AddressBarController.looksLikeNavigableUrlForTest('hello world'),
        isFalse,
      );
      expect(
        AddressBarController.looksLikeNavigableUrlForTest('flutter dart'),
        isFalse,
      );
    });

    test('scheme URLs and bare hosts are navigable', () {
      expect(
        AddressBarController.looksLikeNavigableUrlForTest(
          'https://example.com/path',
        ),
        isTrue,
      );
      expect(
        AddressBarController.looksLikeNavigableUrlForTest('example.com'),
        isTrue,
      );
      expect(
        AddressBarController.looksLikeNavigableUrlForTest('example.com/foo'),
        isTrue,
      );
    });

    test('single search words are not navigable URLs', () {
      expect(
        AddressBarController.looksLikeNavigableUrlForTest('youtube'),
        isFalse,
      );
      expect(
        AddressBarController.looksLikeNavigableUrlForTest('weather'),
        isFalse,
      );
    });
  });
}
