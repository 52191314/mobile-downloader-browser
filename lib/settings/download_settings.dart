import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../sniffer/models/sniffed_media.dart' show MediaType;

enum SniffedMediaSort { newest, name, type, size, duration }

enum SniffedMediaDisplayMode { size, duration, both }

enum BrowserToolbarPosition { bottom, top }

enum DarkModePreference {
  system,
  off,
  forced,
}

/// Controls what happens when a download link (<a download> or
/// Content-Disposition: attachment) is clicked in the browser.
enum DownloadLinkBehavior {
  /// Capture the URL into the sniffed media tray; user must tap the
  /// capture badge to review and manually add to queue.
  capture,

  /// Automatically add the download to the queue without prompting.
  autoDownload,

  /// Show a prompt asking what to do.
  ask,

  /// Silently ignore the download.
  block,
}

class TranslateLanguage {
  final String id;
  final String label;

  const TranslateLanguage({required this.id, required this.label});

  Map<String, dynamic> toJson() => {'id': id, 'label': label};
}

const kTranslateLanguages = <TranslateLanguage>[
  TranslateLanguage(id: 'en', label: 'English'),
  TranslateLanguage(id: 'es', label: 'Spanish'),
  TranslateLanguage(id: 'fr', label: 'French'),
  TranslateLanguage(id: 'de', label: 'German'),
  TranslateLanguage(id: 'it', label: 'Italian'),
  TranslateLanguage(id: 'pt', label: 'Portuguese'),
  TranslateLanguage(id: 'ru', label: 'Russian'),
  TranslateLanguage(id: 'ja', label: 'Japanese'),
  TranslateLanguage(id: 'ko', label: 'Korean'),
  TranslateLanguage(id: 'zh-CN', label: 'Chinese (Simplified)'),
  TranslateLanguage(id: 'zh-TW', label: 'Chinese (Traditional)'),
  TranslateLanguage(id: 'ar', label: 'Arabic'),
  TranslateLanguage(id: 'hi', label: 'Hindi'),
  TranslateLanguage(id: 'vi', label: 'Vietnamese'),
  TranslateLanguage(id: 'th', label: 'Thai'),
  TranslateLanguage(id: 'id', label: 'Indonesian'),
];

TranslateLanguage translateLanguageById(String id) {
  for (final lang in kTranslateLanguages) {
    if (lang.id == id) return lang;
  }
  return kTranslateLanguages.first;
}

class SearchEngine {
  final String id;
  final String name;
  final String templateUrl;

  const SearchEngine({
    required this.id,
    required this.name,
    required this.templateUrl,
  });

  String buildSearchUrl(String query) {
    return templateUrl.replaceAll(
      '{query}',
      Uri.encodeQueryComponent(query.trim()),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'templateUrl': templateUrl,
  };

  factory SearchEngine.fromJson(Map<String, dynamic> json) {
    return SearchEngine(
      id: json['id'] as String? ?? google.id,
      name: json['name'] as String? ?? google.name,
      templateUrl: json['templateUrl'] as String? ?? google.templateUrl,
    );
  }

  static const google = SearchEngine(
    id: 'google',
    name: 'Google',
    templateUrl: 'https://www.google.com/search?q={query}',
  );

  static const duckDuckGo = SearchEngine(
    id: 'duckduckgo',
    name: 'DuckDuckGo',
    templateUrl: 'https://duckduckgo.com/?q={query}',
  );

  static const bing = SearchEngine(
    id: 'bing',
    name: 'Bing',
    templateUrl: 'https://www.bing.com/search?q={query}',
  );

  static const brave = SearchEngine(
    id: 'brave',
    name: 'Brave',
    templateUrl: 'https://search.brave.com/search?q={query}',
  );

  static const builtIn = [google, duckDuckGo, bing, brave];
}

class AdblockFilterSource {
  final String name;
  final String url;
  final bool enabled;

  const AdblockFilterSource({
    required this.name,
    required this.url,
    this.enabled = true,
  });

  AdblockFilterSource copyWith({bool? enabled}) {
    return AdblockFilterSource(
      name: name,
      url: url,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'enabled': enabled,
  };

  factory AdblockFilterSource.fromJson(Map<String, dynamic> json) {
    return AdblockFilterSource(
      name: json['name'] as String? ?? 'Unknown',
      url: json['url'] as String,
      enabled: json['enabled'] as bool? ?? false,
    );
  }

  static const trustedSources = [
    AdblockFilterSource(
      name: 'uBlock Filters',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt',
    ),
    AdblockFilterSource(
      name: 'uBlock Privacy',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt',
    ),
    AdblockFilterSource(
      name: 'uBlock Badware',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt',
    ),
    AdblockFilterSource(
      name: 'uBlock Annoyances',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'uBlock Quick Fixes',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt',
    ),
    AdblockFilterSource(
      name: 'EasyList',
      url: 'https://easylist.to/easylist/easylist.txt',
    ),
    AdblockFilterSource(
      name: 'EasyPrivacy',
      url: 'https://easylist.to/easylist/easyprivacy.txt',
    ),
    AdblockFilterSource(
      name: 'Peter Lowe\'s List',
      url:
          'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblock&showintro=0&mimetype=plaintext',
    ),
    AdblockFilterSource(
      name: 'AdGuard Base',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_2_Base/filter.txt',
    ),
    AdblockFilterSource(
      name: 'AdGuard Mobile Ads',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_11_Mobile/filter.txt',
    ),
    AdblockFilterSource(
      name: 'AdGuard Tracking',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_3_Spyware/filter.txt',
    ),
    AdblockFilterSource(
      name: 'AdGuard Social Media',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_4_Social/filter.txt',
    ),
    AdblockFilterSource(
      name: 'AdGuard Annoyances',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_14_Annoyances/filter.txt',
    ),
    AdblockFilterSource(
      name: 'AdGuard DNS',
      url: 'https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt',
    ),
    AdblockFilterSource(
      name: 'AdGuard URL Tracking',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_17_TrackParam/filter.txt',
    ),
    AdblockFilterSource(
      name: 'Fanboy Annoyance',
      url: 'https://secure.fanboy.co.nz/fanboy-annoyance.txt',
    ),
    AdblockFilterSource(
      name: 'EasyList Cookie Notices',
      url: 'https://secure.fanboy.co.nz/fanboy-cookiemonster.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'Fanboy Social',
      url: 'https://secure.fanboy.co.nz/fanboy-social.txt',
    ),
    AdblockFilterSource(
      name: 'Fanboy Enhanced Tracking',
      url: 'https://secure.fanboy.co.nz/enhancedstats.txt',
    ),
    AdblockFilterSource(
      name: 'NoCoin Filter',
      url:
          'https://raw.githubusercontent.com/hoshsadiq/adblock-nocoin-list/master/nocoin.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'Phishing Army',
      url:
          'https://phishing.army/download/phishing_army_blocklist_extended.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'Adblock Warning Removal',
      url: 'https://easylist-downloads.adblockplus.org/antiadblockfilters.txt',
    ),
    AdblockFilterSource(
      name: 'AdGuard German',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_6_German/filter.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'AdGuard French',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_16_French/filter.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'AdGuard Japanese',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_7_Japanese/filter.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'AdGuard Spanish',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_9_Spanish/filter.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'AdGuard Russian',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_1_Russian/filter.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'AdGuard Turkish',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_13_Turkish/filter.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'AdGuard Chinese',
      url:
          'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_224_Chinese/filter.txt',
      enabled: false,
    ),
    AdblockFilterSource(
      name: 'EasyList China',
      url: 'https://easylist-downloads.adblockplus.org/easylistchina.txt',
      enabled: false,
    ),
  ];

  static List<AdblockFilterSource> disabledTrustedSources() {
    return [
      for (final source in trustedSources) source.copyWith(enabled: false),
    ];
  }

  static const _trackerSourceUrls = {
    'https://easylist.to/easylist/easyprivacy.txt',
    'https://secure.fanboy.co.nz/enhancedstats.txt',
    'https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_3_Spyware/filter.txt',
    'https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt',
  };

  static List<AdblockFilterSource> trackerSourcesEnabled(
    List<AdblockFilterSource> current,
  ) {
    final byUrl = {for (final s in current) s.url: s};
    final result = List<AdblockFilterSource>.from(current);
    for (final url in _trackerSourceUrls) {
      final existing = byUrl[url];
      if (existing != null) {
        if (!existing.enabled) {
          final idx = result.indexOf(existing);
          result[idx] = existing.copyWith(enabled: true);
        }
      } else {
        result.add(
          AdblockFilterSource(
            name: Uri.tryParse(url)?.host ?? url,
            url: url,
            enabled: true,
          ),
        );
      }
    }
    return result;
  }
}

class ManualAdBlockRule {
  final String pattern;
  final bool domainRule;
  final DateTime createdAt;

  ManualAdBlockRule({
    required this.pattern,
    this.domainRule = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'pattern': pattern,
    'domainRule': domainRule,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ManualAdBlockRule.fromJson(Map<String, dynamic> json) {
    return ManualAdBlockRule(
      pattern: json['pattern'] as String? ?? '',
      domainRule: json['domainRule'] as bool? ?? false,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class CosmeticAdRule {
  final String host;
  final String selector;
  final DateTime createdAt;

  CosmeticAdRule({
    required this.host,
    required this.selector,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'host': host,
    'selector': selector,
    'createdAt': createdAt.toIso8601String(),
  };

  factory CosmeticAdRule.fromJson(Map<String, dynamic> json) {
    return CosmeticAdRule(
      host: json['host'] as String? ?? '',
      selector: json['selector'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class DownloadSettings {
  final int maxConcurrentDownloads;
  final int chunksPerTask;
  final String downloadDestination;
  final SearchEngine searchEngine;
  final bool adblockEnabled;
  final bool popupBlockingEnabled;
  final List<AdblockFilterSource> adblockFilterSources;
  final List<ManualAdBlockRule> manualAdBlockRules;
  final List<CosmeticAdRule> manualCosmeticRules;
  final SniffedMediaSort sniffedMediaSort;
  final SniffedMediaDisplayMode sniffedMediaDisplayMode;
  final BrowserToolbarPosition browserToolbarPosition;
  final bool desktopMode;
  /// User-Agent profile key: 'mobile' (default), 'desktop_chrome',
  /// 'desktop_firefox', 'safari'. Controls the global UA sent by both
  /// the WebView and the Dart HTTP download client.
  final String userAgentProfile;
  final bool privateMode;
  final bool wifiOnly;
  final bool readerMode;
  final bool captureShowAllMedia;
  final int maxDetectedMedia;
  final int minMediaSizeKb;
  final int minMediaDurationSeconds;
  final Set<MediaType> disabledMediaTypes;
  final bool doNotTrackEnabled;
  final DownloadLinkBehavior downloadLinkBehavior;
  final bool trackerBlockingEnabled;
  final List<String> adblockAllowlist;
  final DarkModePreference darkModePreference;
  final String translateTargetLang;
  final Map<String, double> siteZoomLevels;
  final Map<String, String> siteUserAgents;
  final bool autoRetry;
  final int retryLimit;
  final int minSpeedThresholdKbps;
  final int stallTimeoutSeconds;
  /// When a download stalls or fails above this percentage (0.0–1.0),
  /// the app will suggest merging the partial file instead of discarding it.
  /// Set to 1.0 to disable this behavior entirely.
  final double partialDownloadThreshold;

  const DownloadSettings({
    required this.maxConcurrentDownloads,
    required this.chunksPerTask,
    required this.downloadDestination,
    required this.searchEngine,
    required this.adblockEnabled,
    this.popupBlockingEnabled = true,
    required this.adblockFilterSources,
    this.manualAdBlockRules = const [],
    this.manualCosmeticRules = const [],
    required this.sniffedMediaSort,
    required this.sniffedMediaDisplayMode,
    required this.browserToolbarPosition,
    this.desktopMode = false,
    this.userAgentProfile = 'mobile',
    this.privateMode = false,
    this.wifiOnly = false,
    this.readerMode = false,
    this.captureShowAllMedia = false,
    this.maxDetectedMedia = 200,
    this.minMediaSizeKb = 0,
    this.minMediaDurationSeconds = 0,
    this.disabledMediaTypes = const {},
    this.doNotTrackEnabled = true,
    this.downloadLinkBehavior = DownloadLinkBehavior.capture,
    this.trackerBlockingEnabled = false,
    this.adblockAllowlist = const [],
    this.darkModePreference = DarkModePreference.system,
    this.translateTargetLang = 'en',
    this.siteZoomLevels = const {},
    this.siteUserAgents = const {},
    this.autoRetry = true,
    this.retryLimit = 3,
    this.minSpeedThresholdKbps = 0,
    this.stallTimeoutSeconds = 20,
    this.partialDownloadThreshold = 0.95,
  });

  static const trustedAdblockSources = [
    'https://easylist.to/easylist/easylist.txt',
    'https://easylist.to/easylist/easyprivacy.txt',
    'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblock&showintro=0&mimetype=plaintext',
    'https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt',
  ];

  factory DownloadSettings.defaults() => DownloadSettings(
    maxConcurrentDownloads: 3,
    chunksPerTask: 8,
    downloadDestination: 'Downloads/Aurora Downloads',
    searchEngine: SearchEngine.google,
    adblockEnabled: true,
    popupBlockingEnabled: true,
    adblockFilterSources: AdblockFilterSource.disabledTrustedSources(),
    sniffedMediaSort: SniffedMediaSort.newest,
    sniffedMediaDisplayMode: SniffedMediaDisplayMode.both,
    browserToolbarPosition: BrowserToolbarPosition.bottom,
    autoRetry: true,
    retryLimit: 3,
  );

  DownloadSettings copyWith({
    int? maxConcurrentDownloads,
    int? chunksPerTask,
    String? downloadDestination,
    SearchEngine? searchEngine,
    bool? adblockEnabled,
    bool? popupBlockingEnabled,
    List<AdblockFilterSource>? adblockFilterSources,
    List<ManualAdBlockRule>? manualAdBlockRules,
    List<CosmeticAdRule>? manualCosmeticRules,
    SniffedMediaSort? sniffedMediaSort,
    SniffedMediaDisplayMode? sniffedMediaDisplayMode,
    BrowserToolbarPosition? browserToolbarPosition,
    bool? desktopMode,
    String? userAgentProfile,
    bool? privateMode,
    bool? wifiOnly,
    bool? readerMode,
    bool? captureShowAllMedia,
    int? maxDetectedMedia,
    int? minMediaSizeKb,
    int? minMediaDurationSeconds,
    Set<MediaType>? disabledMediaTypes,
    bool? doNotTrackEnabled,
    DownloadLinkBehavior? downloadLinkBehavior,
    bool? trackerBlockingEnabled,
    List<String>? adblockAllowlist,
    DarkModePreference? darkModePreference,
    String? translateTargetLang,
    Map<String, double>? siteZoomLevels,
    Map<String, String>? siteUserAgents,
    bool? autoRetry,
    int? retryLimit,
    int? minSpeedThresholdKbps,
    int? stallTimeoutSeconds,
    double? partialDownloadThreshold,
  }) {
    return DownloadSettings(
      autoRetry: autoRetry ?? this.autoRetry,
      retryLimit: retryLimit ?? this.retryLimit,
      minSpeedThresholdKbps:
          minSpeedThresholdKbps ?? this.minSpeedThresholdKbps,
      stallTimeoutSeconds: stallTimeoutSeconds ?? this.stallTimeoutSeconds,
      partialDownloadThreshold:
          partialDownloadThreshold ?? this.partialDownloadThreshold,
      maxConcurrentDownloads:
          maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      chunksPerTask: chunksPerTask ?? this.chunksPerTask,
      downloadDestination: downloadDestination ?? this.downloadDestination,
      searchEngine: searchEngine ?? this.searchEngine,
      adblockEnabled: adblockEnabled ?? this.adblockEnabled,
      popupBlockingEnabled: popupBlockingEnabled ?? this.popupBlockingEnabled,
      adblockFilterSources: adblockFilterSources ?? this.adblockFilterSources,
      manualAdBlockRules: manualAdBlockRules ?? this.manualAdBlockRules,
      manualCosmeticRules: manualCosmeticRules ?? this.manualCosmeticRules,
      sniffedMediaSort: sniffedMediaSort ?? this.sniffedMediaSort,
      sniffedMediaDisplayMode:
          sniffedMediaDisplayMode ?? this.sniffedMediaDisplayMode,
      browserToolbarPosition:
          browserToolbarPosition ?? this.browserToolbarPosition,
      desktopMode: desktopMode ?? this.desktopMode,
      userAgentProfile: userAgentProfile ?? this.userAgentProfile,
      privateMode: privateMode ?? this.privateMode,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      readerMode: readerMode ?? this.readerMode,
      captureShowAllMedia: captureShowAllMedia ?? this.captureShowAllMedia,
      maxDetectedMedia: maxDetectedMedia ?? this.maxDetectedMedia,
      minMediaSizeKb: minMediaSizeKb ?? this.minMediaSizeKb,
      minMediaDurationSeconds:
          minMediaDurationSeconds ?? this.minMediaDurationSeconds,
      disabledMediaTypes: disabledMediaTypes ?? this.disabledMediaTypes,
      doNotTrackEnabled: doNotTrackEnabled ?? this.doNotTrackEnabled,
      downloadLinkBehavior:
          downloadLinkBehavior ?? this.downloadLinkBehavior,
      trackerBlockingEnabled:
          trackerBlockingEnabled ?? this.trackerBlockingEnabled,
      adblockAllowlist: adblockAllowlist ?? this.adblockAllowlist,
      darkModePreference: darkModePreference ?? this.darkModePreference,
      translateTargetLang:
          translateTargetLang ?? this.translateTargetLang,
      siteZoomLevels: siteZoomLevels ?? this.siteZoomLevels,
      siteUserAgents: siteUserAgents ?? this.siteUserAgents,
    );
  }

  Map<String, dynamic> toJson() => {
    'maxConcurrentDownloads': maxConcurrentDownloads,
    'chunksPerTask': chunksPerTask,
    'downloadDestination': downloadDestination,
    'searchEngine': searchEngine.toJson(),
    'adblockEnabled': adblockEnabled,
    'popupBlockingEnabled': popupBlockingEnabled,
    'adblockFilterSources': [
      for (final source in adblockFilterSources) source.toJson(),
    ],
    'manualAdBlockRules': [
      for (final rule in manualAdBlockRules) rule.toJson(),
    ],
    'manualCosmeticRules': [
      for (final rule in manualCosmeticRules) rule.toJson(),
    ],
    'sniffedMediaSort': sniffedMediaSort.name,
    'sniffedMediaDisplayMode': sniffedMediaDisplayMode.name,
    'browserToolbarPosition': browserToolbarPosition.name,
    'desktopMode': desktopMode,
    'userAgentProfile': userAgentProfile,
    'privateMode': privateMode,
    'wifiOnly': wifiOnly,
    'readerMode': readerMode,
      'captureShowAllMedia': captureShowAllMedia,
      'maxDetectedMedia': maxDetectedMedia,
      'minMediaSizeKb': minMediaSizeKb,
      'minMediaDurationSeconds': minMediaDurationSeconds,
      'disabledMediaTypes': disabledMediaTypes.map((t) => t.name).toList(),
      'doNotTrackEnabled': doNotTrackEnabled,
      'downloadLinkBehavior': downloadLinkBehavior.name,
    'trackerBlockingEnabled': trackerBlockingEnabled,
    'adblockAllowlist': adblockAllowlist,
    'darkModePreference': darkModePreference.name,
    'translateTargetLang': translateTargetLang,
    'siteZoomLevels': siteZoomLevels,
    'siteUserAgents': siteUserAgents,
    'autoRetry': autoRetry,
    'retryLimit': retryLimit,
    'minSpeedThresholdKbps': minSpeedThresholdKbps,
    'stallTimeoutSeconds': stallTimeoutSeconds,
    'partialDownloadThreshold': partialDownloadThreshold,
  };

  factory DownloadSettings.fromJson(Map<String, dynamic> json) {
    final defaults = DownloadSettings.defaults();
    return DownloadSettings(
      maxConcurrentDownloads:
          (json['maxConcurrentDownloads'] as num?)?.round() ??
          defaults.maxConcurrentDownloads,
      chunksPerTask:
          (json['chunksPerTask'] as num?)?.round() ?? defaults.chunksPerTask,
      downloadDestination:
          json['downloadDestination'] as String? ??
          defaults.downloadDestination,
      searchEngine: json['searchEngine'] is Map
          ? SearchEngine.fromJson(
              Map<String, dynamic>.from(json['searchEngine'] as Map),
            )
          : defaults.searchEngine,
      adblockEnabled:
          json['adblockEnabled'] as bool? ?? defaults.adblockEnabled,
      popupBlockingEnabled:
          json['popupBlockingEnabled'] as bool? ??
          defaults.popupBlockingEnabled,
      adblockFilterSources:
          _parseFilterSources(
            json['adblockFilterSources'] as List? ??
                json['adblockFilterSourceUrls'] as List?,
          ) ??
          defaults.adblockFilterSources,
      manualAdBlockRules:
          _parseManualAdBlockRules(json['manualAdBlockRules'] as List?) ??
          defaults.manualAdBlockRules,
      manualCosmeticRules:
          _parseCosmeticAdRules(json['manualCosmeticRules'] as List?) ??
          defaults.manualCosmeticRules,
      sniffedMediaSort: SniffedMediaSort.values.byName(
        json['sniffedMediaSort'] as String? ?? defaults.sniffedMediaSort.name,
      ),
      sniffedMediaDisplayMode: SniffedMediaDisplayMode.values.byName(
        json['sniffedMediaDisplayMode'] as String? ??
            defaults.sniffedMediaDisplayMode.name,
      ),
      browserToolbarPosition: BrowserToolbarPosition.values.byName(
        json['browserToolbarPosition'] as String? ??
            defaults.browserToolbarPosition.name,
      ),
      desktopMode: json['desktopMode'] as bool? ?? false,
      userAgentProfile: json['userAgentProfile'] as String? ?? 'mobile',
      privateMode: json['privateMode'] as bool? ?? false,
      wifiOnly: json['wifiOnly'] as bool? ?? false,
      readerMode: json['readerMode'] as bool? ?? false,
      captureShowAllMedia: json['captureShowAllMedia'] as bool? ?? false,
      maxDetectedMedia:
          (json['maxDetectedMedia'] as num?)?.round() ?? 200,
      minMediaSizeKb:
          (json['minMediaSizeKb'] as num?)?.round() ?? 0,
      minMediaDurationSeconds:
          (json['minMediaDurationSeconds'] as num?)?.round() ?? 0,
      disabledMediaTypes: _parseDisabledMediaTypes(
        json['disabledMediaTypes'] as List?,
      ),
      doNotTrackEnabled:
          json['doNotTrackEnabled'] as bool? ?? defaults.doNotTrackEnabled,
      downloadLinkBehavior: DownloadLinkBehavior.values.byName(
        json['downloadLinkBehavior'] as String? ??
            defaults.downloadLinkBehavior.name,
      ),
      trackerBlockingEnabled: json['trackerBlockingEnabled'] as bool? ??
          defaults.trackerBlockingEnabled,
      adblockAllowlist: (json['adblockAllowlist'] as List?)
          ?.cast<String>() ?? defaults.adblockAllowlist,
      darkModePreference: DarkModePreference.values.byName(
        json['darkModePreference'] as String? ??
            defaults.darkModePreference.name,
      ),
      translateTargetLang: json['translateTargetLang'] as String? ??
          defaults.translateTargetLang,
      siteZoomLevels: _parseStringDoubleMap(
        json['siteZoomLevels'] as Map?,
      ),
      siteUserAgents: _parseStringStringMap(json['siteUserAgents'] as Map?),
      autoRetry: json['autoRetry'] as bool? ?? true,
      retryLimit: (json['retryLimit'] as num?)?.round() ?? defaults.retryLimit,
      minSpeedThresholdKbps:
          (json['minSpeedThresholdKbps'] as num?)?.round() ?? 0,
      stallTimeoutSeconds:
          (json['stallTimeoutSeconds'] as num?)?.round() ?? 20,
      partialDownloadThreshold:
          (json['partialDownloadThreshold'] as num?)?.toDouble() ?? 0.95,
    );
  }

  static Set<MediaType> _parseDisabledMediaTypes(List? raw) {
    if (raw == null) return const {};
    final result = <MediaType>{};
    for (final item in raw) {
      if (item is String) {
        try {
          result.add(MediaType.values.byName(item));
        } catch (_) {}
      }
    }
    return result;
  }

  static Map<String, double> _parseStringDoubleMap(Map? raw) {
    if (raw == null) return const {};
    final result = <String, double>{};
    raw.forEach((key, value) {
      if (key is String && value is num) {
        result[key.toLowerCase()] = value.toDouble();
      }
    });
    return result;
  }

  static Map<String, String> _parseStringStringMap(Map? raw) {
    if (raw == null) return const {};
    final result = <String, String>{};
    raw.forEach((key, value) {
      if (key is String && value is String && value.trim().isNotEmpty) {
        result[key.toLowerCase()] = value;
      }
    });
    return result;
  }
  static List<AdblockFilterSource>? _parseFilterSources(List? raw) {
    if (raw == null || raw.isEmpty) return null;
    final result = <AdblockFilterSource>[];
    for (final item in raw) {
      if (item is Map) {
        result.add(
          AdblockFilterSource.fromJson(Map<String, dynamic>.from(item)),
        );
      } else if (item is String) {
        result.add(
          AdblockFilterSource(
            name: Uri.tryParse(item)?.host ?? item,
            url: item,
          ),
        );
      }
    }
    if (result.isNotEmpty) {
      final trustedUrls = {for (final s in AdblockFilterSource.trustedSources) s.url};
      for (int i = 0; i < result.length; i++) {
        if (trustedUrls.contains(result[i].url)) {
          result[i] = result[i].copyWith(enabled: false);
        }
      }
    }
    return result.isEmpty ? null : result;
  }

  static List<ManualAdBlockRule>? _parseManualAdBlockRules(List? raw) {
    if (raw == null) return null;
    final result = <ManualAdBlockRule>[];
    for (final item in raw) {
      if (item is Map) {
        final rule = ManualAdBlockRule.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (rule.pattern.trim().isNotEmpty) result.add(rule);
      } else if (item is String && item.trim().isNotEmpty) {
        result.add(ManualAdBlockRule(pattern: item.trim()));
      }
    }
    return result;
  }

  static List<CosmeticAdRule>? _parseCosmeticAdRules(List? raw) {
    if (raw == null) return null;
    final result = <CosmeticAdRule>[];
    for (final item in raw) {
      if (item is Map) {
        final rule = CosmeticAdRule.fromJson(Map<String, dynamic>.from(item));
        if (rule.host.trim().isNotEmpty && rule.selector.trim().isNotEmpty) {
          result.add(rule);
        }
      }
    }
    return result;
  }
}

class DownloadSettingsStore {
  final String fileName;

  const DownloadSettingsStore({this.fileName = 'download_settings.json'});

  Future<DownloadSettings> load() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return DownloadSettings.defaults();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return DownloadSettings.defaults();
      return DownloadSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return DownloadSettings.defaults();
    }
  }

  Future<void> save(DownloadSettings settings) async {
    final file = await _settingsFile();
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await file.writeAsString(jsonEncode(settings.toJson()));
  }

  Future<File> _settingsFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }
}
