import '../premium/build_channel.dart';

/// Play Store compliance gates for media sniffing and downloads.
///
/// **Play channel only:** YouTube (and its CDNs) are hard-blocked when
/// `AURORA_BUILD_CHANNEL=play`. GitHub / sideload builds leave capture and
/// download unrestricted so the open-source APK can keep full sniffer
/// capability. See `docs/play_store_compliance.md`.
///
/// Detection helpers ([isYouTubeUrl], [matchesYouTubeRestriction]) always
/// report matches; [evaluate] / [isBlocked] only enforce on Play.
class RestrictedMediaPolicy {
  RestrictedMediaPolicy._();

  /// User-facing copy when sniff/download is blocked for YouTube.
  static const userMessageYouTube =
      'Downloading from YouTube is not supported in compliance with '
      'Google Play Store policies.';

  /// Shorter banner for page-load notices (Play builds only).
  static const pageNoticeYouTube =
      'YouTube: media capture and download are disabled for Play compliance.';

  /// Host suffixes / exact hosts that belong to YouTube product surfaces.
  static const List<String> youtubeSurfaceHostSuffixes = [
    'youtube.com',
    'youtube-nocookie.com',
    'youtu.be',
    'youtube.googleapis.com',
    'youtubei.googleapis.com',
    'ytimg.com',
    'ggpht.com',
  ];

  /// Media CDN hosts used by YouTube playback (often not under youtube.com).
  static const List<String> youtubeMediaHostSuffixes = [
    'googlevideo.com',
    'youtube.com', // videoplayback paths on main host
  ];

  /// True when this binary enforces Play restricted-media rules.
  ///
  /// Default channel is `github` → false. Play APKs built with
  /// `--dart-define=AURORA_BUILD_CHANNEL=play` → true.
  static bool get enforcementEnabled => BuildChannel.isPlay;

  /// Returns true if [host] is a YouTube surface or media CDN host.
  static bool isYouTubeHost(String? host) {
    if (host == null || host.isEmpty) return false;
    final h = host.toLowerCase().trim();
    final bare = h.startsWith('www.') ? h.substring(4) : h;
    return _matchesSuffix(bare, youtubeSurfaceHostSuffixes) ||
        _matchesSuffix(bare, youtubeMediaHostSuffixes);
  }

  /// True if [url] is on a YouTube surface or known media CDN.
  static bool isYouTubeUrl(String? url) {
    final host = _hostOf(url);
    return isYouTubeHost(host);
  }

  /// True if the active page is YouTube.
  static bool isYouTubePage(String? pageUrl) => isYouTubeUrl(pageUrl);

  /// Pure match: would this capture hit the YouTube rule (ignoring channel)?
  static bool matchesYouTubeRestriction({
    required String mediaUrl,
    String? sourcePageUrl,
    String? referer,
    String? origin,
    Map<String, String>? headers,
  }) {
    final headerReferer = _headerValue(headers, 'referer') ?? referer;
    final headerOrigin = _headerValue(headers, 'origin') ?? origin;

    return isYouTubeUrl(mediaUrl) ||
        isYouTubeUrl(sourcePageUrl) ||
        isYouTubeUrl(headerReferer) ||
        isYouTubeUrl(headerOrigin);
  }

  /// Full evaluation for a media capture or download attempt.
  ///
  /// On **GitHub** builds: always allowed (no Play policy gate).
  /// On **Play** builds: blocks when media URL, page, Referer, or Origin is
  /// YouTube / YouTube CDN.
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

    if (matchesYouTubeRestriction(
      mediaUrl: mediaUrl,
      sourcePageUrl: sourcePageUrl,
      referer: referer,
      origin: origin,
      headers: headers,
    )) {
      return RestrictedMediaDecision.blocked(
        reason: RestrictedMediaReason.youtube,
        message: userMessageYouTube,
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

enum RestrictedMediaReason {
  youtube,
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
