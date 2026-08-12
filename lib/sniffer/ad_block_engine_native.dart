import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

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

  /// When the list was last fetched successfully (network fetch time, or the
  /// cache file's mtime when served from cache). Null when never loaded.
  final DateTime? lastUpdated;

  const AdblockSourceStatus({
    required this.url,
    required this.state,
    this.ruleCount = 0,
    this.errorMessage,
    this.lastUpdated,
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

/// One filter source queued for the refresh pipeline: cached text + whether
/// the cache is stale enough to warrant a network fetch.
class _SourceRefreshJob {
  final AdblockFilterSource source;
  final Uri uri;
  final File? cacheFile;
  final String? cachedText;
  final bool shouldUpdate;

  const _SourceRefreshJob({
    required this.source,
    required this.uri,
    this.cacheFile,
    this.cachedText,
    required this.shouldUpdate,
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
  final List<RemoveParamRule> removeParamRules;

  const AdBlockParseResult({
    required this.networkRules,
    required this.cosmeticRules,
    this.scriptletRules = const [],
    this.cssInjectionRules = const [],
    this.removeParamRules = const [],
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

/// A `$removeparam` rule (AdGuard URL Tracking list): strip the named query
/// parameter from matching URLs instead of blocking them. `param` null means
/// strip ALL query parameters.
class RemoveParamRule {
  /// Pre-modifier pattern: '' (every URL), '||host^', 'host/path', '/path'.
  final String pattern;

  /// Parameter name to strip; null = strip all query parameters.
  final String? param;

  const RemoveParamRule({required this.pattern, this.param});
}

class _ScriptletParseResult {
  final String name;
  final List<String> args;

  const _ScriptletParseResult({required this.name, this.args = const []});
}

class AdBlockEngine {
  /// Per-source fetch budget. Filter lists are multi-megabyte (EasyList is
  /// ~2.5 MB) — 6 s was too short on slow mobile networks, so sources timed
  /// out and silently fell back to stale caches.
  static const Duration _filterFetchTimeout = Duration(seconds: 20);

  /// Backoff between the first attempt and the single retry.
  static const Duration _filterFetchRetryDelay = Duration(milliseconds: 1500);

  /// Cached lists are refreshed after this age (uBlock Origin refreshes its
  /// lists on a similar cadence).
  static const Duration _filterStaleAfter = Duration(hours: 24);
  static final AdBlockFFIBindings? _bindings = AdBlockFFIBindings.load();

  final bool enabled;
  final List<AdBlockRule> rules;
  final List<CosmeticAdRule> cosmeticRules;
  final List<ScriptletRule> scriptletRules;
  final List<CssInjectionRule> cssInjectionRules;
  final List<RemoveParamRule> removeParamRules;
  final List<AdblockSourceStatus> sourceStatuses;
  AdBlockNativeEngine? _nativeEngine;
  bool _nativeEngineInitialized = false;
  final String? rawRulesText;

  /// Lazily initialises the native engine on first blocking call.
  /// Deferring the FFI loadRules out of the constructor moves ~10-50 ms
  /// of synchronous work out of cold-start initState into the first
  /// request interception, which happens well after the first frame.
  AdBlockNativeEngine? _lazyNativeEngine() {
    if (!_nativeEngineInitialized) {
      _nativeEngineInitialized = true;
      if (_nativeEngine == null && _bindings != null && enabled) {
        _nativeEngine = AdBlockNativeEngine(_bindings!);
        try {
          _nativeEngine!.loadRules(
            rawRulesText ??
                serializeRules(
                  rules,
                  cosmeticRules: cosmeticRules,
                  scriptletRules: scriptletRules,
                  cssInjectionRules: cssInjectionRules,
                ),
          );
        } catch (_) {
          // Native engine may fail to load rules on some devices
          // (e.g. incomplete .so extraction). Fall through to Dart-side.
        }
      }
    }
    return _nativeEngine;
  }

  static final Map<String, Future<AdBlockEngine>> _engineCache = {};
  final LinkedHashMap<String, bool> _blockCache = LinkedHashMap<String, bool>();
  static const int _maxCacheSize = 5000;

  AdBlockEngine({
    required this.enabled,
    required this.rules,
    this.cosmeticRules = const [],
    this.scriptletRules = const [],
    this.cssInjectionRules = const [],
    this.removeParamRules = const [],
    this.sourceStatuses = const [],
    this.rawRulesText,
  }) : _nativeEngine = null /* created lazily in shouldBlockUrl */ {
    // Native engine creation + loadRules is deferred to the first
    // shouldBlockUrl call so that cold-start initState (which calls
    // sharedBuiltIn) does not block the first frame with FFI overhead.
  }

  static String _computeCacheKey({
    required bool enabled,
    required List<AdblockFilterSource> sources,
    required List<ManualAdBlockRule> manualRules,
    required List<CosmeticAdRule> manualCosmeticRules,
  }) {
    final sb = StringBuffer();
    sb.write('enabled:$enabled;');
    for (final src in sources) {
      sb.write('src:${src.name}:${src.url}:${src.enabled};');
    }
    for (final rule in manualRules) {
      sb.write('rule:${rule.pattern}:${rule.domainRule};');
    }
    for (final rule in manualCosmeticRules) {
      sb.write('cosmetic:${rule.host}:${rule.selector};');
    }
    return sb.toString();
  }

  static Future<File> _getCacheFile(String url) async {
    final docs = await getApplicationSupportDirectory();
    return File('${docs.path}/adblock_filter_${url.hashCode}.txt');
  }

  /// Timestamp of the last successful fetch for a filter source (the cache
  /// file's mtime), or null when the source was never fetched successfully.
  /// Used by the settings UI to surface list freshness.
  static Future<DateTime?> filterSourceLastUpdated(String url) async {
    try {
      final cacheFile = await _getCacheFile(url);
      if (!await cacheFile.exists()) return null;
      return await cacheFile.lastModified();
    } catch (_) {
      return null;
    }
  }

  static Future<DateTime?> _sourceLastModified(File? cacheFile) async {
    if (cacheFile == null) return null;
    try {
      return await cacheFile.lastModified();
    } catch (_) {
      return null;
    }
  }

  /// Resolves `!#include <file>` directives (used by uBlockOrigin uAssets
  /// lists — e.g. annoyances.txt is a stub whose rules live in
  /// annoyances-others.txt) by fetching the referenced file from the same
  /// directory. Depth-capped to guard against pathological chains.
  static Future<String> _resolveIncludes(
    http.Client client,
    String text,
    Uri baseUri, [
    int depth = 0,
  ]) async {
    if (depth > 3) return text;
    final includeRe = RegExp(r'^!#include\s+(\S+)');
    final out = <String>[];
    for (final line in text.split('\n')) {
      final m = includeRe.firstMatch(line.trim());
      if (m == null) {
        out.add(line);
        continue;
      }
      final includeUri = baseUri.resolve(m.group(1)!);
      try {
        final response =
            await client.get(includeUri).timeout(_filterFetchTimeout);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          out.add(await _resolveIncludes(client, response.body, includeUri, depth + 1));
        }
      } catch (_) {
        // Keep the include line (harmless comment) rather than dropping the
        // rest of the list.
        out.add(line);
      }
    }
    return out.join('\n');
  }

  /// Fetches one filter list with a single retry after a short backoff.
  /// Returns (body, errorMessage) — exactly one of the two is non-null.
  static Future<(String?, String?)> _fetchFilterListWithRetry(
    http.Client client,
    Uri uri,
  ) async {
    String? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future.delayed(_filterFetchRetryDelay);
      }
      try {
        final response = await client.get(uri).timeout(_filterFetchTimeout);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return (response.body, null);
        }
        lastError = 'Server returned error ${response.statusCode}';
      } on TimeoutException {
        lastError = 'Request timed out.';
      } catch (error) {
        lastError = '$error';
      }
    }
    return (null, lastError);
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
      removeParamRules: parsed.removeParamRules,
      rawRulesText: _builtInRules,
    );
  }

  /// Process-wide shared built-in engine (enabled only).
  ///
  /// Creating a full [AdBlockEngine] loads the native `.so` and runs
  /// `loadRules`. On cold start we open one controller per restored tab;
  /// sharing the default engine avoids N× native compile of the same
  /// lightweight list. Controllers that call [fromFilterSources] replace
  /// their local reference and do not mutate this instance.
  static AdBlockEngine? _sharedBuiltInEnabled;
  static AdBlockEngine? _sharedBuiltInDisabled;

  static AdBlockEngine sharedBuiltIn({bool enabled = true}) {
    if (!enabled) {
      return _sharedBuiltInDisabled ??= AdBlockEngine.builtIn(enabled: false);
    }
    return _sharedBuiltInEnabled ??= AdBlockEngine.builtIn(enabled: true);
  }

  static Future<AdBlockEngine> fromFilterSources({
    required bool enabled,
    required List<AdblockFilterSource> sources,
    List<ManualAdBlockRule> manualRules = const [],
    List<CosmeticAdRule> manualCosmeticRules = const [],
    http.Client? client,
  }) {
    final key = _computeCacheKey(
      enabled: enabled,
      sources: sources,
      manualRules: manualRules,
      manualCosmeticRules: manualCosmeticRules,
    );
    if (_engineCache.containsKey(key)) {
      return _engineCache[key]!;
    }
    final future = _buildEngine(
      enabled: enabled,
      sources: sources,
      manualRules: manualRules,
      manualCosmeticRules: manualCosmeticRules,
      client: client,
    );
    _engineCache[key] = future;
    return future;
  }

  static Future<AdBlockEngine> _buildEngine({
    required bool enabled,
    required List<AdblockFilterSource> sources,
    required List<ManualAdBlockRule> manualRules,
    required List<CosmeticAdRule> manualCosmeticRules,
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
      final removeParams = <RemoveParamRule>[...builtIn.removeParamRules];

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
        // Manual $removeparam rules strip parameters; never block.
        final manualRemoveParams = _parseRemoveParamRule(pattern);
        if (manualRemoveParams != null) {
          removeParams.addAll(manualRemoveParams);
          continue;
        }
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
          removeParamRules: removeParams,
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

      // ---- Pass 1: cache read + staleness check (fast, sequential) ----
      final jobs = <_SourceRefreshJob>[];
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
              errorMessage: 'Could not load — invalid filter URL.',
            ),
          );
          continue;
        }

        String? filterText;
        File? cacheFile;
        try {
          cacheFile = await _getCacheFile(source.url);
          if (await cacheFile.exists()) {
            filterText = await cacheFile.readAsString();
          }
        } catch (_) {}

        var shouldUpdate = false;
        if (filterText == null) {
          shouldUpdate = true;
        } else if (cacheFile != null) {
          try {
            final lastModified = await cacheFile.lastModified();
            if (DateTime.now().difference(lastModified) > _filterStaleAfter) {
              shouldUpdate = true;
            }
          } catch (_) {
            shouldUpdate = true;
          }
        }

        jobs.add(
          _SourceRefreshJob(
            source: source,
            uri: uri,
            cacheFile: cacheFile,
            cachedText: filterText,
            shouldUpdate: shouldUpdate,
          ),
        );
      }

      // ---- Pass 2: refresh stale sources in parallel (one retry each) ----
      final fetchResults = await Future.wait([
        for (final job in jobs.where((j) => j.shouldUpdate))
          _fetchFilterListWithRetry(httpClient, job.uri),
      ]);
      final fetchedByUrl = <String, (String?, String?)>{};
      var fetchIndex = 0;
      for (final job in jobs) {
        if (!job.shouldUpdate) continue;
        fetchedByUrl[job.uri.toString()] = fetchResults[fetchIndex++];
      }

      // ---- Pass 3: merge results in source order. Parsing stays sequential
      // so memory stays bounded on low-RAM devices. ----
      for (final job in jobs) {
        final source = job.source;
        var filterText = job.cachedText;
        String? errorMessage;
        var loadedFromNetwork = false;
        if (job.shouldUpdate) {
          final (fresh, error) = fetchedByUrl[job.uri.toString()]!;
          errorMessage = error;
          if (fresh != null) {
            filterText = await _resolveIncludes(httpClient, fresh, job.uri);
            loadedFromNetwork = true;
            if (job.cacheFile != null) {
              try {
                await job.cacheFile!.parent.create(recursive: true);
                await job.cacheFile!.writeAsString(fresh);
              } catch (_) {}
            }
          }
        }

        if (filterText != null) {
          try {
            final parsed = await _parseFilterTextResponsive(filterText);
            rules.addAll(parsed.networkRules);
            cosmetics.addAll(parsed.cosmeticRules);
            scriptlets.addAll(parsed.scriptletRules);
            cssInjections.addAll(parsed.cssInjectionRules);
            removeParams.addAll(parsed.removeParamRules);
            rawSb.writeln(_withoutRemoveParamLines(filterText));
            statuses.add(
              AdblockSourceStatus(
                url: source.url,
                state: AdblockSourceLoadState.loaded,
                ruleCount:
                    parsed.networkRules.length + parsed.cosmeticRules.length,
                lastUpdated: loadedFromNetwork
                    ? DateTime.now()
                    : await _sourceLastModified(job.cacheFile),
              ),
            );
          } catch (error) {
            statuses.add(
              AdblockSourceStatus(
                url: source.url,
                state: AdblockSourceLoadState.failed,
                errorMessage: 'Could not parse filters: $error',
              ),
            );
          }
        } else {
          statuses.add(
            AdblockSourceStatus(
              url: source.url,
              state: AdblockSourceLoadState.failed,
              errorMessage: errorMessage ?? 'Could not load this filter list.',
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
        removeParamRules: removeParams,
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

    final cacheKey = '$rawUrl|$sourceHost|$requestType|$isThirdParty';
    final cached = _blockCache[cacheKey];
    if (cached != null) {
      _blockCache.remove(cacheKey);
      _blockCache[cacheKey] = cached;
      return cached;
    }

    bool result = false;
    final nativeEngine = _lazyNativeEngine();
    if (nativeEngine != null) {
      result = nativeEngine.shouldBlockUrlEx(
        rawUrl,
        sourceHost: sourceHost,
        requestType: requestType,
        isThirdParty: isThirdParty,
      );
    } else {
      final uri = Uri.tryParse(rawUrl);
      if (uri == null) {
        result = false;
      } else {
        var blocked = false;
        for (final rule in rules) {
          if (!rule.matches(uri, rawUrl)) continue;
          if (rule.isException) {
            blocked = false;
            break;
          }
          blocked = true;
        }
        result = blocked;
      }
    }

    _blockCache[cacheKey] = result;
    if (_blockCache.length > _maxCacheSize) {
      _blockCache.remove(_blockCache.keys.first);
    }
    return result;
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

  String? _genericCosmeticCssCache;

  /// Builds `display:none` CSS for [selectors], in small batches.
  ///
  /// CSS discards an *entire* selector list if any single selector in it fails
  /// to parse, so emitting every selector as one comma-separated list means one
  /// malformed filter-list rule takes down all cosmetic hiding on the page.
  /// Batching caps the blast radius while staying far smaller than one rule per
  /// selector.
  static String _buildHideCss(List<String> selectors) {
    const batchSize = 25;
    final buffer = StringBuffer();
    for (var i = 0; i < selectors.length; i += batchSize) {
      final end =
          (i + batchSize < selectors.length) ? i + batchSize : selectors.length;
      buffer.write(selectors.sublist(i, end).join(','));
      buffer.write('{display:none!important}');
    }
    return buffer.toString();
  }

  /// Host-independent cosmetic CSS — rules written as `##selector` with no
  /// domain, which is the bulk of EasyList's element hiding.
  ///
  /// Installed once as a document_start user script rather than pushed over the
  /// platform channel on every navigation: the full lists carry thousands of
  /// generic rules, and re-sending that per page load would cost more than the
  /// ads it hides. Cached because the result never varies by host, and the
  /// engine is rebuilt (new instance) whenever the user's filter sources change.
  String getGenericCosmeticCss() {
    if (!enabled) return '';
    final cached = _genericCosmeticCssCache;
    if (cached != null) return cached;
    final selectors = <String>[];
    for (final rule in cosmeticRules) {
      if (rule.host.isEmpty) selectors.add(rule.selector);
    }
    final built = selectors.isEmpty ? '' : _buildHideCss(selectors);
    _genericCosmeticCssCache = built;
    return built;
  }

  /// Returns cosmetic CSS specific to [host]. Generic (hostless) rules are
  /// deliberately excluded — see [getGenericCosmeticCss].
  String getCosmeticCssForHost(String host) {
    if (!enabled) return '';
    final normalizedHost = host.toLowerCase();
    final selectors = <String>[];
    final cssInjections = <String>[];

    // Collect standard cosmetic rules. Generic (hostless) rules are excluded
    // here — they go out once via [getGenericCosmeticCss] as a document_start
    // user script instead of crossing the platform channel on every page load.
    for (final rule in cosmeticRules) {
      final ruleHost = rule.host.toLowerCase();
      if (ruleHost.isEmpty) continue;
      if (normalizedHost == ruleHost ||
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
      parts.add(_buildHideCss(selectors));
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
    final removeParams = <RemoveParamRule>[];
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

      // `$removeparam` rules strip tracking parameters — they must never
      // become block rules (the old modifier-stripping turned AdGuard URL
      // Tracking's 2,600+ rules into full-domain blocks, e.g. youtube.com).
      final removeParam = _parseRemoveParamRule(body);
      if (removeParam != null) {
        removeParams.addAll(removeParam);
        continue;
      }

      final rule = _parseRuleBody(body, isException: isException);
      if (rule != null) network.add(rule);
    }
    return AdBlockParseResult(
      networkRules: network,
      cosmeticRules: cosmetics,
      scriptletRules: scriptlets,
      cssInjectionRules: cssInjections,
      removeParamRules: removeParams,
    );
  }

  /// Drops `$removeparam` lines from filter text before it reaches the
  /// native engine, whose parser also strips `$` modifiers and would
  /// otherwise turn them into domain-block rules.
  static String _withoutRemoveParamLines(String text) {
    if (!text.contains('removeparam')) return text;
    return text
        .split(RegExp(r'\r?\n'))
        .where((line) => _parseRemoveParamRule(line.trim()) == null)
        .join('\n');
  }

  /// Parses a `$removeparam[=param]` rule. Returns null when the line is not
  /// a removeparam rule. `param1|param2` values expand into multiple rules.
  static List<RemoveParamRule>? _parseRemoveParamRule(String body) {
    final optionIndex = body.indexOf(r'$');
    if (optionIndex == -1) return null;
    final options = body.substring(optionIndex + 1).split(',');
    String? removeParamValue;
    for (final option in options) {
      final trimmed = option.trim();
      if (trimmed == 'removeparam') {
        removeParamValue = '';
        break;
      }
      if (trimmed.startsWith('removeparam=')) {
        removeParamValue = trimmed.substring('removeparam='.length);
        break;
      }
    }
    if (removeParamValue == null) return null;
    if (removeParamValue.isEmpty) {
      return [
        RemoveParamRule(pattern: body.substring(0, optionIndex).trim()),
      ];
    }
    // Regex-valued removeparam rules are unsupported — drop the rule instead
    // of stripping everything.
    if (removeParamValue.startsWith('/')) return const [];
    return [
      for (final param in removeParamValue.split('|'))
        if (param.isNotEmpty)
          RemoveParamRule(
            pattern: body.substring(0, optionIndex).trim(),
            param: param,
          ),
    ];
  }

  /// Strips tracking parameters from [url] per the loaded `$removeparam`
  /// rules. Returns the cleaned URL, or null when nothing matched.
  String? stripTrackingParams(String url) {
    if (removeParamRules.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return null;
    final host = uri.host.toLowerCase();
    final path = uri.path;

    final stripAll = removeParamRules.any(
      (r) => r.param == null && _removeParamRuleMatches(r, host, path),
    );
    if (stripAll) {
      return uri.replace(queryParameters: null).toString();
    }
    final toStrip = <String>{};
    for (final rule in removeParamRules) {
      final param = rule.param;
      if (param == null || !_removeParamRuleMatches(rule, host, path)) {
        continue;
      }
      toStrip.add(param);
    }
    if (toStrip.isEmpty) return null;
    final remaining = <String, String>{
      for (final entry in uri.queryParameters.entries)
        if (!toStrip.contains(entry.key)) entry.key: entry.value,
    };
    if (remaining.length == uri.queryParameters.length) return null;
    return uri.replace(queryParameters: remaining).toString();
  }

  static bool _removeParamRuleMatches(
    RemoveParamRule rule,
    String host,
    String path,
  ) {
    final pattern = rule.pattern;
    if (pattern.isEmpty) return true;
    if (pattern.startsWith('||')) {
      var rest = pattern.substring(2);
      if (rest.endsWith('^')) rest = rest.substring(0, rest.length - 1);
      return _hostOrPathMatches(rest, host, path);
    }
    if (pattern.startsWith('/')) return path.startsWith(pattern);
    if (pattern.contains('/')) {
      final slash = pattern.indexOf('/');
      final patternHost = pattern.substring(0, slash).replaceAll('^', '');
      if (!_hostMatches(patternHost, host)) return false;
      return path.startsWith(pattern.substring(slash));
    }
    return _hostMatches(pattern.replaceAll('^', ''), host);
  }

  static bool _hostOrPathMatches(String pattern, String host, String path) {
    if (pattern.contains('/')) {
      final slash = pattern.indexOf('/');
      if (!_hostMatches(pattern.substring(0, slash), host)) return false;
      return path.startsWith(pattern.substring(slash));
    }
    return _hostMatches(pattern, host);
  }

  static bool _hostMatches(String pattern, String host) {
    if (pattern.isEmpty) return true;
    return host == pattern || host.endsWith('.$pattern');
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

  /// Selector fragments that are procedural/extended-CSS syntax rather than
  /// real CSS. They are common in EasyList and uBlock lists but a browser
  /// rejects them, and because selectors are emitted as one comma-separated
  /// list, a single invalid entry silently voids *every* cosmetic rule on the
  /// page. Filtering them here keeps the rest of the list working.
  static const List<String> _proceduralSelectorTokens = [
    '+js(',
    ':has-text(',
    ':-abp-has(',
    ':-abp-contains(',
    ':xpath(',
    ':matches-css(',
    ':matches-attr(',
    ':matches-path(',
    ':min-text-length(',
    ':upward(',
    ':watch-attr(',
    ':remove(',
    ':style(',
    ':others(',
    ':if(',
    ':if-not(',
  ];

  static bool _isSupportedSelector(String selector) {
    final lower = selector.toLowerCase();
    for (final token in _proceduralSelectorTokens) {
      if (lower.contains(token)) return false;
    }
    return true;
  }

  static CosmeticAdRule? _parseCosmeticLine(String line) {
    final index = line.indexOf('##');
    // index == 0 is a *generic* rule (`##.ad`) that applies to every host —
    // that is the bulk of EasyList's element hiding, so it must not be dropped.
    if (index < 0 || index >= line.length - 2) return null;
    final host = line.substring(0, index).trim();
    final selector = line.substring(index + 2).trim();
    if (selector.isEmpty || host.contains(',')) return null;
    if (!_isSupportedSelector(selector)) return null;
    // An empty host means "all hosts"; getCosmeticCssForHost already treats
    // CosmeticAdRule.host == '' that way.
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
