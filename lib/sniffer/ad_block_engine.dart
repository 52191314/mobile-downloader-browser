import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../settings/download_settings.dart';

enum AdBlockRuleType { domain, contains }

enum AdblockSourceLoadState { disabled, loaded, failed }

class AdblockSourceStatus {
  final String url;
  final AdblockSourceLoadState state;
  final int ruleCount;
  final String? errorMessage;

  const AdblockSourceStatus({
    required this.url,
    required this.state,
    this.ruleCount = 0,
    this.errorMessage,
  });
}

class ElementDescriptor {
  final String host;
  final String tagName;
  final String id;
  final List<String> classes;
  final String? src;
  final String? href;
  final String? textHint;

  const ElementDescriptor({
    required this.host,
    this.tagName = '',
    this.id = '',
    this.classes = const [],
    this.src,
    this.href,
    this.textHint,
  });
}

class BlockedPopupEvent {
  final String? url;
  final String? sourcePageUrl;
  final String? frameUrl;
  final bool userInitiated;
  final String reason;

  const BlockedPopupEvent({
    this.url,
    this.sourcePageUrl,
    this.frameUrl,
    this.userInitiated = false,
    this.reason = 'popup',
  });

  factory BlockedPopupEvent.fromJson(Map<String, dynamic> json) {
    return BlockedPopupEvent(
      url: json['url'] as String?,
      sourcePageUrl: json['sourcePageUrl'] as String?,
      frameUrl: json['frameUrl'] as String?,
      userInitiated: json['userInitiated'] as bool? ?? false,
      reason: json['reason'] as String? ?? 'popup',
    );
  }
}

class AdBlockRule {
  final AdBlockRuleType type;
  final String pattern;
  final bool isException;
  final String _normalizedPattern;

  AdBlockRule({
    required this.type,
    required this.pattern,
    this.isException = false,
  }) : _normalizedPattern = pattern.toLowerCase();

  String get normalizedPattern => _normalizedPattern;

  bool matches(Uri uri, String rawUrl) {
    final host = uri.host.toLowerCase();
    final url = rawUrl.toLowerCase();
    return switch (type) {
      AdBlockRuleType.domain =>
        host == _normalizedPattern || host.endsWith('.$_normalizedPattern'),
      AdBlockRuleType.contains => url.contains(_normalizedPattern),
    };
  }
}

class AdBlockParseResult {
  final List<AdBlockRule> networkRules;
  final List<CosmeticAdRule> cosmeticRules;

  const AdBlockParseResult({
    required this.networkRules,
    required this.cosmeticRules,
  });
}

class AdBlockEngine {
  static const Duration _filterSourceTimeout = Duration(seconds: 6);
  static const int _maxCacheSize = 5000;

  final bool enabled;
  final List<AdBlockRule> rules;
  final List<CosmeticAdRule> cosmeticRules;
  final List<AdblockSourceStatus> sourceStatuses;

  // Indexes for fast rule lookup.
  final Map<String, List<AdBlockRule>> _domainBlockRules = {};
  final Map<String, List<AdBlockRule>> _domainExceptionRules = {};
  final List<AdBlockRule> _containsBlockRules = [];
  final List<AdBlockRule> _containsExceptionRules = [];

  // LRU cache keyed by raw URL.
  final LinkedHashMap<String, bool> _blockCache = LinkedHashMap<String, bool>();

  AdBlockEngine({
    required this.enabled,
    required this.rules,
    this.cosmeticRules = const [],
    this.sourceStatuses = const [],
  }) {
    _buildIndexes();
  }

  void _buildIndexes() {
    for (final rule in rules) {
      switch (rule.type) {
        case AdBlockRuleType.domain:
          final map = rule.isException
              ? _domainExceptionRules
              : _domainBlockRules;
          map.putIfAbsent(rule.normalizedPattern, () => []).add(rule);
        case AdBlockRuleType.contains:
          if (rule.isException) {
            _containsExceptionRules.add(rule);
          } else {
            _containsBlockRules.add(rule);
          }
      }
    }
  }

  factory AdBlockEngine.builtIn({bool enabled = true}) {
    final parsed = parseFilterText(_builtInRules);
    return AdBlockEngine(
      enabled: enabled,
      rules: parsed.networkRules,
      cosmeticRules: parsed.cosmeticRules,
    );
  }

  static Future<AdBlockEngine> fromFilterSources({
    required bool enabled,
    required List<AdblockFilterSource> sources,
    List<ManualAdBlockRule> manualRules = const [],
    List<CosmeticAdRule> manualCosmeticRules = const [],
    http.Client? client,
  }) async {
    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final builtIn = parseFilterText(_builtInRules);
      final rules = <AdBlockRule>[...builtIn.networkRules];
      final cosmetics = <CosmeticAdRule>[
        ...builtIn.cosmeticRules,
        ...manualCosmeticRules,
      ];
      final statuses = <AdblockSourceStatus>[];

      for (final manual in manualRules) {
        final pattern = manual.pattern.trim();
        if (pattern.isEmpty) continue;
        if (manual.domainRule) {
          rules.add(
            AdBlockRule(type: AdBlockRuleType.domain, pattern: pattern),
          );
        } else {
          final parsed = _parseRuleBody(pattern, isException: false);
          rules.add(
            parsed ??
                AdBlockRule(type: AdBlockRuleType.contains, pattern: pattern),
          );
        }
      }

      if (!enabled) {
        return AdBlockEngine(
          enabled: enabled,
          rules: rules,
          cosmeticRules: cosmetics,
          sourceStatuses: [
            for (final source in sources)
              AdblockSourceStatus(
                url: source.url,
                state: AdblockSourceLoadState.disabled,
              ),
          ],
        );
      }

      for (final source in sources) {
        if (!source.enabled) {
          statuses.add(
            AdblockSourceStatus(
              url: source.url,
              state: AdblockSourceLoadState.disabled,
            ),
          );
          continue;
        }

        final uri = Uri.tryParse(source.url.trim());
        if (uri == null || !uri.hasScheme) {
          statuses.add(
            AdblockSourceStatus(
              url: source.url,
              state: AdblockSourceLoadState.failed,
              errorMessage: 'Invalid URL',
            ),
          );
          continue;
        }

        try {
          final response = await httpClient
              .get(uri)
              .timeout(_filterSourceTimeout);
          if (response.statusCode >= 200 && response.statusCode < 300) {
            final parsed = await _parseFilterTextResponsive(response.body);
            rules.addAll(parsed.networkRules);
            cosmetics.addAll(parsed.cosmeticRules);
            statuses.add(
              AdblockSourceStatus(
                url: source.url,
                state: AdblockSourceLoadState.loaded,
                ruleCount:
                    parsed.networkRules.length + parsed.cosmeticRules.length,
              ),
            );
          } else {
            statuses.add(
              AdblockSourceStatus(
                url: source.url,
                state: AdblockSourceLoadState.failed,
                errorMessage: 'HTTP ${response.statusCode}',
              ),
            );
          }
        } on TimeoutException {
          statuses.add(
            AdblockSourceStatus(
              url: source.url,
              state: AdblockSourceLoadState.failed,
              errorMessage: 'Timed out',
            ),
          );
        } catch (error) {
          statuses.add(
            AdblockSourceStatus(
              url: source.url,
              state: AdblockSourceLoadState.failed,
              errorMessage: '$error',
            ),
          );
        }
      }

      return AdBlockEngine(
        enabled: enabled,
        rules: rules,
        cosmeticRules: cosmetics,
        sourceStatuses: statuses,
      );
    } finally {
      if (ownsClient) {
        httpClient.close();
      }
    }
  }

  static Future<AdBlockParseResult> _parseFilterTextResponsive(String text) {
    if (text.length < 64 * 1024) {
      return Future.value(parseFilterText(text));
    }
    return Isolate.run(() => parseFilterText(text));
  }

  static Future<AdBlockEngine> fromFilterSourceUrls({
    required bool enabled,
    required List<String> urls,
    http.Client? client,
  }) {
    return fromFilterSources(
      enabled: enabled,
      sources: [
        for (final url in urls)
          AdblockFilterSource(name: Uri.tryParse(url)?.host ?? url, url: url),
      ],
      client: client,
    );
  }

  bool shouldBlockUrl(String rawUrl) {
    if (!enabled) return false;

    // LRU cache lookup.
    final cached = _blockCache[rawUrl];
    if (cached != null) {
      _blockCache.remove(rawUrl);
      _blockCache[rawUrl] = cached;
      return cached;
    }

    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;

    // Exceptions take precedence: if any exception rule matches, allow.
    if (_domainExceptionRules.isNotEmpty &&
        _hasDomainMatch(uri.host, _domainExceptionRules)) {
      _cacheResult(rawUrl, false);
      return false;
    }
    if (_containsExceptionRules.isNotEmpty &&
        _hasContainsMatch(rawUrl, _containsExceptionRules)) {
      _cacheResult(rawUrl, false);
      return false;
    }

    // Block rules.
    final blocked = (_domainBlockRules.isNotEmpty &&
            _hasDomainMatch(uri.host, _domainBlockRules)) ||
        (_containsBlockRules.isNotEmpty &&
            _hasContainsMatch(rawUrl, _containsBlockRules));
    _cacheResult(rawUrl, blocked);
    return blocked;
  }

  bool _hasDomainMatch(String host, Map<String, List<AdBlockRule>> domainMap) {
    if (host.isEmpty) return false;
    final lowerHost = host.toLowerCase();
    var dotIndex = -1;
    while (true) {
      final part = dotIndex == -1
          ? lowerHost
          : lowerHost.substring(dotIndex + 1);
      if (domainMap.containsKey(part)) return true;
      dotIndex = lowerHost.indexOf('.', dotIndex + 1);
      if (dotIndex == -1 || dotIndex >= lowerHost.length - 1) break;
    }
    return false;
  }

  bool _hasContainsMatch(String rawUrl, List<AdBlockRule> rules) {
    final lowerUrl = rawUrl.toLowerCase();
    for (final rule in rules) {
      if (lowerUrl.contains(rule.normalizedPattern)) return true;
    }
    return false;
  }

  void _cacheResult(String rawUrl, bool blocked) {
    _blockCache[rawUrl] = blocked;
    if (_blockCache.length > _maxCacheSize) {
      _blockCache.remove(_blockCache.keys.first);
    }
  }

  bool shouldSuppressSniffedUrl(String rawUrl) {
    if (rawUrl.trim().isEmpty) return false;
    return shouldBlockUrl(rawUrl);
  }

  bool shouldHideElement(String pageHost, ElementDescriptor element) {
    final normalizedHost = pageHost.toLowerCase();
    for (final rule in cosmeticRules) {
      final host = rule.host.toLowerCase();
      if (host.isNotEmpty &&
          normalizedHost != host &&
          !normalizedHost.endsWith('.$host')) {
        continue;
      }
      if (_selectorMatches(rule.selector, element)) return true;
    }
    return false;
  }

  static bool looksLikeAdMediaUrl(String rawUrl) {
    final normalized = rawUrl.toLowerCase();
    if (normalized.contains('/vast') ||
        normalized.contains('vast=') ||
        normalized.contains('/vmap') ||
        normalized.contains('vmap=') ||
        normalized.contains('prebid') ||
        normalized.contains('pubads') ||
        normalized.contains('ima3') ||
        normalized.contains('doubleclick') ||
        normalized.contains('/ads/') ||
        normalized.contains('/adserver/') ||
        normalized.contains('/tracking/') ||
        normalized.contains('trackpixel') ||
        normalized.contains('pixel.gif')) {
      return true;
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host.startsWith('ads.') ||
        host.contains('.ads.') ||
        host.contains('adservice') ||
        host.contains('adserver') ||
        host.contains('analytics');
  }

  static List<AdBlockRule> parseRules(String text) {
    return parseFilterText(text).networkRules;
  }

  static AdBlockParseResult parseFilterText(String text) {
    final network = <AdBlockRule>[];
    final cosmetics = <CosmeticAdRule>[];
    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('!') || line.startsWith('[')) {
        continue;
      }

      final cosmetic = _parseCosmeticLine(line);
      if (cosmetic != null) {
        cosmetics.add(cosmetic);
        continue;
      }

      final hostsRule = _parseHostsRule(line);
      if (hostsRule != null) {
        network.add(hostsRule);
        continue;
      }

      final isException = line.startsWith('@@');
      final body = isException ? line.substring(2) : line;
      final rule = _parseRuleBody(body, isException: isException);
      if (rule != null) network.add(rule);
    }
    return AdBlockParseResult(networkRules: network, cosmeticRules: cosmetics);
  }

  static AdBlockRule? _parseHostsRule(String line) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) return null;
    final sink = parts.first;
    if (sink != '0.0.0.0' &&
        sink != '127.0.0.1' &&
        sink != '::' &&
        sink != '::1') {
      return null;
    }
    final host = parts[1].trim().toLowerCase();
    if (!_looksHostLike(host)) return null;
    return AdBlockRule(type: AdBlockRuleType.domain, pattern: host);
  }

  static CosmeticAdRule? _parseCosmeticLine(String line) {
    final index = line.indexOf('##');
    if (index <= 0 || index >= line.length - 2) return null;
    final host = line.substring(0, index).trim();
    final selector = line.substring(index + 2).trim();
    if (host.isEmpty || selector.isEmpty || host.contains(',')) return null;
    return CosmeticAdRule(host: host, selector: selector);
  }

  static AdBlockRule? _parseRuleBody(String body, {required bool isException}) {
    var clean = body;
    final optionIndex = clean.indexOf(r'$');
    if (optionIndex != -1) {
      clean = clean.substring(0, optionIndex);
    }
    clean = clean.trim();
    if (clean.isEmpty || clean.startsWith('#')) return null;

    if (clean.startsWith('||')) {
      final domain = clean.substring(2).split(RegExp(r'[\^/]')).first.trim();
      if (domain.isEmpty) return null;
      return AdBlockRule(
        type: AdBlockRuleType.domain,
        pattern: domain,
        isException: isException,
      );
    }

    if (clean.startsWith('|')) {
      clean = clean.substring(1);
    }
    if (clean.endsWith('|')) {
      clean = clean.substring(0, clean.length - 1);
    }

    final uri = Uri.tryParse(clean);
    if (uri != null && uri.host.isNotEmpty) {
      return AdBlockRule(
        type: AdBlockRuleType.domain,
        pattern: uri.host,
        isException: isException,
      );
    }

    final hostLike = clean.split('/').first.replaceAll('^', '');
    if (_looksHostLike(hostLike) && !hostLike.contains('*')) {
      return AdBlockRule(
        type: AdBlockRuleType.domain,
        pattern: hostLike,
        isException: isException,
      );
    }

    return AdBlockRule(
      type: AdBlockRuleType.contains,
      pattern: clean.replaceAll('*', ''),
      isException: isException,
    );
  }

  static bool _selectorMatches(String selector, ElementDescriptor element) {
    final clean = selector.trim();
    if (clean.isEmpty) return false;
    if (clean.startsWith('#')) return element.id == clean.substring(1);
    if (clean.startsWith('.')) {
      return element.classes.contains(clean.substring(1));
    }
    final tag = element.tagName.toLowerCase();
    if (!clean.contains('.') && !clean.contains('#')) {
      return tag == clean.toLowerCase();
    }
    final tagClass = RegExp(
      r'^([a-z0-9_-]+)\.([a-z0-9_-]+)$',
    ).firstMatch(clean.toLowerCase());
    if (tagClass != null) {
      return tag == tagClass.group(1) &&
          element.classes.contains(tagClass.group(2));
    }
    return false;
  }

  static bool _looksHostLike(String host) {
    return host.contains('.') &&
        !host.contains('*') &&
        !host.contains('/') &&
        !host.contains(':');
  }
}

const String _builtInRules = '''
! Aurora default lightweight blocker
||doubleclick.net^
||googleads.g.doubleclick.net^
||adcolony.com^
||ads.google.com^
||popads.net^
||popcash.net^
||onclickads.net^
||propellerads.com^
||ads.yahoo.com^
||adservice.google.com^
||googlesyndication.com^
||quantserve.com^
||scorecardresearch.com^
||adnxs.com^
||outbrain.com^
||taboola.com^
||criteo.com^
||pubmatic.com^
||casalemedia.com^
||imasdk.googleapis.com^
/ads/
/adserver/
/banner/
/popunder/
/vast/
/vmap/
''';
