import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../sniffer/models/sniffed_media.dart' show MediaType;
import '../backup/auto_backup_models.dart';

enum SniffedMediaSort { newest, name, type, size, duration }

enum SniffedMediaDisplayMode { size, duration, both }

/// Which backend the in-app player decodes with. See
/// `lib/sniffer/player/playback_engine.dart` — kept as its own enum here so
/// settings persistence does not drag the player package into this file.
enum PlaybackEngineSetting { videoPlayer, mediaKit }

enum BrowserToolbarPosition { bottom, top }

enum DarkModePreference {
  system,
  off,
  forced,
}

/// Proxy protocol type.
enum ProxyType {
  /// No proxy.
  none,

  /// HTTP / HTTPS proxy.
  http,

  /// SOCKS5 proxy.
  socks5,
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

class AppSupportedLanguage {
  final String code;
  final String name;

  const AppSupportedLanguage({required this.code, required this.name});
}

const kAppSupportedLanguages = <AppSupportedLanguage>[
  AppSupportedLanguage(code: 'system', name: 'System Default'),
  AppSupportedLanguage(code: 'en', name: 'English'),
  AppSupportedLanguage(code: 'fr', name: 'Français'),
  AppSupportedLanguage(code: 'es', name: 'Español'),
  AppSupportedLanguage(code: 'zh', name: '中文 (简体)'),
  AppSupportedLanguage(code: 'hi', name: 'हिन्दी'),
  AppSupportedLanguage(code: 'ar', name: 'العربية'),
  AppSupportedLanguage(code: 'id', name: 'Bahasa Indonesia'),
  AppSupportedLanguage(code: 'ja', name: '日本語'),
  AppSupportedLanguage(code: 'pt', name: 'Português'),
  AppSupportedLanguage(code: 'ru', name: 'Русский'),
  AppSupportedLanguage(code: 'de', name: 'Deutsch'),
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

  /// Returns the default list of trusted filter sources.
  /// Exactly 3 slots are enabled by default (fitting within [freeFilterListSlots]):
  /// - EasyList (Ads)
  /// - EasyPrivacy (Trackers & Privacy)
  /// - Peter Lowe's List (Adservers & tracking)
  static List<AdblockFilterSource> defaultSources() {
    const defaultEnabledUrls = {
      'https://easylist.to/easylist/easylist.txt',
      'https://easylist.to/easylist/easyprivacy.txt',
      'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblock&showintro=0&mimetype=plaintext',
    };
    return [
      for (final source in trustedSources)
        source.copyWith(enabled: defaultEnabledUrls.contains(source.url)),
    ];
  }

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

  /// Page host this rule was created from, when it came from the element
  /// picker.
  ///
  /// Needed because [pattern] is the *resource* host (`ads.example-cdn.net`),
  /// which usually has nothing to do with the page the user was on. Without
  /// this, "Reset element blocks" on a page could never find the network rules
  /// that page created, so they silently accumulated forever. Null for rules
  /// typed by hand in settings and for anything saved before this field.
  final String? addedForHost;

  ManualAdBlockRule({
    required this.pattern,
    this.domainRule = false,
    this.addedForHost,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'pattern': pattern,
    'domainRule': domainRule,
    'addedForHost': addedForHost,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ManualAdBlockRule.fromJson(Map<String, dynamic> json) {
    return ManualAdBlockRule(
      pattern: json['pattern'] as String? ?? '',
      domainRule: json['domainRule'] as bool? ?? false,
      addedForHost: json['addedForHost'] as String?,
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
  /// User-facing destination under the public Downloads collection.
  /// Always normalized to `Downloads/<folder…>` (never outside Downloads).
  static const String defaultDownloadDestination = 'Downloads/Aurora Downloader';

  /// MediaStore / native RELATIVE_PATH form (`Download/...`).
  static String mediaStoreRelativeFromDisplay(String displayPath) {
    final n = normalizeDownloadDestination(displayPath);
    if (n.startsWith('Downloads/')) {
      return 'Download/${n.substring('Downloads/'.length)}';
    }
    return 'Download/Aurora Downloader';
  }

  /// Display form for UI (`Downloads/...`).
  static String displayFromMediaStoreRelative(String relativePath) {
    final r = relativePath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    if (r.startsWith('Download/')) {
      return 'Downloads/${r.substring('Download/'.length)}';
    }
    if (r.startsWith('Downloads/')) return r;
    return defaultDownloadDestination;
  }

  /// Coerce any stored/legacy value into a safe Downloads-relative path.
  /// Migrates old `Aurora Downloads` → `Aurora Downloader`.
  static String normalizeDownloadDestination(String? raw) {
    var s = (raw ?? '').trim().replaceAll('\\', '/');
    if (s.isEmpty) return defaultDownloadDestination;

    // Legacy app name (plural "Downloads").
    s = s.replaceAll('Aurora Downloads', 'Aurora Downloader');

    // Strip accidental leading slashes.
    s = s.replaceFirst(RegExp(r'^/+'), '');

    // MediaStore form → display form.
    if (s.startsWith('Download/') && !s.startsWith('Downloads/')) {
      s = 'Downloads/${s.substring('Download/'.length)}';
    }

    // Force under Downloads/ — Android scoped storage only lets us publish
    // into the shared Downloads collection via MediaStore without SAF.
    if (!s.startsWith('Downloads/')) {
      // If user typed only a folder name, nest it under Downloads.
      s = 'Downloads/$s';
    }

    // Drop `..` segments and empty parts.
    final parts = s
        .split('/')
        .where((p) => p.isNotEmpty && p != '.' && p != '..')
        .toList();
    if (parts.isEmpty || parts.first != 'Downloads') {
      return defaultDownloadDestination;
    }
    // Need at least Downloads/<something>
    if (parts.length < 2) {
      return defaultDownloadDestination;
    }
    // Sanitize folder name characters (no control chars).
    final cleaned = parts.map((p) {
      return p.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_').trim();
    }).where((p) => p.isNotEmpty).toList();
    if (cleaned.length < 2) return defaultDownloadDestination;
    return cleaned.join('/');
  }

  final int maxConcurrentDownloads;
  final int chunksPerTask;
  final String downloadDestination;
  final SearchEngine searchEngine;
  final bool adblockEnabled;
  final bool cloudflareStealthEnabled;
  final bool popupBlockingEnabled;
  final bool invisibleRedirectBlockingEnabled;

  /// Per-source-site redirect blocklist: `sourceHost → [targetHost, …]`.
  /// When the user picks "Always block on this site" in the redirect prompt,
  /// the source host is mapped to the blocked target so future redirects
  /// from that source are cancelled silently instead of prompting again.
  final Map<String, List<String>> alwaysBlockedRedirectHosts;
  final List<AdblockFilterSource> adblockFilterSources;
  final List<ManualAdBlockRule> manualAdBlockRules;
  final List<CosmeticAdRule> manualCosmeticRules;
  final SniffedMediaSort sniffedMediaSort;
  final SniffedMediaDisplayMode sniffedMediaDisplayMode;

  /// Backend for the in-app player. Switching is also offered in the player
  /// itself when a stream fails to start, and that choice persists here.
  final PlaybackEngineSetting playbackEngine;

  final BrowserToolbarPosition browserToolbarPosition;
  final bool desktopMode;
  /// User-Agent profile key: 'mobile' (default), 'desktop_chrome',
  /// 'desktop_firefox', 'safari'. Controls the global UA sent by both
  /// the WebView and the Dart HTTP download client.
  final String userAgentProfile;
  final String customUserAgent;
  final bool privateMode;
  final bool wifiOnly;
  final bool readerMode;
  /// When true, site `<video>`/`<audio>` play is intercepted and Aurora's
  /// in-app player opens instead (UC Browser-style). Free core feature.
  final bool replaceSitePlayer;
  final bool captureShowAllMedia;
  final int maxDetectedMedia;
  final Set<MediaType> disabledMediaTypes;
  final bool doNotTrackEnabled;
  final DownloadLinkBehavior downloadLinkBehavior;
  final bool trackerBlockingEnabled;
  final List<String> adblockAllowlist;
  final List<String> customVideoHosts;
  final List<String> externalBrowserHosts;
  final DarkModePreference darkModePreference;
  final String appLanguageCode;
  final String translateTargetLang;
  final Map<String, double> siteZoomLevels;
  final Map<String, String> siteUserAgents;
  final List<String> menuSettingsOrder;
  final List<String> menuToolOrder;

  // --- Proxy settings ---
  final ProxyType proxyType;
  final String proxyHost;
  final int proxyPort;
  final String proxyUsername;
  final String proxyPassword;

  final bool autoRetry;
  final int retryLimit;
  final int minSpeedThresholdKbps;
  final int stallTimeoutSeconds;
  /// When a download stalls or fails above this percentage (0.0–1.0),
  /// the app will suggest merging the partial file instead of discarding it.
  /// Set to 1.0 to disable this behavior entirely.
  final double partialDownloadThreshold;

  /// When true, completed files are automatically sorted into subdirectories
  /// (Videos, Audio, Images, Documents, etc.) under the completed/ folder.
  final bool autoClassifyEnabled;

  /// When true, MPEG-TS files (.ts) are remuxed to MP4 after download
  /// (no transcoding — just a fast container change). Only affects
  /// direct .ts downloads; HLS streams already remux via HlsDownloader.
  final bool remuxTsToMp4;

  /// When true, the filename includes a quality suffix like "(720p)" when
  /// a resolution label (e.g. 720p, 1080p) is detected in the media URL.
  final bool includeQualitySuffix;

  /// Optional overrides: file extension → folder name.
  /// E.g. `{".mp4": "Movies", ".mkv": "Movies"}` routes all MP4s and MKVs
  /// into a "Movies" subfolder instead of the default "Videos" folder.
  final Map<String, String> autoClassifyMappings;

  /// When true, temporary alert snackbars are shown at the bottom of the screen.
  final bool showSnackbars;

  final bool autoBackupEnabled;
  final int autoBackupFrequencyHours;
  final bool autoBackupFavorites;
  final bool autoBackupHistory;
  final bool autoBackupSavedPages;
  final bool autoBackupQueue;
  final bool autoBackupSettings;
  final int lastBackupTimestamp;
  final AutoBackupInterval autoBackupInterval;
  final bool neverAskBatteryOpt;

  /// True after we have shown the POST_NOTIFICATIONS system prompt once.
  /// Prevents re-requesting on every launch when the user already denied.
  final bool notificationPermissionAsked;

  const DownloadSettings({
    required this.maxConcurrentDownloads,
    required this.chunksPerTask,
    required this.downloadDestination,
    required this.searchEngine,
    required this.adblockEnabled,
    this.cloudflareStealthEnabled = true,
    this.popupBlockingEnabled = true,
    this.invisibleRedirectBlockingEnabled = true,
    this.alwaysBlockedRedirectHosts = const {},
    required this.adblockFilterSources,
    this.manualAdBlockRules = const [],
    this.manualCosmeticRules = const [],
    required this.sniffedMediaSort,
    required this.sniffedMediaDisplayMode,
    this.playbackEngine = PlaybackEngineSetting.videoPlayer,
    required this.browserToolbarPosition,
    this.desktopMode = false,
    this.userAgentProfile = 'mobile',
    this.customUserAgent = '',
    this.privateMode = false,
    this.wifiOnly = false,
    this.readerMode = false,
    // Default off: site players work normally; an IDM-style floating
    // button opens Aurora when the user wants it. Auto-replace on play
    // remains available as an optional Settings toggle.
    this.replaceSitePlayer = false,
    this.captureShowAllMedia = false,
    this.maxDetectedMedia = 200,
    this.disabledMediaTypes = const {},
    this.doNotTrackEnabled = true,
    this.downloadLinkBehavior = DownloadLinkBehavior.ask,
    this.trackerBlockingEnabled = true,
    this.adblockAllowlist = const [],
    this.customVideoHosts = const [],
    this.externalBrowserHosts = const [],
    this.darkModePreference = DarkModePreference.system,
    this.appLanguageCode = 'system',
    this.translateTargetLang = 'en',
    this.siteZoomLevels = const {},
    this.siteUserAgents = const {},
    this.menuSettingsOrder = const [],
    this.menuToolOrder = const [],
    this.proxyType = ProxyType.none,
    this.proxyHost = '',
    this.proxyPort = 8080,
    this.proxyUsername = '',
    this.proxyPassword = '',
    this.autoRetry = true,
    this.retryLimit = 3,
    this.minSpeedThresholdKbps = 10,
    this.stallTimeoutSeconds = 20,
    this.partialDownloadThreshold = 0.95,
    this.autoClassifyEnabled = true,
    this.remuxTsToMp4 = true,
    this.includeQualitySuffix = true,
    this.autoClassifyMappings = const {},
    this.showSnackbars = true,
    this.autoBackupEnabled = false,
    this.autoBackupFrequencyHours = 24,
    this.autoBackupFavorites = true,
    this.autoBackupHistory = true,
    this.autoBackupSavedPages = true,
    this.autoBackupQueue = true,
    this.autoBackupSettings = true,
    this.lastBackupTimestamp = 0,
    this.autoBackupInterval = AutoBackupInterval.daily,
    this.neverAskBatteryOpt = false,
    this.notificationPermissionAsked = false,
  });

  static const trustedAdblockSources = [
    'https://easylist.to/easylist/easylist.txt',
    'https://easylist.to/easylist/easyprivacy.txt',
    'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblock&showintro=0&mimetype=plaintext',
    'https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt',
  ];

  factory DownloadSettings.defaults() => DownloadSettings(
    maxConcurrentDownloads: 3,
    chunksPerTask: 16,
    downloadDestination: defaultDownloadDestination,
    searchEngine: SearchEngine.google,
    adblockEnabled: true,
    popupBlockingEnabled: true,
    invisibleRedirectBlockingEnabled: true,
    adblockFilterSources: AdblockFilterSource.defaultSources(),
    sniffedMediaSort: SniffedMediaSort.newest,
    sniffedMediaDisplayMode: SniffedMediaDisplayMode.both,
    playbackEngine: PlaybackEngineSetting.videoPlayer,
    browserToolbarPosition: BrowserToolbarPosition.bottom,
    autoRetry: true,
    retryLimit: 3,
    minSpeedThresholdKbps: 10,
    autoClassifyEnabled: true,
    remuxTsToMp4: true,
    includeQualitySuffix: true,
    showSnackbars: true,
    neverAskBatteryOpt: false,
  );

  DownloadSettings copyWith({
    int? maxConcurrentDownloads,
    int? chunksPerTask,
    String? downloadDestination,
    SearchEngine? searchEngine,
    bool? adblockEnabled,
    bool? cloudflareStealthEnabled,
    bool? popupBlockingEnabled,
    bool? invisibleRedirectBlockingEnabled,
    Map<String, List<String>>? alwaysBlockedRedirectHosts,
    List<AdblockFilterSource>? adblockFilterSources,
    List<ManualAdBlockRule>? manualAdBlockRules,
    List<CosmeticAdRule>? manualCosmeticRules,
    SniffedMediaSort? sniffedMediaSort,
    SniffedMediaDisplayMode? sniffedMediaDisplayMode,
    PlaybackEngineSetting? playbackEngine,
    BrowserToolbarPosition? browserToolbarPosition,
    bool? desktopMode,
    String? userAgentProfile,
    String? customUserAgent,
    bool? privateMode,
    bool? wifiOnly,
    bool? readerMode,
    bool? replaceSitePlayer,
    bool? captureShowAllMedia,
    int? maxDetectedMedia,
    Set<MediaType>? disabledMediaTypes,
    bool? doNotTrackEnabled,
    DownloadLinkBehavior? downloadLinkBehavior,
    bool? trackerBlockingEnabled,
    List<String>? adblockAllowlist,
    List<String>? customVideoHosts,
    List<String>? externalBrowserHosts,
    DarkModePreference? darkModePreference,
    String? appLanguageCode,
    String? translateTargetLang,
    Map<String, double>? siteZoomLevels,
    Map<String, String>? siteUserAgents,
    List<String>? menuSettingsOrder,
    List<String>? menuToolOrder,
    ProxyType? proxyType,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool? autoRetry,
    int? retryLimit,
    int? minSpeedThresholdKbps,
    int? stallTimeoutSeconds,
    double? partialDownloadThreshold,
    bool? autoClassifyEnabled,
    bool? remuxTsToMp4,
    bool? includeQualitySuffix,
    Map<String, String>? autoClassifyMappings,
    bool? showSnackbars,
    bool? autoBackupEnabled,
    int? autoBackupFrequencyHours,
    bool? autoBackupFavorites,
    bool? autoBackupHistory,
    bool? autoBackupSavedPages,
    bool? autoBackupQueue,
    bool? autoBackupSettings,
    int? lastBackupTimestamp,
    AutoBackupInterval? autoBackupInterval,
    bool? neverAskBatteryOpt,
    bool? notificationPermissionAsked,
  }) {
    return DownloadSettings(
      autoRetry: autoRetry ?? this.autoRetry,
      retryLimit: retryLimit ?? this.retryLimit,
      minSpeedThresholdKbps:
          minSpeedThresholdKbps ?? this.minSpeedThresholdKbps,
      stallTimeoutSeconds: stallTimeoutSeconds ?? this.stallTimeoutSeconds,
      partialDownloadThreshold:
          partialDownloadThreshold ?? this.partialDownloadThreshold,
      autoClassifyEnabled:
          autoClassifyEnabled ?? this.autoClassifyEnabled,
      remuxTsToMp4: remuxTsToMp4 ?? this.remuxTsToMp4,
      includeQualitySuffix:
          includeQualitySuffix ?? this.includeQualitySuffix,
      autoClassifyMappings:
          autoClassifyMappings ?? this.autoClassifyMappings,
      showSnackbars: showSnackbars ?? this.showSnackbars,
      autoBackupEnabled: autoBackupEnabled ?? this.autoBackupEnabled,
      autoBackupFrequencyHours: autoBackupFrequencyHours ?? this.autoBackupFrequencyHours,
      autoBackupFavorites: autoBackupFavorites ?? this.autoBackupFavorites,
      autoBackupHistory: autoBackupHistory ?? this.autoBackupHistory,
      autoBackupSavedPages: autoBackupSavedPages ?? this.autoBackupSavedPages,
      autoBackupQueue: autoBackupQueue ?? this.autoBackupQueue,
      autoBackupSettings: autoBackupSettings ?? this.autoBackupSettings,
      lastBackupTimestamp: lastBackupTimestamp ?? this.lastBackupTimestamp,
      autoBackupInterval: autoBackupInterval ?? this.autoBackupInterval,
      neverAskBatteryOpt: neverAskBatteryOpt ?? this.neverAskBatteryOpt,
      notificationPermissionAsked:
          notificationPermissionAsked ?? this.notificationPermissionAsked,
      maxConcurrentDownloads:
          maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      chunksPerTask: chunksPerTask ?? this.chunksPerTask,
      downloadDestination: downloadDestination != null
          ? normalizeDownloadDestination(downloadDestination)
          : this.downloadDestination,
      searchEngine: searchEngine ?? this.searchEngine,
      adblockEnabled: adblockEnabled ?? this.adblockEnabled,
      cloudflareStealthEnabled:
          cloudflareStealthEnabled ?? this.cloudflareStealthEnabled,
      popupBlockingEnabled: popupBlockingEnabled ?? this.popupBlockingEnabled,
      invisibleRedirectBlockingEnabled: invisibleRedirectBlockingEnabled ?? this.invisibleRedirectBlockingEnabled,
      alwaysBlockedRedirectHosts:
          alwaysBlockedRedirectHosts ?? this.alwaysBlockedRedirectHosts,
      adblockFilterSources: adblockFilterSources ?? this.adblockFilterSources,
      manualAdBlockRules: manualAdBlockRules ?? this.manualAdBlockRules,
      manualCosmeticRules: manualCosmeticRules ?? this.manualCosmeticRules,
      sniffedMediaSort: sniffedMediaSort ?? this.sniffedMediaSort,
      sniffedMediaDisplayMode:
          sniffedMediaDisplayMode ?? this.sniffedMediaDisplayMode,
      playbackEngine: playbackEngine ?? this.playbackEngine,
      browserToolbarPosition:
          browserToolbarPosition ?? this.browserToolbarPosition,
      desktopMode: desktopMode ?? this.desktopMode,
      userAgentProfile: userAgentProfile ?? this.userAgentProfile,
      customUserAgent: customUserAgent ?? this.customUserAgent,
      privateMode: privateMode ?? this.privateMode,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      readerMode: readerMode ?? this.readerMode,
      replaceSitePlayer: replaceSitePlayer ?? this.replaceSitePlayer,
      captureShowAllMedia: captureShowAllMedia ?? this.captureShowAllMedia,
      maxDetectedMedia: maxDetectedMedia ?? this.maxDetectedMedia,
      disabledMediaTypes: disabledMediaTypes ?? this.disabledMediaTypes,
      doNotTrackEnabled: doNotTrackEnabled ?? this.doNotTrackEnabled,
      downloadLinkBehavior:
          downloadLinkBehavior ?? this.downloadLinkBehavior,
      trackerBlockingEnabled:
          trackerBlockingEnabled ?? this.trackerBlockingEnabled,
      adblockAllowlist: adblockAllowlist ?? this.adblockAllowlist,
      customVideoHosts: customVideoHosts ?? this.customVideoHosts,
      externalBrowserHosts: externalBrowserHosts ?? this.externalBrowserHosts,
      darkModePreference: darkModePreference ?? this.darkModePreference,
      appLanguageCode: appLanguageCode ?? this.appLanguageCode,
      translateTargetLang:
          translateTargetLang ?? this.translateTargetLang,
      siteZoomLevels: siteZoomLevels ?? this.siteZoomLevels,
      siteUserAgents: siteUserAgents ?? this.siteUserAgents,
      menuSettingsOrder: menuSettingsOrder ?? this.menuSettingsOrder,
      menuToolOrder: menuToolOrder ?? this.menuToolOrder,
      proxyType: proxyType ?? this.proxyType,
      proxyHost: proxyHost ?? this.proxyHost,
      proxyPort: proxyPort ?? this.proxyPort,
      proxyUsername: proxyUsername ?? this.proxyUsername,
      proxyPassword: proxyPassword ?? this.proxyPassword,
    );
  }

  Map<String, dynamic> toJson() => {
    'maxConcurrentDownloads': maxConcurrentDownloads,
    'chunksPerTask': chunksPerTask,
    'downloadDestination': downloadDestination,
    'searchEngine': searchEngine.toJson(),
    'adblockEnabled': adblockEnabled,
    'cloudflareStealthEnabled': cloudflareStealthEnabled,
    'popupBlockingEnabled': popupBlockingEnabled,
    'invisibleRedirectBlockingEnabled': invisibleRedirectBlockingEnabled,
    'alwaysBlockedRedirectHosts': alwaysBlockedRedirectHosts,
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
    'playbackEngine': playbackEngine.name,
    'browserToolbarPosition': browserToolbarPosition.name,
    'desktopMode': desktopMode,
    'userAgentProfile': userAgentProfile,
    'customUserAgent': customUserAgent,
    'privateMode': privateMode,
    'wifiOnly': wifiOnly,
    'readerMode': readerMode,
    'replaceSitePlayer': replaceSitePlayer,
      'captureShowAllMedia': captureShowAllMedia,
      'maxDetectedMedia': maxDetectedMedia,
      'disabledMediaTypes': disabledMediaTypes.map((t) => t.name).toList(),
      'doNotTrackEnabled': doNotTrackEnabled,
      'downloadLinkBehavior': downloadLinkBehavior.name,
    'trackerBlockingEnabled': trackerBlockingEnabled,
      'adblockAllowlist': adblockAllowlist,
    'customVideoHosts': customVideoHosts,
    'externalBrowserHosts': externalBrowserHosts,
      'darkModePreference': darkModePreference.name,
      'appLanguageCode': appLanguageCode,
      'translateTargetLang': translateTargetLang,
    'siteZoomLevels': siteZoomLevels,
    'siteUserAgents': siteUserAgents,
    'menuSettingsOrder': menuSettingsOrder,
    'menuToolOrder': menuToolOrder,
    'proxyType': proxyType.name,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    'proxyUsername': proxyUsername,
    'proxyPassword': proxyPassword,
    'autoRetry': autoRetry,
    'retryLimit': retryLimit,
    'minSpeedThresholdKbps': minSpeedThresholdKbps,
    'stallTimeoutSeconds': stallTimeoutSeconds,
    'partialDownloadThreshold': partialDownloadThreshold,
    'autoClassifyEnabled': autoClassifyEnabled,
    'remuxTsToMp4': remuxTsToMp4,
    'includeQualitySuffix': includeQualitySuffix,
    'autoClassifyMappings': autoClassifyMappings,
    'showSnackbars': showSnackbars,
    'autoBackupEnabled': autoBackupEnabled,
    'autoBackupFrequencyHours': autoBackupFrequencyHours,
    'autoBackupFavorites': autoBackupFavorites,
    'autoBackupHistory': autoBackupHistory,
    'autoBackupSavedPages': autoBackupSavedPages,
    'autoBackupQueue': autoBackupQueue,
    'autoBackupSettings': autoBackupSettings,
    'lastBackupTimestamp': lastBackupTimestamp,
    'autoBackupInterval': autoBackupInterval.name,
    'neverAskBatteryOpt': neverAskBatteryOpt,
    'notificationPermissionAsked': notificationPermissionAsked,
  };

  factory DownloadSettings.fromJson(Map<String, dynamic> json) {
    final defaults = DownloadSettings.defaults();
    return DownloadSettings(
      maxConcurrentDownloads:
          (json['maxConcurrentDownloads'] as num?)?.round() ??
          defaults.maxConcurrentDownloads,
      chunksPerTask:
          (json['chunksPerTask'] as num?)?.round() ?? defaults.chunksPerTask,
      downloadDestination: normalizeDownloadDestination(
        json['downloadDestination'] as String? ??
            defaults.downloadDestination,
      ),
      searchEngine: json['searchEngine'] is Map
          ? SearchEngine.fromJson(
              Map<String, dynamic>.from(json['searchEngine'] as Map),
            )
          : defaults.searchEngine,
      adblockEnabled:
          json['adblockEnabled'] as bool? ?? defaults.adblockEnabled,
      cloudflareStealthEnabled:
          json['cloudflareStealthEnabled'] as bool? ?? true,
      popupBlockingEnabled:
          json['popupBlockingEnabled'] as bool? ??
          defaults.popupBlockingEnabled,
      invisibleRedirectBlockingEnabled:
          json['invisibleRedirectBlockingEnabled'] as bool? ??
          defaults.invisibleRedirectBlockingEnabled,
      alwaysBlockedRedirectHosts: _parseStringListMap(
        json['alwaysBlockedRedirectHosts'],
      ),
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
      // Tolerate an unknown name rather than throwing the whole settings load
      // away if this enum ever changes shape.
      playbackEngine: PlaybackEngineSetting.values.firstWhere(
        (e) => e.name == json['playbackEngine'],
        orElse: () => defaults.playbackEngine,
      ),
      browserToolbarPosition: BrowserToolbarPosition.values.byName(
        json['browserToolbarPosition'] as String? ??
            defaults.browserToolbarPosition.name,
      ),
      desktopMode: json['desktopMode'] as bool? ?? false,
      userAgentProfile: json['userAgentProfile'] as String? ?? 'mobile',
      customUserAgent: json['customUserAgent'] as String? ?? '',
      privateMode: json['privateMode'] as bool? ?? false,
      wifiOnly: json['wifiOnly'] as bool? ?? false,
      readerMode: json['readerMode'] as bool? ?? false,
      replaceSitePlayer: json['replaceSitePlayer'] as bool? ?? false,
      captureShowAllMedia: json['captureShowAllMedia'] as bool? ?? false,
      maxDetectedMedia:
          (json['maxDetectedMedia'] as num?)?.round() ?? 200,
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
      customVideoHosts: (json['customVideoHosts'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          defaults.customVideoHosts,
      externalBrowserHosts: (json['externalBrowserHosts'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          defaults.externalBrowserHosts,
      darkModePreference: DarkModePreference.values.byName(
        json['darkModePreference'] as String? ??
            defaults.darkModePreference.name,
      ),
      appLanguageCode:
          json['appLanguageCode'] as String? ?? defaults.appLanguageCode,
      translateTargetLang: json['translateTargetLang'] as String? ??
          defaults.translateTargetLang,
      siteZoomLevels: _parseZoomLevels(
        json['siteZoomLevels'] as Map?,
      ),
      siteUserAgents: _parseStringStringMap(json['siteUserAgents'] as Map?),
      menuSettingsOrder:
          (json['menuSettingsOrder'] as List?)?.cast<String>() ?? const [],
      menuToolOrder:
          (json['menuToolOrder'] as List?)?.cast<String>() ?? const [],
      proxyType: ProxyType.values.firstWhere(
        (e) => e.name == json['proxyType'],
        orElse: () => ProxyType.none,
      ),
      proxyHost: json['proxyHost'] as String? ?? '',
      proxyPort: (json['proxyPort'] as num?)?.round() ?? 8080,
      proxyUsername: json['proxyUsername'] as String? ?? '',
      proxyPassword: json['proxyPassword'] as String? ?? '',
      autoRetry: json['autoRetry'] as bool? ?? true,
      retryLimit: (json['retryLimit'] as num?)?.round() ?? defaults.retryLimit,
      minSpeedThresholdKbps:
          (json['minSpeedThresholdKbps'] as num?)?.round() ?? defaults.minSpeedThresholdKbps,
      stallTimeoutSeconds:
          (json['stallTimeoutSeconds'] as num?)?.round() ?? 20,
      partialDownloadThreshold:
          (json['partialDownloadThreshold'] as num?)?.toDouble() ?? 0.95,
      autoClassifyEnabled:
          json['autoClassifyEnabled'] as bool? ?? true,
      remuxTsToMp4:
          json['remuxTsToMp4'] as bool? ?? true,
      includeQualitySuffix:
          json['includeQualitySuffix'] as bool? ?? true,
      autoClassifyMappings:
          json['autoClassifyMappings'] is Map
              ? Map<String, String>.from(
                  (json['autoClassifyMappings'] as Map).map(
                    (k, v) => MapEntry(k.toString(), v.toString()),
                  ),
                )
              : const {},
      showSnackbars:
          json['showSnackbars'] as bool? ?? true,
      autoBackupEnabled:
          json['autoBackupEnabled'] as bool? ?? false,
      autoBackupFrequencyHours:
          (json['autoBackupFrequencyHours'] as num?)?.round() ?? 24,
      autoBackupFavorites:
          json['autoBackupFavorites'] as bool? ?? true,
      autoBackupHistory:
          json['autoBackupHistory'] as bool? ?? true,
      autoBackupSavedPages:
          json['autoBackupSavedPages'] as bool? ?? true,
      autoBackupQueue:
          json['autoBackupQueue'] as bool? ?? true,
      autoBackupSettings:
          json['autoBackupSettings'] as bool? ?? true,
      lastBackupTimestamp:
          (json['lastBackupTimestamp'] as num?)?.round() ?? 0,
      autoBackupInterval:
          AutoBackupInterval.fromName(json['autoBackupInterval'] as String?),
      neverAskBatteryOpt: json['neverAskBatteryOpt'] as bool? ?? false,
      notificationPermissionAsked:
          json['notificationPermissionAsked'] as bool? ?? false,
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

  /// Parses per-site zoom levels with the same clamping applied at zoom-time
  /// (0.5x–3.0x). Rejects non-finite values and drops no-op (~1.0x) entries so
  /// a corrupted or out-of-range persisted value can't break zoom math on load.
  static Map<String, double> _parseZoomLevels(Map? raw) {
    if (raw == null) return const {};
    const minZoom = 0.5;
    const maxZoom = 3.0;
    final result = <String, double>{};
    raw.forEach((key, value) {
      if (key is String && value is num) {
        final v = value.toDouble();
        if (!v.isFinite) return;
        final clamped = v.clamp(minZoom, maxZoom).toDouble();
        if ((clamped - 1.0).abs() < 0.01) return; // drop no-op zoom
        result[key.toLowerCase()] = double.parse(clamped.toStringAsFixed(2));
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

  /// Parses a `{sourceHost: [targetHost, …]}` map for
  /// [alwaysBlockedRedirectHosts]. Hosts are lowercased; empty lists and
  /// non-string entries are dropped.
  static Map<String, List<String>> _parseStringListMap(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    raw.forEach((key, value) {
      if (key is! String || key.trim().isEmpty) return;
      if (value is! List || value.isEmpty) return;
      final targets = <String>[];
      for (final item in value) {
        if (item is String && item.trim().isNotEmpty) {
          targets.add(item.toLowerCase());
        }
      }
      if (targets.isNotEmpty) {
        result[key.toLowerCase()] = targets;
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
    final encoded = jsonEncode(settings.toJson());
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(encoded, flush: true);
    try {
      await tempFile.rename(file.path);
    } catch (_) {
      await tempFile.copy(file.path);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<File> _settingsFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }
}
