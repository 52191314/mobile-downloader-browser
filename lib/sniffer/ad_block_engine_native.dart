import 'dart:async';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../settings/download_settings.dart';
import '../native/adblock_ffi.dart';
import '../native/adblock_native_engine.dart';

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

  const AdBlockRule({
    required this.type,
    required this.pattern,
    this.isException = false,
  });

  bool matches(Uri uri, String rawUrl) {
    final host = uri.host.toLowerCase();
    final url = rawUrl.toLowerCase();
    final normalizedPattern = pattern.toLowerCase();
    return switch (type) {
      AdBlockRuleType.domain =>
        host == normalizedPattern || host.endsWith('.$normalizedPattern'),
      AdBlockRuleType.contains => url.contains(normalizedPattern),
    };
  }
}

class AdBlockParseResult {
  final List<AdBlockRule> networkRules;
  final List<CosmeticAdRule> cosmeticRules;
  final List<ScriptletRule> scriptletRules;
  final List<CssInjectionRule> cssInjectionRules;

  const AdBlockParseResult({
    required this.networkRules,
    required this.cosmeticRules,
    this.scriptletRules = const [],
    this.cssInjectionRules = const [],
  });
}

class ScriptletRule {
  final String host;
  final String name;
  final List<String> args;

  const ScriptletRule({
    this.host = '',
    required this.name,
    this.args = const [],
  });
}

class CssInjectionRule {
  final String host;
  final String css;

  const CssInjectionRule({
    this.host = '',
    required this.css,
  });
}

class _ScriptletParseResult {
  final String name;
  final List<String> args;

  const _ScriptletParseResult({required this.name, this.args = const []});
}

class AdBlockEngine {
  static const Duration _filterSourceTimeout = Duration(seconds: 6);
  static final AdBlockFFIBindings? _bindings = AdBlockFFIBindings.load();

  final bool enabled;
  final List<AdBlockRule> rules;
  final List<CosmeticAdRule> cosmeticRules;
  final List<ScriptletRule> scriptletRules;
  final List<CssInjectionRule> cssInjectionRules;
  final List<AdblockSourceStatus> sourceStatuses;
  final AdBlockNativeEngine? _nativeEngine;
  final String? rawRulesText;

  AdBlockEngine({
    required this.enabled,
    required this.rules,
    this.cosmeticRules = const [],
    this.scriptletRules = const [],
    this.cssInjectionRules = const [],
    this.sourceStatuses = const [],
    this.rawRulesText,
  }) : _nativeEngine = (_bindings != null && enabled)
           ? AdBlockNativeEngine(_bindings!)
           : null {
    final nativeEngine = _nativeEngine;
    if (nativeEngine != null) {
      if (rawRulesText != null) {
        nativeEngine.loadRules(rawRulesText!);
      } else {
        final rulesText = serializeRules(
          rules,
          cosmeticRules: cosmeticRules,
          scriptletRules: scriptletRules,
          cssInjectionRules: cssInjectionRules,
        );
        nativeEngine.loadRules(rulesText);
      }
    }
  }

  static String serializeRules(
    List<AdBlockRule> rules, {
    List<CosmeticAdRule> cosmeticRules = const [],
    List<ScriptletRule> scriptletRules = const [],
    List<CssInjectionRule> cssInjectionRules = const [],
  }) {
    final sb = StringBuffer();
    for (final rule in rules) {
      if (rule.isException) {
        sb.write('@@');
      }
      if (rule.type == AdBlockRuleType.domain) {
        sb.write('||');
        sb.write(rule.pattern);
        sb.write('^');
      } else {
        sb.write(rule.pattern);
      }
      sb.write('\n');
    }
    for (final rule in cosmeticRules) {
      if (rule.host.isNotEmpty) {
        sb.write(rule.host);
      }
      sb.write('##');
      sb.write(rule.selector);
      sb.write('\n');
    }
    for (final rule in scriptletRules) {
      if (rule.host.isNotEmpty) {
        sb.write(rule.host);
      }
      sb.write('#%#//scriptlet(\'');
      sb.write(rule.name);
      for (final arg in rule.args) {
        sb.write('\', \'');
        sb.write(arg);
      }
      sb.write('\')\n');
    }
    for (final rule in cssInjectionRules) {
      if (rule.host.isNotEmpty) {
        sb.write(rule.host);
      }
      sb.write('#\$#');
      sb.write(rule.css);
      sb.write('\n');
    }
    return sb.toString();
  }

  factory AdBlockEngine.builtIn({bool enabled = true}) {
    final parsed = parseFilterText(_builtInRules);
    return AdBlockEngine(
      enabled: enabled,
      rules: parsed.networkRules,
      cosmeticRules: parsed.cosmeticRules,
      scriptletRules: parsed.scriptletRules,
      cssInjectionRules: parsed.cssInjectionRules,
      rawRulesText: _builtInRules,
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
      final rawSb = StringBuffer()..writeln(_builtInRules);
      final builtIn = parseFilterText(_builtInRules);
      final rules = <AdBlockRule>[...builtIn.networkRules];
      final cosmetics = <CosmeticAdRule>[
        ...builtIn.cosmeticRules,
        ...manualCosmeticRules,
      ];
      final scriptlets = <ScriptletRule>[...builtIn.scriptletRules];
      final cssInjections = <CssInjectionRule>[...builtIn.cssInjectionRules];
      final statuses = <AdblockSourceStatus>[];

      // Add manual cosmetic rules to rawSb
      for (final rule in manualCosmeticRules) {
        if (rule.host.isNotEmpty) {
          rawSb.write(rule.host);
        }
        rawSb.write('##');
        rawSb.writeln(rule.selector);
      }

      for (final manual in manualRules) {
        final pattern = manual.pattern.trim();
        if (pattern.isEmpty) continue;
        if (manual.domainRule) {
          rules.add(
            AdBlockRule(type: AdBlockRuleType.domain, pattern: pattern),
          );
          rawSb.writeln('||$pattern^');
        } else {
          final parsed = _parseRuleBody(pattern, isException: false);
          rules.add(
            parsed ??
                AdBlockRule(type: AdBlockRuleType.contains, pattern: pattern),
          );
          rawSb.writeln(pattern);
        }
      }

      if (!enabled) {
        return AdBlockEngine(
          enabled: enabled,
          rules: rules,
          cosmeticRules: cosmetics,
          scriptletRules: scriptlets,
          cssInjectionRules: cssInjections,
          sourceStatuses: [
            for (final source in sources)
              AdblockSourceStatus(
                url: source.url,
                state: AdblockSourceLoadState.disabled,
              ),
          ],
          rawRulesText: rawSb.toString(),
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
            scriptlets.addAll(parsed.scriptletRules);
            cssInjections.addAll(parsed.cssInjectionRules);
            rawSb.writeln(response.body);
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
        scriptletRules: scriptlets,
        cssInjectionRules: cssInjections,
        sourceStatuses: statuses,
        rawRulesText: rawSb.toString(),
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

  bool shouldBlockUrl(
    String rawUrl, {
    String sourceHost = '',
    String requestType = '',
    bool isThirdParty = false,
  }) {
    if (!enabled) return false;
    final nativeEngine = _nativeEngine;
    if (nativeEngine != null) {
      return nativeEngine.shouldBlockUrlEx(
        rawUrl,
        sourceHost: sourceHost,
        requestType: requestType,
        isThirdParty: isThirdParty,
      );
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;

    var blocked = false;
    for (final rule in rules) {
      if (!rule.matches(uri, rawUrl)) continue;
      if (rule.isException) return false;
      blocked = true;
    }
    return blocked;
  }

  bool shouldSuppressSniffedUrl(String rawUrl) {
    if (rawUrl.trim().isEmpty) return false;
    return shouldBlockUrl(rawUrl);
  }

  bool shouldHideElement(String pageHost, ElementDescriptor element) {
    if (!enabled) return false;
    // Always use Dart-side cosmetic rule matching to support complete CSS selector matching.
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

  /// Returns all scriptlet rules that apply to the given [host].
  List<ScriptletRule> getScriptletsForHost(String host) {
    if (!enabled) return const [];
    final normalizedHost = host.toLowerCase();
    final result = <ScriptletRule>[];
    for (final rule in scriptletRules) {
      if (rule.host.isEmpty) {
        // Global scriptlet — applies to all pages
        result.add(rule);
      } else {
        final ruleHost = rule.host.toLowerCase();
        if (normalizedHost == ruleHost ||
            normalizedHost.endsWith('.$ruleHost')) {
          result.add(rule);
        }
      }
    }
    return result;
  }

  /// Returns combined cosmetic CSS for the given [host], including
  /// both standard cosmetic selectors and CSS injection rules.
  String getCosmeticCssForHost(String host) {
    if (!enabled) return '';
    final normalizedHost = host.toLowerCase();
    final selectors = <String>[];
    final cssInjections = <String>[];

    // Collect standard cosmetic rules
    for (final rule in cosmeticRules) {
      final ruleHost = rule.host.toLowerCase();
      if (ruleHost.isEmpty ||
          normalizedHost == ruleHost ||
          normalizedHost.endsWith('.$ruleHost')) {
        selectors.add(rule.selector);
      }
    }

    // Collect CSS injection rules
    for (final rule in cssInjectionRules) {
      final ruleHost = rule.host.toLowerCase();
      if (ruleHost.isEmpty ||
          normalizedHost == ruleHost ||
          normalizedHost.endsWith('.$ruleHost')) {
        cssInjections.add(rule.css);
      }
    }

    final parts = <String>[];
    if (selectors.isNotEmpty) {
      parts.add('${selectors.join(",")}{display:none!important}');
    }
    if (cssInjections.isNotEmpty) {
      parts.addAll(cssInjections);
    }
    return parts.join('\n');
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
    final scriptlets = <ScriptletRule>[];
    final cssInjections = <CssInjectionRule>[];
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

      // Parse scriptlet rules (#%#//scriptlet(...))
      final scriptletMatch =
          RegExp(r'^([^#]*)#%#\/\/scriptlet\((.+)\)$').firstMatch(line);
      if (scriptletMatch != null) {
        final host = scriptletMatch.group(1)?.trim() ?? '';
        final argsStr = scriptletMatch.group(2)?.trim() ?? '';
        if (argsStr.isNotEmpty) {
          final nameAndArgs = _parseScriptletArgs(argsStr);
          scriptlets.add(ScriptletRule(
            host: host,
            name: nameAndArgs.name,
            args: nameAndArgs.args,
          ));
          continue;
        }
      }

      // Parse CSS injection rules (#$#)
      final cssInjectIndex = line.indexOf('#\$#');
      if (cssInjectIndex != -1 && cssInjectIndex < line.length - 3) {
        final host = line.substring(0, cssInjectIndex).trim();
        final css = line.substring(cssInjectIndex + 3).trim();
        if (css.isNotEmpty && (host.isEmpty || !host.contains(','))) {
          cssInjections.add(CssInjectionRule(host: host, css: css));
          continue;
        }
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
    return AdBlockParseResult(
      networkRules: network,
      cosmeticRules: cosmetics,
      scriptletRules: scriptlets,
      cssInjectionRules: cssInjections,
    );
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

  static _ScriptletParseResult _parseScriptletArgs(String argsStr) {
    // Parse comma-separated quoted args: 'name', 'arg1', 'arg2'
    final args = <String>[];
    final regex = RegExp(r"'(?:[^'\\]|\\.)*'");
    for (final match in regex.allMatches(argsStr)) {
      var arg = match.group(0) ?? '';
      if (arg.startsWith("'") && arg.endsWith("'")) {
        arg = arg.substring(1, arg.length - 1);
      }
      args.add(arg);
    }
    if (args.isEmpty) {
      // Split by comma as fallback
      final parts = argsStr.split(',');
      if (parts.isNotEmpty) {
        for (var part in parts) {
          part = part.trim().replaceAll(RegExp(r"^'|'$"), '');
          if (part.isNotEmpty) args.add(part);
        }
      }
    }
    final name = args.isNotEmpty ? args.removeAt(0) : argsStr;
    return _ScriptletParseResult(name: name, args: args);
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
