import 'package:flutter/foundation.dart';

/// One selectable rendition of a stream (HLS variant, progressive alternate).
@immutable
class PlaybackVariant {
  const PlaybackVariant({
    required this.url,
    required this.label,
    this.height,
    this.bandwidth,
    this.headers,
  });

  final String url;
  final String label;
  final int? height;
  final int? bandwidth;

  /// Per-variant headers. Null means "reuse the source's headers" — correct
  /// for same-CDN renditions, wrong when a variant lives on another host, so
  /// callers that know better should supply them.
  final Map<String, String>? headers;
}

/// Everything an engine needs to play something. Deliberately inert: no
/// controllers, no widgets, nothing platform-specific, so it can be built in a
/// test or logged verbatim.
@immutable
class PlaybackSource {
  const PlaybackSource({
    required this.url,
    this.title = '',
    this.headers = const {},
    this.variants = const [],
    this.startAt = Duration.zero,
    this.sourcePageUrl,
  });

  final String url;
  final String title;

  /// Request headers for the media fetch — User-Agent, Referer, Cookie.
  /// The single most common cause of a stream that "loads" and then plays
  /// nothing is these being absent or stale.
  final Map<String, String> headers;

  final List<PlaybackVariant> variants;
  final Duration startAt;
  final String? sourcePageUrl;

  bool get hasVariants => variants.length >= 2;

  /// Header names only — safe to log. Values carry session cookies and must
  /// never reach a log sink or a bug report.
  List<String> get headerNames => headers.keys.toList(growable: false);

  PlaybackSource copyWith({
    String? url,
    String? title,
    Map<String, String>? headers,
    List<PlaybackVariant>? variants,
    Duration? startAt,
    String? sourcePageUrl,
  }) {
    return PlaybackSource(
      url: url ?? this.url,
      title: title ?? this.title,
      headers: headers ?? this.headers,
      variants: variants ?? this.variants,
      startAt: startAt ?? this.startAt,
      sourcePageUrl: sourcePageUrl ?? this.sourcePageUrl,
    );
  }
}
