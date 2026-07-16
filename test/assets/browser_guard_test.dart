import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('browser_guard context menu routing', () {
    late final String guard;

    setUpAll(() {
      guard = File('assets/browser_guard.js').readAsStringSync();
    });

    test('blocked window.open does not emit LinkContextChannel payloads', () {
      final start = guard.indexOf('window.open = function(url, name, specs)');
      final end = guard.indexOf('// --- long press and context menu ---');

      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final windowOpenBlock = guard.substring(start, end);

      expect(windowOpenBlock, contains('AdBlockerChannel.postMessage'));
      expect(windowOpenBlock, isNot(contains('postLinkContext')));
    });

    test('text selection can use Aurora context sheet without native menu', () {
      expect(guard, contains('function hasTextSelection()'));
      expect(
        guard,
        contains(
          'if (hasTextSelection()) return;',
        ),
      );
      expect(
        guard,
        contains('TextSelectionChannel.postMessage(text)'),
      );
    });
  });
}
