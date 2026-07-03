import '../settings/download_settings.dart';

class BrowserSearch {
  static Uri resolveInput(String rawInput, SearchEngine searchEngine) {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return Uri.parse(searchEngine.buildSearchUrl(input));
    }

    final parsed = Uri.tryParse(input);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      return parsed;
    }

    if (_looksLikeHost(input)) {
      return Uri.parse('https://$input');
    }

    return Uri.parse(searchEngine.buildSearchUrl(input));
  }

  static bool _looksLikeHost(String input) {
    if (input.contains(RegExp(r'\s'))) return false;
    if (input.startsWith('?')) return false;
    final host = input.split('/').first.split(':').first;
    return host.contains('.') && !host.startsWith('.') && !host.endsWith('.');
  }
}
