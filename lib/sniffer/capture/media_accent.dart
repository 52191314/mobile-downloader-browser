import 'package:flutter/material.dart';

import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_tokens.dart';

/// True when the media looks like an HLS stream (URL or content-type).
bool isHlsMedia(SniffedMedia m) {
  return m.url.contains('.m3u8') ||
      (m.contentType?.contains('m3u8') ?? false) ||
      (m.contentType?.contains('apple/mpegurl') ?? false);
}

/// Theme-aware accent color for a sniffed media item.
///
/// HLS always wins over [MediaType]. Torrent uses the dedicated
/// [AColors.mediaTorrent] token (deep teal — not amber, not frost).
Color mediaAccentFor(AColors ac, SniffedMedia item, {required bool isHls}) {
  if (isHls) return ac.mediaHls;
  return switch (item.type) {
    MediaType.video => ac.mediaVideo,
    MediaType.audio => ac.mediaAudio,
    MediaType.image => ac.mediaImage,
    MediaType.torrent => ac.mediaTorrent,
    _ => ac.mediaOther,
  };
}

/// Icon for a [MediaType] used on Capture rows and type wells.
IconData mediaTypeIcon(MediaType type) {
  return switch (type) {
    MediaType.video => Icons.movie,
    MediaType.audio => Icons.audiotrack,
    MediaType.image => Icons.image,
    MediaType.document => Icons.description,
    MediaType.archive => Icons.archive,
    MediaType.torrent => Icons.hub,
    MediaType.subtitle => Icons.subtitles,
    MediaType.executable => Icons.insert_drive_file,
    MediaType.playlist => Icons.queue_music,
  };
}

/// Short human-readable byte label. When [estimated] is true, prefixes `~`.
String formatCaptureBytes(int? bytes, {bool estimated = false}) {
  if (bytes == null || bytes <= 0) return '';
  final String label;
  if (bytes < 1024) {
    label = '$bytes B';
  } else if (bytes < 1024 * 1024) {
    label = '${(bytes / 1024).toStringAsFixed(0)} KB';
  } else if (bytes < 1024 * 1024 * 1024) {
    label = '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  } else {
    label = '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  return estimated ? '~$label' : label;
}

/// Formats duration as `M:SS` or `H:MM:SS`.
String formatCaptureDuration(Duration d) {
  final hrs = d.inHours;
  final mins = d.inMinutes % 60;
  final secs = d.inSeconds % 60;
  if (hrs > 0) {
    return '$hrs:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
  return '$mins:${secs.toString().padLeft(2, '0')}';
}
