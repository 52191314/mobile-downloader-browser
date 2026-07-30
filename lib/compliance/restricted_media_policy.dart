import '../premium/build_channel.dart';

/// Play Store compliance gates for media sniffing and downloads.
///
/// **Play channel only:** known DRM / ToS / policy-hotspot platforms are
/// hard-blocked when `AURORA_BUILD_CHANNEL=play`. GitHub / sideload builds
/// leave capture and download unrestricted so the open-source APK can keep
/// full sniffer capability. See `docs/play_store_compliance.md` and
/// `docs/play_restricted_hosts_plan.md`.
///
/// Wave 1 groups: YouTube, TikTok, Meta (FB/IG), Netflix, Spotify, Twitch.
/// Wave 2+ groups (Prime Video, Disney+, Max, Crunchyroll, Apple TV+) will be
/// added in future waves per the plan.
class RestrictedMediaPolicy {
  RestrictedMediaPolicy._();

  // ---------------------------------------------------------------------------
  // Public message strings (canonical — no platform-specific messages)
  // ---------------------------------------------------------------------------

  /// User-facing copy when sniff/download is blocked for Play compliance.
  static const userMessageRestricted =
      'Downloading from this service is not supported in compliance with '
      'Google Play Store policies.';

  /// Shorter banner for page-load notices (Play builds only).
  static const pageNoticeRestricted =
      'Media capture and download are disabled on this site for Play compliance.';

  // ---------------------------------------------------------------------------
  // Channel gating
  // ---------------------------------------------------------------------------

  /// True when this binary enforces Play restricted-media rules.
  ///
  /// Default channel is `github` → false. Play APKs built with
  /// `--dart-define=AURORA_BUILD_CHANNEL=play` → true.
  static bool get enforcementEnabled => BuildChannel.isPlay;

  // ---------------------------------------------------------------------------
  // Platform group definitions (Wave 1)
  // ---------------------------------------------------------------------------

  static final List<_PlatformGroup> _groups = [
    _PlatformGroup(
      reason: RestrictedMediaReason.youtube,
      surfaceHosts: [
        'youtube.com',
        'youtube-nocookie.com',
        'youtu.be',
        'youtube.googleapis.com',
        'youtubei.googleapis.com',
        'ytimg.com',
        'ggpht.com',
      ],
      mediaHosts: [
        'googlevideo.com',
        'youtube.com',
      ],
    ),
    _PlatformGroup(
      reason: RestrictedMediaReason.tiktok,
      surfaceHosts: [
        'tiktok.com',
        'musical.ly',
        'byteoversea.com',
      ],
      mediaHosts: [
        'tiktokv.com',
        'tiktokcdn.com',
        'ibytedtos.com',
        'ttlivecdn.com',
      ],
    ),
    _PlatformGroup(
      reason: RestrictedMediaReason.meta,
      surfaceHosts: [
        'facebook.com',
        'fb.com',
        'instagram.com',
        'ig.me',
      ],
      mediaHosts: [
        'fbcdn.net',
        'fbcdn.com',
        'cdninstagram.com',
      ],
    ),
    _PlatformGroup(
      reason: RestrictedMediaReason.netflix,
      surfaceHosts: [
        'netflix.com',
      ],
      mediaHosts: [
        'nflxvideo.net',
        'nflximg.net',
        'nflxso.net',
        'nflxext.com',
      ],
    ),
    _PlatformGroup(
      reason: RestrictedMediaReason.spotify,
      surfaceHosts: [
        'spotify.com',
      ],
      mediaHosts: [
        'pscdn.co',
        'scdn.co',
        'spotifycdn.com',
      ],
    ),
    _PlatformGroup(
      reason: RestrictedMediaReason.twitch,
      surfaceHosts: [
        'twitch.tv',
      ],
      mediaHosts: [
        'ttvnw.net',
        'jtvnw.net',
      ],
    ),
  ];

  // ---------------------------------------------------------------------------
  // Public helpers — group-aware replaces of old YouTube-only methods
  // ---------------------------------------------------------------------------

  /// True if [url] host matches any restricted platform's surface or media
  /// hosts (all groups). Replaces the old `isYouTubeUrl`.
  static bool isRestrictedUrl(String? url) {
    final host = _hostOf(url);
    if (host == null) return false;
    return _matchesAnyGroup(host);
  }

  /// True if the active page [pageUrl] host matches any restricted platform's
  /// surface hosts. Replaces the old `isYouTubePage`.
  static bool isRestrictedPage(String? pageUrl) {
    final host = _hostOf(pageUrl);
    if (host == null) return false;
    return _matchesAnyGroupSurface(host);
  }

  /// Play channel + restricted **surface** page → hard-off sniffing for the tab.
  ///
  /// Does not require a media URL. Use for "disable sniffer on this site."
  /// CDN / paste backstops still use [isBlocked].
  static bool shouldHardOffSniffing(String? pageUrl) {
    if (!enforcementEnabled) return false;
    return isRestrictedPage(pageUrl);
  }

  // ---------------------------------------------------------------------------
  // Core evaluation
  // ---------------------------------------------------------------------------

  /// Full evaluation for a media capture or download attempt.
  ///
  /// On **GitHub** builds: always allowed (no Play policy gate).
  /// On **Play** builds: blocks when media URL, page, Referer, or Origin is a
  /// restricted platform (any Wave 1 group).
  ///
  /// [forceEnforce] is for unit tests only — production call sites omit it.
  static RestrictedMediaDecision evaluate({
    required String mediaUrl,
    String? sourcePageUrl,
    String? referer,
    String? origin,
    Map<String, String>? headers,
    bool? forceEnforce,
  }) {
    final enforce = forceEnforce ?? enforcementEnabled;
    if (!enforce) {
      return RestrictedMediaDecision.allowed();
    }

    final headerReferer = _headerValue(headers, 'referer') ?? referer;
    final headerOrigin = _headerValue(headers, 'origin') ?? origin;

    final reason = _matchesAnyRestriction(
      mediaUrl: mediaUrl,
      sourcePageUrl: sourcePageUrl,
      referer: headerReferer,
      origin: headerOrigin,
    );
    if (reason != null) {
      return RestrictedMediaDecision.blocked(
        reason: reason,
        message: userMessageRestricted,
      );
    }
    return RestrictedMediaDecision.allowed();
  }

  /// Convenience: true when [evaluate] would block on this build channel.
  static bool isBlocked({
    required String mediaUrl,
    String? sourcePageUrl,
    String? referer,
    String? origin,
    Map<String, String>? headers,
    bool? forceEnforce,
  }) {
    return evaluate(
      mediaUrl: mediaUrl,
      sourcePageUrl: sourcePageUrl,
      referer: referer,
      origin: origin,
      headers: headers,
      forceEnforce: forceEnforce,
    ).blocked;
  }

  // ---------------------------------------------------------------------------
  // Private matching
  // ---------------------------------------------------------------------------

  /// Returns the first [RestrictedMediaReason] matching any of the media URL,
  /// source page, Referer, or Origin against all platform groups.
  /// Returns `null` when no group matches.
  static RestrictedMediaReason? _matchesAnyRestriction({
    required String mediaUrl,
    String? sourcePageUrl,
    String? referer,
    String? origin,
  }) {
    final mediaHost = _hostOf(mediaUrl);
    final pageHost = _hostOf(sourcePageUrl);
    final refererHost = _hostOf(referer);
    final originHost = _hostOf(origin);

    for (final group in _groups) {
      if (_groupMatches(group, mediaHost) ||
          _groupMatches(group, pageHost) ||
          _groupMatches(group, refererHost) ||
          _groupMatches(group, originHost)) {
        return group.reason;
      }
    }
    return null;
  }

  /// True when [host] matches any platform group's allHosts.
  static bool _matchesAnyGroup(String host) {
    for (final group in _groups) {
      if (_groupMatches(group, host)) return true;
    }
    return false;
  }

  /// True when [host] matches any platform group's surfaceHosts.
  static bool _matchesAnyGroupSurface(String host) {
    for (final group in _groups) {
      if (_matchesSuffix(host, group.surfaceHosts)) return true;
    }
    return false;
  }

  static bool _groupMatches(_PlatformGroup group, String? host) {
    if (host == null) return false;
    return _matchesSuffix(host, group.allHosts);
  }

  static bool _matchesSuffix(String host, List<String> suffixes) {
    for (final s in suffixes) {
      if (host == s || host.endsWith('.$s')) return true;
    }
    return false;
  }

  static String? _hostOf(String? url) {
    if (url == null || url.isEmpty) return null;
    final trimmed = url.trim();
    // Referer/Origin sometimes arrive without scheme.
    final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.host;
  }

  static String? _headerValue(Map<String, String>? headers, String name) {
    if (headers == null || headers.isEmpty) return null;
    final lower = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == lower) {
        final v = e.value.trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }
}

// -----------------------------------------------------------------------------
// Enums & models
// -----------------------------------------------------------------------------

enum RestrictedMediaReason {
  youtube,
  tiktok,
  meta,
  netflix,
  spotify,
  twitch,
  // Wave 2 (reserved):
  // primeVideo,
  // disney,
  // hboMax,
  // crunchyroll,
  // Wave 3 (reserved):
  // appleTv,
  // otherLicensed,
}

class RestrictedMediaDecision {
  final bool blocked;
  final RestrictedMediaReason? reason;
  final String? message;

  const RestrictedMediaDecision._({
    required this.blocked,
    this.reason,
    this.message,
  });

  factory RestrictedMediaDecision.allowed() =>
      const RestrictedMediaDecision._(blocked: false);

  factory RestrictedMediaDecision.blocked({
    required RestrictedMediaReason reason,
    required String message,
  }) =>
      RestrictedMediaDecision._(
        blocked: true,
        reason: reason,
        message: message,
      );
}

// -----------------------------------------------------------------------------
// Private helpers
// -----------------------------------------------------------------------------

class _PlatformGroup {
  final RestrictedMediaReason reason;
  final List<String> surfaceHosts;
  final List<String> mediaHosts;
  final List<String> allHosts;

  _PlatformGroup({
    required this.reason,
    required this.surfaceHosts,
    required this.mediaHosts,
  }) : allHosts = [...surfaceHosts, ...mediaHosts];
}
