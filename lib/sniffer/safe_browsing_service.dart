import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum SafeBrowsingVerdict { safe, suspicious, malicious, unknown }

class SafeBrowsingResult {
  final SafeBrowsingVerdict verdict;
  final String? reason;
  final String? source;

  const SafeBrowsingResult({
    required this.verdict,
    this.reason,
    this.source,
  });
}

class SafeBrowsingService {
  final http.Client _client;
  final Duration _timeout;
  List<String>? _memoryBlocklist;
  Set<String>? _memoryWhitelist;

  SafeBrowsingService({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 6);

  void dispose() {
    _client.close();
  }

  Future<File> _whitelistFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/safe_browsing_whitelist.json');
  }

  Future<Set<String>> _loadWhitelist() async {
    if (_memoryWhitelist != null) return _memoryWhitelist!;
    try {
      final file = await _whitelistFile();
      if (!await file.exists()) {
        _memoryWhitelist = {};
        return {};
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _memoryWhitelist = decoded.whereType<String>().toSet();
      } else {
        _memoryWhitelist = {};
      }
    } catch (_) {
      _memoryWhitelist = {};
    }
    return _memoryWhitelist!;
  }

  Future<void> whitelistHost(String host) async {
    final wl = await _loadWhitelist();
    wl.add(host.toLowerCase());
    try {
      final file = await _whitelistFile();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(jsonEncode(wl.toList()));
    } catch (_) {}
  }

  Future<bool> isHostWhitelisted(String host) async {
    final wl = await _loadWhitelist();
    final h = host.toLowerCase();
    for (final entry in wl) {
      if (h == entry || h.endsWith('.$entry')) {
        return true;
      }
    }
    return false;
  }

  /// Checks a URL against the local blocklist first, then falls back to
  /// a lightweight heuristic that flags known TLDs and suspicious patterns.
  Future<SafeBrowsingResult> check(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return const SafeBrowsingResult(
        verdict: SafeBrowsingVerdict.unknown,
        reason: 'Invalid URL',
      );
    }
    final host = uri.host.toLowerCase();

    if (await isHostWhitelisted(host)) {
      return const SafeBrowsingResult(verdict: SafeBrowsingVerdict.safe);
    }

    final local = await _loadLocalBlocklist();
    for (final entry in local) {
      if (host == entry || host.endsWith('.$entry')) {
        return SafeBrowsingResult(
          verdict: SafeBrowsingVerdict.malicious,
          reason: 'Local blocklist match: $entry',
          source: 'local',
        );
      }
    }

    final heuristic = _heuristicCheck(host);
    if (heuristic != null) return heuristic;

    return const SafeBrowsingResult(verdict: SafeBrowsingVerdict.safe);
  }

  SafeBrowsingResult? _heuristicCheck(String host) {
    if (host.split('.').length > 5) {
      return SafeBrowsingResult(
        verdict: SafeBrowsingVerdict.suspicious,
        reason: 'Unusually deep subdomain',
        source: 'heuristic',
      );
    }
    if (RegExp(r'^[a-z0-9]{16,}\.').hasMatch(host)) {
      return SafeBrowsingResult(
        verdict: SafeBrowsingVerdict.suspicious,
        reason: 'Long random-looking subdomain',
        source: 'heuristic',
      );
    }
    final suspiciousTlds = {
      '.zip',
      '.review',
      '.country',
      '.kim',
      '.cricket',
      '.science',
      '.work',
      '.party',
    };
    for (final tld in suspiciousTlds) {
      if (host.endsWith(tld)) {
        return SafeBrowsingResult(
          verdict: SafeBrowsingVerdict.suspicious,
          reason: 'Frequent abuse TLD: $tld',
          source: 'heuristic',
        );
      }
    }
    final punycode = RegExp(r'xn--');
    if (punycode.hasMatch(host)) {
      return SafeBrowsingResult(
        verdict: SafeBrowsingVerdict.suspicious,
        reason: 'Punycode host (possible lookalike)',
        source: 'heuristic',
      );
    }
    return null;
  }

  Future<List<String>> _loadLocalBlocklist() async {
    if (_memoryBlocklist != null) return _memoryBlocklist!;
    final cached = await _readCache();
    if (cached.isNotEmpty) {
      _memoryBlocklist = cached;
      return cached;
    }
    final remote = await _fetchAndCacheRemote();
    _memoryBlocklist = remote;
    return remote;
  }

  Future<List<String>> _readCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        return decoded
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _fetchAndCacheRemote() async {
    const url =
        'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-links-NEW-today.txt';
    try {
      final response = await _client
          .get(Uri.parse(url))
          .timeout(_timeout);
      if (response.statusCode != 200) return const [];
      final lines = response.body
          .split('\n')
          .map((line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || trimmed.startsWith('#')) return '';
            final uri = Uri.tryParse(trimmed);
            return uri?.host.toLowerCase() ?? '';
          })
          .where((host) => host.isNotEmpty)
          .toSet()
          .take(2000)
          .toList(growable: false);
      await _writeCache(lines);
      return lines;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeCache(List<String> hosts) async {
    try {
      final file = await _cacheFile();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(jsonEncode(hosts));
    } catch (_) {}
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/phishing_blocklist_cache.json');
  }
}

class FakeSafeBrowsingService extends SafeBrowsingService {
  FakeSafeBrowsingService() : super();

  @override
  Future<SafeBrowsingResult> check(String url) async {
    return const SafeBrowsingResult(verdict: SafeBrowsingVerdict.safe);
  }
}

bool isRunningInTest() {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}
