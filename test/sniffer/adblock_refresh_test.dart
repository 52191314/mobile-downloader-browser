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
}
