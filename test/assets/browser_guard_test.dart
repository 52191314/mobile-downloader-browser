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
      final end = guard.indexOf('// --- invisible redirect blocking');

      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final windowOpenBlock = guard.substring(start, end);

      expect(windowOpenBlock, contains('PopupBlockerChannel.postMessage'));
      expect(windowOpenBlock, isNot(contains('postLinkContext')));
    });

    test('text selection can use Aurora context sheet without native menu', () {
      expect(guard, contains('function hasSelectedContextText()'));
      expect(
        guard,
        contains(
          '!shouldInterceptContext(event.target) && !hasSelectedContextText()',
        ),
      );
      expect(
        guard,
        contains('if (!ctx.href && !ctx.src && !ctx.selectedText) return;'),
      );
    });
  });
}
