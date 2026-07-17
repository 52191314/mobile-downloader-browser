import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Fetches type-ahead search suggestions for the browser address bar.
///
/// Supports engine-specific OpenSearch / autocomplete endpoints:
/// - DuckDuckGo (default / privacy)
/// - Google (Firefox client — no API key)
/// - Bing
/// - Brave (falls back to DuckDuckGo)
class SearchSuggestionService {
  final http.Client _client;
  final bool _ownsClient;

  SearchSuggestionService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  void dispose() {
    if (_ownsClient) _client.close();
  }

  /// Returns up to [limit] suggestion phrases for [query].
  ///
  /// [engineId] matches [SearchEngine.id] (`google`, `duckduckgo`, `bing`,
  /// `brave`, or custom).
  Future<List<String>> suggestions(
    String query, {
    String engineId = 'duckduckgo',
    int limit = 8,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final id = engineId.toLowerCase();
    List<String> raw;
    try {
      if (id == 'google') {
        raw = await _google(trimmed);
      } else if (id == 'bing') {
        raw = await _bing(trimmed);
      } else {
        // duckduckgo, brave, custom — DDG is reliable and keyless.
        raw = await _duckDuckGo(trimmed);
      }
    } catch (_) {
      raw = const [];
    }
    if (raw.isEmpty) return const [];
    // Drop exact duplicate of the typed query and empty strings.
    final out = <String>[];
    final seen = <String>{};
    final qLower = trimmed.toLowerCase();
    for (final s in raw) {
      final t = s.trim();
      if (t.isEmpty) continue;
      final key = t.toLowerCase();
      if (key == qLower) continue;
      if (!seen.add(key)) continue;
      out.add(t);
      if (out.length >= limit) break;
    }
    return out;
  }

  Future<List<String>> _duckDuckGo(String query) async {
    // Default JSON: [{"phrase":"..."}, ...]
    final uri = Uri.parse(
      'https://duckduckgo.com/ac/?q=${Uri.encodeQueryComponent(query)}',
    );
    final response = await _get(uri);
    if (response == null) return const [];
    return _parsePhraseObjects(response) ??
        _parseOpenSearchList(response) ??
        const [];
  }

  Future<List<String>> _google(String query) async {
    // Firefox client returns OpenSearch JSON: ["query", ["s1","s2",...]]
    final uri = Uri.parse(
      'https://suggestqueries.google.com/complete/search'
      '?client=firefox&q=${Uri.encodeQueryComponent(query)}',
    );
    final response = await _get(uri);
    if (response == null) return const [];
    return _parseOpenSearchList(response) ?? const [];
  }

  Future<List<String>> _bing(String query) async {
    // OpenSearch JSON: ["query", ["s1","s2",...]]
    final uri = Uri.parse(
      'https://api.bing.com/osjson.aspx?query=${Uri.encodeQueryComponent(query)}',
    );
    final response = await _get(uri);
    if (response == null) return const [];
    return _parseOpenSearchList(response) ?? const [];
  }

  Future<String?> _get(Uri uri) async {
    try {
      final response = await _client
          .get(
            uri,
            headers: const {
              'Accept': 'application/json, text/javascript, */*',
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;
      final body = response.body.trim();
      return body.isEmpty ? null : body;
    } catch (_) {
      return null;
    }
  }

  /// Parses `[{"phrase":"foo"}, ...]` (DuckDuckGo default).
  static List<String>? _parsePhraseObjects(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List || decoded.isEmpty) return null;
      if (decoded.first is! Map) return null;
      final out = <String>[];
      for (final item in decoded) {
        if (item is Map && item['phrase'] is String) {
          out.add(item['phrase'] as String);
        }
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// Parses OpenSearch / DDG `type=list` shape: `["query", ["s1","s2",...]]`.
  static List<String>? _parseOpenSearchList(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List || decoded.length < 2) return null;
      final second = decoded[1];
      if (second is List) {
        return second.whereType<String>().toList(growable: false);
      }
      // Some endpoints return flat string lists after the query.
      return decoded.skip(1).whereType<String>().toList(growable: false);
    } catch (_) {
      return null;
    }
  }
}
