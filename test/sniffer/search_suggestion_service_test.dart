import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/sniffer/search_suggestion_service.dart';

void main() {
  group('SearchSuggestionService', () {
    test('parses DuckDuckGo phrase objects', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'duckduckgo.com');
        return http.Response(
          '[{"phrase":"youtube"},{"phrase":"youtube music"}]',
          200,
        );
      });
      final service = SearchSuggestionService(client: client);
      final out = await service.suggestions('you', engineId: 'duckduckgo');
      expect(out, ['youtube', 'youtube music']);
      service.dispose();
    });

    test('parses OpenSearch list (Google/Bing/DDG type=list)', () async {
      final client = MockClient((request) async {
        return http.Response(
          '["you",["youtube","youtube music","youtube kids"]]',
          200,
        );
      });
      final service = SearchSuggestionService(client: client);
      final out = await service.suggestions('you', engineId: 'google');
      expect(out, ['youtube', 'youtube music', 'youtube kids']);
      service.dispose();
    });

    test('drops exact query duplicate and respects limit', () async {
      final client = MockClient((request) async {
        return http.Response(
          '[{"phrase":"you"},{"phrase":"youtube"},{"phrase":"youtube"}]',
          200,
        );
      });
      final service = SearchSuggestionService(client: client);
      final out = await service.suggestions(
        'you',
        engineId: 'duckduckgo',
        limit: 1,
      );
      expect(out, ['youtube']);
      service.dispose();
    });

    test('returns empty on non-200', () async {
      final client = MockClient((request) async {
        return http.Response('nope', 500);
      });
      final service = SearchSuggestionService(client: client);
      final out = await service.suggestions('you');
      expect(out, isEmpty);
      service.dispose();
    });
  });
}
