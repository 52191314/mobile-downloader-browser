import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class SearchSuggestionService {
  final http.Client _client;

  SearchSuggestionService({http.Client? client})
      : _client = client ?? http.Client();

  void dispose() {
    _client.close();
  }

  Future<List<String>> suggestions(
    String query, {
    String engine = 'duckduckgo',
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    if (engine == 'duckduckgo') {
      return _duckDuckGo(trimmed);
    }
    return const [];
  }

  Future<List<String>> _duckDuckGo(String query) async {
    try {
      final uri = Uri.parse(
        'https://duckduckgo.com/ac/?q=${Uri.encodeQueryComponent(query)}&type=list',
      );
      final response = await _client
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return const [];
      final body = response.body.trim();
      if (body.isEmpty) return const [];
      final decoded = jsonDecode(body);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }
}
