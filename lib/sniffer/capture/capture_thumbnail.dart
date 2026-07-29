import 'package:flutter/material.dart';

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
@visibleForTesting
String? posterUrlFor(SniffedMedia item) {
  final candidate = item.type == MediaType.image
      ? (item.thumbnailUrl ?? item.url)
      : item.thumbnailUrl;
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
/// Paints the page's own artwork when the sniffer harvested one, and the
/// accent-tinted type icon when it did not — the slot keeps the same footprint
/// either way so rows stay aligned in a mixed list. The duration (or `LIVE`)
/// badge is burned into the corner in both states.
class CaptureThumbnail extends StatelessWidget {
  const CaptureThumbnail({
    super.key,
    required this.item,
    required this.isHls,
    this.width = 84,
    this.onTap,
  });

  final SniffedMedia item;
  final bool isHls;
  final double width;

  /// Tapping the poster previews the media. Null renders it non-interactive
  /// (documents, archives, torrents — nothing to play).
  final VoidCallback? onTap;

  double get _height => width * 9 / 16;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final accent = mediaAccentFor(ac, item, isHls: isHls);
    final poster = posterUrlFor(item);
    final badge = _badgeLabel();

    return SizedBox(
      width: width,
      height: _height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Fallback(item: item, accent: accent),
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
