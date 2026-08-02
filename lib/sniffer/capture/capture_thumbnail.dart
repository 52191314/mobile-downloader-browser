import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:aurora_downloader/sniffer/capture/capture_frame_cache.dart';
import 'package:aurora_downloader/sniffer/capture/media_accent.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Request headers a poster fetch is allowed to inherit from the capture.
///
/// The sniffed header set is the full browsing context (cookies already
/// stripped by [sanitizeSniffedMediaHeaders], but still carrying `Range`,
/// `Sec-Fetch-*`, `Accept: video/*` and friends). Replaying that at an image
/// host gets 406s and partial responses, so only the two headers hotlink
/// protection actually checks are forwarded.
const _posterHeaderAllowlist = {'referer', 'user-agent'};

Map<String, String> _posterHeaders(SniffedMedia item) {
  final out = <String, String>{};
  for (final entry in item.headers.entries) {
    if (_posterHeaderAllowlist.contains(entry.key.toLowerCase())) {
      out[entry.key] = entry.value;
    }
  }
  final page = item.sourcePageUrl?.trim();
  if (page != null && page.isNotEmpty && !out.keys.any((k) => k.toLowerCase() == 'referer')) {
    out['Referer'] = page;
  }
  return out;
}

/// The poster URL to paint for [item], or null when there is nothing to show.
///
/// Images are their own thumbnail; everything else needs a poster harvested
/// from the page. `blob:` and `data:` never render here — the bridge guard
/// rejects them upstream, and this is a second line of defence.
///
/// [pagePoster] is the page's `og:image`, and is only consulted when the item
/// carries no poster of its own. The caller decides whether page artwork is
/// honest for this page at all; by the time it arrives here it is trusted.
@visibleForTesting
String? posterUrlFor(SniffedMedia item, {String? pagePoster}) {
  final own = item.type == MediaType.image
      ? (item.thumbnailUrl ?? item.url)
      : item.thumbnailUrl;
  final candidate = (own != null && own.trim().isNotEmpty) ? own : pagePoster;
  final trimmed = candidate?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return trimmed;
}

/// 16:9 poster well for a capture row.
///
/// Four sources, in descending order of how specific they are to this file:
///
/// 1. the element's own `<video poster>` — curated by the site, and free;
/// 2. a frame decoded out of the stream itself, via [CaptureFrameCache];
/// 3. the page's `og:image`, when the sheet judged it representative;
/// 4. the accent-tinted type icon.
///
/// The decode is skipped entirely when (1) is available, since a still the site
/// chose is at least as good as one picked a tenth of the way in and costs no
/// network. The slot keeps the same footprint in all four states so rows stay
/// aligned in a mixed list, and the duration (or `LIVE`) badge is burned into
/// the corner regardless.
class CaptureThumbnail extends StatefulWidget {
  const CaptureThumbnail({
    super.key,
    required this.item,
    required this.isHls,
    this.width = 84,
    this.onTap,
    this.pagePoster,
    this.frameCache,
  });

  final SniffedMedia item;
  final bool isHls;
  final double width;

  /// The page's `og:image`, or null when the caller judged it an unfair
  /// stand-in for this page. Used only when [item] has no poster of its own.
  final String? pagePoster;

  /// Tapping the poster previews the media. Null renders it non-interactive
  /// (documents, archives, torrents — nothing to play).
  final VoidCallback? onTap;

  /// Overridable so widget tests can supply frames without a platform channel.
  @visibleForTesting
  final CaptureFrameCache? frameCache;

  @override
  State<CaptureThumbnail> createState() => _CaptureThumbnailState();
}

class _CaptureThumbnailState extends State<CaptureThumbnail> {
  Uint8List? _frame;

  CaptureFrameCache get _cache =>
      widget.frameCache ?? CaptureFrameCache.instance;

  double get _height => widget.width * 9 / 16;

  /// The site's own still for this element, ignoring page-level artwork.
  String? get _elementPoster => posterUrlFor(widget.item);

  @override
  void initState() {
    super.initState();
    _resolveFrame();
  }

  @override
  void didUpdateWidget(CaptureThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rows are recycled as the list scrolls, so one State can be handed a
    // different capture. Without this the previous row's frame would linger.
    if (oldWidget.item.url != widget.item.url) {
      _frame = null;
      _resolveFrame();
    }
  }

  void _resolveFrame() {
    // A curated poster already beats anything a decode would produce.
    if (_elementPoster != null) return;

    final item = widget.item;
    final ready = _cache.cached(item.url);
    if (ready != null) {
      _frame = ready;
      return;
    }
    if (_cache.hasFailed(item.url) || !CaptureFrameCache.canDecode(item)) return;

    final requestedUrl = item.url;
    _cache.frameFor(item).then((bytes) {
      if (!mounted || bytes == null) return;
      // The row may have been recycled onto a different capture while the
      // decode was in flight.
      if (widget.item.url != requestedUrl) return;
      setState(() => _frame = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final width = widget.width;
    final onTap = widget.onTap;

    final ac = context.ac;
    final accent = mediaAccentFor(ac, item, isHls: widget.isHls);
    final badge = _badgeLabel();

    // A decoded frame is this file's own content, so it outranks page artwork;
    // the element's own poster outranks both.
    final elementPoster = _elementPoster;
    final frame = elementPoster == null ? _frame : null;
    final poster = elementPoster ??
        (frame != null
            ? null
            : posterUrlFor(item, pagePoster: widget.pagePoster));

    return SizedBox(
      width: width,
      height: _height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Fallback(item: item, accent: accent),
            if (frame != null)
              Image.memory(
                frame,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // Already decoded to ~maxWidth natively; nothing more to cap.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            if (poster != null)
              Image.network(
                poster,
                fit: BoxFit.cover,
                headers: _posterHeaders(item),
                // Posters are decorative and often far larger than the slot;
                // decode at ~2x the painted size instead of full resolution so
                // a list of them cannot blow up the image cache.
                cacheWidth: (width * 2).round(),
                gaplessPlayback: true,
                // A dead poster is not an error worth surfacing — the type-icon
                // fallback underneath is already painted.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                frameBuilder: (_, child, frame, wasSync) {
                  if (wasSync || frame != null) return child;
                  return const SizedBox.shrink();
                },
              ),
            if (onTap != null)
              Center(
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 15,
                    color: Colors.white,
                  ),
                ),
              ),
            if (badge != null)
              Positioned(
                right: 3,
                bottom: 3,
                child: _Badge(
                  label: badge.$1,
                  color: badge.$2 ? ac.statusError : Colors.white,
                ),
              ),
            if (onTap != null)
              Material(
                color: Colors.transparent,
                child: InkWell(onTap: onTap),
              ),
          ],
        ),
      ),
    );
  }

  /// `(label, isLive)` for the corner badge, or null when there is nothing
  /// meaningful to stamp.
  (String, bool)? _badgeLabel() {
    final item = widget.item;
    if (item.isLive == true) return ('LIVE', true);
    final d = item.duration;
    if (d != null && d.inSeconds > 0) return (formatCaptureDuration(d), false);
    return null;
  }
}

/// Painted under every poster so a slow or broken image never shows a hole.
class _Fallback extends StatelessWidget {
  const _Fallback({required this.item, required this.accent});

  final SniffedMedia item;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.22),
            accent.withValues(alpha: 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(mediaTypeIcon(item.type), color: accent, size: 20),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          fontFamily: 'JetBrains Mono',
          height: 1.2,
        ),
      ),
    );
  }
}
