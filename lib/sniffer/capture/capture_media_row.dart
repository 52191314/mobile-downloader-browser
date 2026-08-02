import 'package:flutter/material.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/capture/capture_thumbnail.dart';
import 'package:aurora_downloader/sniffer/capture/media_accent.dart';
import 'package:aurora_downloader/sniffer/media_capture_analyzer.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

/// One capture-group row: poster, title, metadata chips, selection, actions.
///
/// Download is not per-row — use checkbox multi-select + header Download.
/// Preview lives on the poster itself (the play affordance is painted there),
/// so the trailing cluster is a single Details button at every width and no
/// longer collapses into an overflow menu.
class CaptureMediaRow extends StatelessWidget {
  const CaptureMediaRow({
    super.key,
    required this.index,
    required this.group,
    required this.selected,
    required this.onSelectedChanged,
    required this.onPreview,
    required this.onInfo,
    this.displayMode = SniffedMediaDisplayMode.both,
    this.pagePoster,
  });

  final int index;
  final CaptureGroup group;
  final bool selected;
  final ValueChanged<bool> onSelectedChanged;
  final VoidCallback? onPreview;
  final VoidCallback onInfo;

  /// Page artwork to fall back on when this row's media has no poster of its
  /// own. Null when the sheet judged the page's `og:image` unrepresentative.
  final String? pagePoster;

  /// Controls size/duration richness in the metadata (PR5 / KD25).
  final SniffedMediaDisplayMode displayMode;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isLight = context.isLight;
    final item = group.primary.media;
    final hls = isHlsMedia(item);
    final recommended = group.isRecommended;
    final canPreview = onPreview != null &&
        (item.type == MediaType.video ||
            item.type == MediaType.audio ||
            item.type == MediaType.image);

    final chips = buildCaptureChips(
      item,
      group,
      hls: hls,
      displayMode: displayMode,
    );
    final subtitle = buildCaptureSubtitle(
      item,
      group,
      hls: hls,
      displayMode: displayMode,
      chips: chips,
    );

    final borderColor = selected ? ac.accentFrost : ac.borderHairline;
    final borderWidth = selected ? 2.0 : 1.0;
    final glowAlpha = isLight ? 0.12 : 0.20;
    final glowBlur = isLight ? 6.0 : 8.0;
    final glow = selected
        ? [
            BoxShadow(
              color: ac.accentFrost.withValues(alpha: glowAlpha),
              blurRadius: glowBlur,
            ),
          ]
        : null;

    final BoxDecoration decoration;
    if (isLight) {
      decoration = BoxDecoration(
        color: ac.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: glow,
      );
    } else {
      decoration = BoxDecoration(
        gradient: LinearGradient(
          colors: [ac.gradientMid, ac.surfacePanel],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: glow,
      );
    }

    return Padding(
      key: Key('sniffed_item_$index'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        decoration: decoration,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onInfo,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 4, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: Checkbox(
                        value: selected,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        fillColor: WidgetStateProperty.resolveWith((s) {
                          if (s.contains(WidgetState.selected)) {
                            return ac.accentFrost;
                          }
                          return null;
                        }),
                        checkColor: context.auroraColorScheme.onPrimary,
                        onChanged: (v) {
                          if (v != null) onSelectedChanged(v);
                        },
                      ),
                    ),
                    const SizedBox(width: 2),
                    CaptureThumbnail(
                      key: Key('capture_thumb_$index'),
                      item: item,
                      isHls: hls,
                      onTap: canPreview ? onPreview : null,
                      pagePoster: pagePoster,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.name.isNotEmpty
                                      ? item.name
                                      : 'Unknown media',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: ac.textPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                  ),
                                ),
                              ),
                              if (recommended) ...[
                                const SizedBox(width: 4),
                                const _BestPill(),
                              ],
                            ],
                          ),
                          if (chips.isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                for (final chip in chips) _MetaChip(chip: chip),
                              ],
                            ),
                          ],
                          if (subtitle.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ac.textTertiary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _ActionIcon(
                      key: Key('info_item_$index'),
                      icon: Icons.info_outline,
                      color: ac.textSecondary,
                      tooltip: 'Details',
                      onPressed: onInfo,
                    ),
                    // Preview moved onto the poster; keep the key addressable
                    // so existing finders and the narrow-width path still
                    // resolve to a real, tappable widget.
                    Offstage(
                      child: SizedBox(
                        width: 0,
                        height: 0,
                        child: IconButton(
                          key: Key('preview_item_$index'),
                          icon: const Icon(Icons.play_circle_outline),
                          onPressed: canPreview ? onPreview : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Visual weight of a metadata chip.
enum CaptureChipTone {
  /// Resolution / quality — carries the media accent colour.
  accent,

  /// Ordinary technical fact (codec, frame rate, bitrate).
  neutral,

  /// Byte counts — rendered in the mono face like every other figure.
  figure,

  /// Live stream marker.
  live,
}

/// One metadata chip on a capture row.
@immutable
class CaptureChip {
  const CaptureChip(this.label, this.tone);

  final String label;
  final CaptureChipTone tone;

  @override
  bool operator ==(Object other) =>
      other is CaptureChip && other.label == label && other.tone == tone;

  @override
  int get hashCode => Object.hash(label, tone);

  @override
  String toString() => 'CaptureChip($label, ${tone.name})';
}

/// Chips for the top metadata line, most important first.
///
/// The sniffer resolves far more than a row can show — resolution, both codecs,
/// frame rate, bandwidth, sample rate, channel count, live flag. This picks the
/// highest-signal facts for the media at hand (video leads with picture specs,
/// audio with sample rate / channels) and caps the list so a narrow screen
/// never wraps into a wall of pills. Everything omitted here is still one tap
/// away in Details.
///
/// [displayMode] gates the size chip only, matching the existing setting.
@visibleForTesting
List<CaptureChip> buildCaptureChips(
  SniffedMedia item,
  CaptureGroup group, {
  required bool hls,
  SniffedMediaDisplayMode displayMode = SniffedMediaDisplayMode.both,
  int max = 4,
}) {
  final chips = <CaptureChip>[];
  final includeSize = displayMode == SniffedMediaDisplayMode.size ||
      displayMode == SniffedMediaDisplayMode.both;

  if (item.isLive == true) {
    chips.add(const CaptureChip('LIVE', CaptureChipTone.live));
  }

  final quality = group.primary.qualityLabel;
  if (quality != null && quality.isNotEmpty && quality != 'HLS') {
    chips.add(CaptureChip(quality, CaptureChipTone.accent));
  } else if (item.height != null && item.height! > 0) {
    chips.add(CaptureChip('${item.height}p', CaptureChipTone.accent));
  }

  if (includeSize) {
    final size = formatCaptureBytes(
      item.contentLengthBytes,
      estimated: item.isSizeEstimated,
    );
    if (size.isNotEmpty) {
      chips.add(CaptureChip(size, CaptureChipTone.figure));
    }
  }

  if (item.type == MediaType.audio) {
    final rate = item.sampleRate;
    if (rate != null && rate > 0) {
      final khz = (rate / 1000).toStringAsFixed(rate % 1000 == 0 ? 0 : 1);
      chips.add(CaptureChip('$khz kHz', CaptureChipTone.neutral));
    }
    final channels = item.channels;
    if (channels != null && channels > 0) {
      chips.add(CaptureChip(_channelLabel(channels), CaptureChipTone.neutral));
    }
    final audioCodec = prettyCodecLabel(item.audioCodec);
    if (audioCodec != null) {
      chips.add(CaptureChip(audioCodec, CaptureChipTone.neutral));
    }
  } else {
    final videoCodec = prettyCodecLabel(item.videoCodec);
    if (videoCodec != null) {
      chips.add(CaptureChip(videoCodec, CaptureChipTone.neutral));
    }
    final fps = item.frameRate;
    // Below ~5 is not a real playback rate — it is what a failed probe leaves
    // behind. Rows whose enrichment did not complete were rendering "1fps"
    // next to a filename that said 60fps, which reads as the app being wrong
    // rather than the data being missing. Say nothing instead.
    if (fps != null && fps >= 5) {
      final rounded = fps.round();
      // 29.97 / 59.94 / 23.976 are the common broadcast rates — keep them as
      // they are rather than rounding to a whole number and claiming precision
      // the manifest never gave us. The tolerance has to stay under 0.03 or
      // 29.97 collapses into "30fps".
      final label = (fps - rounded).abs() < 0.01
          ? '${rounded}fps'
          : '${fps.toStringAsFixed(2)}fps';
      chips.add(CaptureChip(label, CaptureChipTone.neutral));
    }
    final bandwidth = item.bandwidth;
    if (bandwidth != null && bandwidth > 0) {
      chips.add(
        CaptureChip(formatCaptureBitrate(bandwidth), CaptureChipTone.figure),
      );
    }
  }

  if (chips.length <= max) return chips;
  return chips.sublist(0, max);
}

String _channelLabel(int channels) {
  return switch (channels) {
    1 => 'Mono',
    2 => 'Stereo',
    6 => '5.1',
    8 => '7.1',
    _ => '${channels}ch',
  };
}

/// Maps a codec identifier from a manifest or container onto the name a person
/// would recognise. Returns null when there is nothing worth showing.
///
/// HLS manifests report RFC 6381 strings (`avc1.640028`, `mp4a.40.2`); probes
/// report short names (`h264`, `opus`). Unknown values pass through uppercased
/// rather than being dropped — an unfamiliar codec is still information.
@visibleForTesting
String? prettyCodecLabel(String? raw) {
  final value = raw?.trim().toLowerCase();
  if (value == null || value.isEmpty) return null;
  final base = value.split('.').first;

  const known = <String, String>{
    'avc1': 'H.264',
    'avc3': 'H.264',
    'h264': 'H.264',
    'x264': 'H.264',
    'hvc1': 'H.265',
    'hev1': 'H.265',
    'h265': 'H.265',
    'hevc': 'H.265',
    'av01': 'AV1',
    'av1': 'AV1',
    'vp08': 'VP8',
    'vp8': 'VP8',
    'vp09': 'VP9',
    'vp9': 'VP9',
    'mp4a': 'AAC',
    'aac': 'AAC',
    'opus': 'Opus',
    'vorbis': 'Vorbis',
    'mp3': 'MP3',
    'flac': 'FLAC',
    'alac': 'ALAC',
    'ac-3': 'AC-3',
    'ac3': 'AC-3',
    'ec-3': 'E-AC-3',
    'eac3': 'E-AC-3',
    'dts': 'DTS',
  };

  final mapped = known[base];
  if (mapped != null) return mapped;
  if (base.length > 12) return null;
  return base.toUpperCase();
}

/// Bitrate as `N.N Mbps` / `N kbps` from bits per second.
@visibleForTesting
String formatCaptureBitrate(int bitsPerSecond) {
  if (bitsPerSecond >= 1000000) {
    return '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbps';
  }
  return '${(bitsPerSecond / 1000).round()} kbps';
}

/// Secondary line under the chips: container · duration · variants · staleness.
///
/// Duration is normally burned into the poster badge, so it only appears here
/// when there is no badge to carry it (a live stream shows `LIVE` instead).
/// Size, resolution, codecs and bitrate all live in [buildCaptureChips] now.
///
/// Pass the row's [chips] so the container is dropped when a chip already says
/// it — see [_containerIsRedundant].
@visibleForTesting
String buildCaptureSubtitle(
  SniffedMedia item,
  CaptureGroup group, {
  required bool hls,
  SniffedMediaDisplayMode displayMode = SniffedMediaDisplayMode.both,
  Iterable<CaptureChip> chips = const [],
}) {
  final parts = <String>[];
  final includeDuration = displayMode == SniffedMediaDisplayMode.duration ||
      displayMode == SniffedMediaDisplayMode.both;

  if (hls) {
    parts.add('HLS');
  } else {
    final container = item.containerFormat?.trim();
    final String? label;
    if (container != null && container.isNotEmpty) {
      label = container.toUpperCase();
    } else if (item.contentType != null && item.contentType!.isNotEmpty) {
      label = item.contentType!.split(';').first.trim();
    } else {
      label = null;
    }
    if (label != null && !_containerIsRedundant(label, chips)) {
      parts.add(label);
    }
  }

  // The poster badge already shows the duration unless a LIVE badge took the
  // slot — only then does it need repeating here.
  if (includeDuration &&
      item.isLive == true &&
      item.duration != null &&
      item.duration!.inSeconds > 0) {
    parts.add(formatCaptureDuration(item.duration!));
  }

  if (group.variantCount > 1) {
    parts.add('${group.variantCount} variants');
  }

  if (item.isCacheRestored) {
    parts.add('from last session');
  }

  return parts.join(' · ');
}

/// True when [container] restates a fact one of [chips] already carries.
///
/// `qualityLabel` falls back to the content type when a capture has no
/// resolution resolved yet, so an unenriched MP4 rendered a `video/mp4` chip
/// *and* an `MP4` subtitle — the same fact twice, on every row. Comparison is
/// on the subtype so `video/mp4` and `MP4` collapse onto each other.
bool _containerIsRedundant(String container, Iterable<CaptureChip> chips) {
  final needle = container.toLowerCase().split('/').last;
  for (final chip in chips) {
    if (chip.label.toLowerCase().split('/').last == needle) return true;
  }
  return false;
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.chip});

  final CaptureChip chip;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final color = switch (chip.tone) {
      CaptureChipTone.accent => ac.accentFrost,
      CaptureChipTone.live => ac.statusError,
      CaptureChipTone.figure => ac.textSecondary,
      CaptureChipTone.neutral => ac.textSecondary,
    };
    final emphatic =
        chip.tone == CaptureChipTone.accent || chip.tone == CaptureChipTone.live;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: emphatic ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: color.withValues(alpha: emphatic ? 0.38 : 0.20),
        ),
      ),
      child: Text(
        chip.label,
        maxLines: 1,
        style: TextStyle(
          color: color,
          fontSize: 10,
          height: 1.1,
          fontWeight: emphatic ? FontWeight.w700 : FontWeight.w600,
          fontFamily:
              chip.tone == CaptureChipTone.figure ? 'JetBrains Mono' : null,
        ),
      ),
    );
  }
}

class _BestPill extends StatelessWidget {
  const _BestPill();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: ac.accentAmber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 10, color: ac.accentAmber),
          const SizedBox(width: 2),
          Text(
            'Best',
            style: TextStyle(
              color: ac.accentAmber,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  static const double size = 32.0;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: Size(size, size),
        maximumSize: Size(size, size),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      icon: Icon(icon, size: 18),
      color: color,
      onPressed: onPressed,
    );
  }
}
