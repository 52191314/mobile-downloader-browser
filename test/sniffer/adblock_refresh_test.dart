import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/ad_block_engine_native.dart';

void main() {
  test('adblock: stale sources retry once and report loaded status', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('server error', 500);
      return http.Response('||ads.example.com^\n##.ad-banner\n', 200);
    });

    final engine = await AdBlockEngine.fromFilterSources(
      enabled: true,
      sources: const [
        AdblockFilterSource(
          name: 'Mock List',
          url: 'https://example.com/list.txt',
        ),
      ],
      client: client,
    );

    // The 500 was retried once, then the list loaded.
    expect(calls, 2);
    expect(engine.sourceStatuses.single.state, AdblockSourceLoadState.loaded);
    expect(engine.sourceStatuses.single.ruleCount, 2);
    expect(engine.sourceStatuses.single.errorMessage, isNull);
  });

  test('adblock: double timeout reports failed with message', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      // Simulate a network that never answers.
      throw TimeoutException('timed out');
    });

    final engine = await AdBlockEngine.fromFilterSources(
      enabled: true,
      sources: const [
        AdblockFilterSource(
          name: 'Timeout List',
          url: 'https://example.com/timeout.txt',
        ),
      ],
      client: client,
    );

    expect(calls, 2); // first attempt + retry
    expect(engine.sourceStatuses.single.state, AdblockSourceLoadState.failed);
    expect(engine.sourceStatuses.single.errorMessage, contains('timed out'));
  });

  test('adblock: !#include stubs are resolved (uAssets annoyances pattern)',
      () async {
    final client = MockClient((request) async {
      // Stub list that includes its real rules from a sibling file.
      if (request.url.toString() == 'https://example.com/annoy.txt') {
        return http.Response(
          '! stub\n!#include annoy-others.txt\n##.cookie-banner\n',
          200,
        );
      }
      if (request.url.toString() == 'https://example.com/annoy-others.txt') {
        return http.Response('||ads.tracker.example^\n###newsletter-popup\n', 200);
      }
      return http.Response('not found', 404);
    });

    final engine = await AdBlockEngine.fromFilterSources(
      enabled: true,
      sources: const [
        AdblockFilterSource(
          name: 'Annoy Stub',
          url: 'https://example.com/annoy.txt',
        ),
      ],
      client: client,
    );

    // Stub's own rule + the 2 rules from the included file.
    expect(engine.sourceStatuses.single.state, AdblockSourceLoadState.loaded);
    expect(engine.sourceStatuses.single.ruleCount, 3);
  });

  test('adblock: annoyances list ships enabled by default', () {
    final annoyances = AdblockFilterSource.trustedSources
        .where((s) => s.name.contains('Annoyances'))
        .toList();
    // uBlock + AdGuard annoyances lists both ship; uBlock's is on by default.
    expect(annoyances, hasLength(2));
    expect(
      annoyances.firstWhere((s) => s.name.contains('uBlock')).enabled,
      isTrue,
    );
  });

  test('adblock: removeparam rules strip params, never block domains', () {
    const text = '''
! AdGuard URL Tracking sample
\$removeparam=utm_source
||youtube.com^\$removeparam=feature
||supply.amazon.com/ref^\$removeparam=ref_
@@||example.com^\$removeparam=via
/checkout\$removeparam=fbclid
''';
    final parsed = AdBlockEngine.parseFilterText(text);

    // None of the removeparam lines became block rules — youtube.com must
    // NOT be blocked (this was the over-blocking bug).
    expect(
      parsed.networkRules.where((r) => r.pattern.contains('youtube')),
      isEmpty,
    );
    expect(parsed.networkRules.where((r) => r.pattern.contains('amazon')), isEmpty);
    expect(
      parsed.networkRules.where((r) => r.pattern.contains('example.com')),
      isEmpty,
    );

    expect(parsed.removeParamRules, hasLength(5));
    final engine = AdBlockEngine(
      enabled: true,
      rules: parsed.networkRules,
      removeParamRules: parsed.removeParamRules,
    );

    // Generic rule strips utm_source from any URL.
    expect(
      engine.stripTrackingParams('https://news.example/a?utm_source=x&id=1'),
      'https://news.example/a?id=1',
    );
    // Domain rule only matches its host (and subdomains).
    expect(
      engine.stripTrackingParams(
          'https://youtube.com/watch?v=abc&feature=share'),
      'https://youtube.com/watch?v=abc',
    );
    expect(
      engine.stripTrackingParams('https://other.com/watch?feature=share'),
      isNull,
    );
    // Host+path rule.
    expect(
      engine.stripTrackingParams(
          'https://supply.amazon.com/ref/p?ref_=x&k=1'),
      'https://supply.amazon.com/ref/p?k=1',
    );
    // Path-only rule.
    expect(
      engine.stripTrackingParams('https://shop.example/checkout?fbclid=9&x=1'),
      'https://shop.example/checkout?x=1',
    );
    // Non-matching URLs are untouched.
    expect(
      engine.stripTrackingParams('https://shop.example/home?fbclid=9'),
      isNull,
    );
  });

  test('adblock: removeparam rules never reach the native engine text',
      () async {
    final engine = await AdBlockEngine.fromFilterSources(
      enabled: true,
      sources: const [
        AdblockFilterSource(
          name: 'Mock TrackParam',
          url: 'https://example.com/trackparam.txt',
        ),
      ],
      client: MockClient((request) async {
        if (request.url.toString() == 'https://example.com/trackparam.txt') {
          return http.Response(
            '||youtube.com^\$removeparam=feature\n||ads.example.com^\n',
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

    // The real block rule survives; the removeparam line is gone from the
    // raw text the native engine parses (its parser strips $ modifiers and
    // would otherwise block youtube.com entirely).
    expect(engine.sourceStatuses.single.state, AdblockSourceLoadState.loaded);
    expect(
      engine.rules.where((r) => r.pattern == 'ads.example.com'),
      hasLength(1),
    );
    expect(engine.rawRulesText, isNot(contains('removeparam')));
    expect(engine.rawRulesText, contains('ads.example.com'));
    expect(
      engine.removeParamRules.where((r) => r.param == 'feature'),
      hasLength(1),
    );
  });
}
