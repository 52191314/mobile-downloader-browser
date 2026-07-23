import '../settings/download_settings.dart';
import 'external_scheme.dart';

class BrowserSearch {
  static Uri resolveInput(String rawInput, SearchEngine searchEngine) {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return Uri.parse(searchEngine.buildSearchUrl(input));
    }

    final parsed = Uri.tryParse(input);
    // http(s) with host, or app schemes without a host (tg:resolve?…, magnet:…).
    if (parsed != null && parsed.hasScheme) {
      if (parsed.host.isNotEmpty || isExternalAppUri(parsed)) {
        return parsed;
      }
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
