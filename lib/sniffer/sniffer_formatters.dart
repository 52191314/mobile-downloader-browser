import 'package:flutter/material.dart';

import '../settings/download_settings.dart';
import 'models/sniffed_media.dart';

/// Human-readable byte size (e.g. `1.2 MB`). Returns `Unknown` when ≤ 0.
String formatByteSize(int bytes, {bool isEstimated = false}) {
  if (bytes <= 0) return 'Unknown';
  const suffixes = ['B', 'KB', 'MB', 'GB'];
  var i = 0;
  double size = bytes.toDouble();
  while (size >= 1024 && i < suffixes.length - 1) {
    size /= 1024;
    i++;
  }
  final formatted = '${size.toStringAsFixed(1)} ${suffixes[i]}';
  return isEstimated ? '$formatted (est.)' : formatted;
}

/// Compact size label for list rows. Empty string when unknown.
String sizeLabel(int? bytes, {bool isEstimated = false}) {
  if (bytes == null || bytes < 0) return '';
  final suffix = isEstimated ? ' (est.)' : '';
  if (bytes < 1024) return '$bytes B$suffix';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB$suffix';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB$suffix';
}

/// `H:MM:SS` or `MM:SS`. Empty when null/zero.
String durationLabel(Duration? duration) {
  if (duration == null || duration == Duration.zero) return '';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

/// Host from URL, or `'Page'` / raw string fallback.
String titleForUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && uri.host.isNotEmpty) return uri.host;
  return url.isEmpty ? 'Page' : url;
}

/// Prefer non-empty [title]; otherwise [titleForUrl].
String cleanTitle(String? title, String? url) {
  final trimmed = title?.trim();
  if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  return titleForUrl(url ?? '');
}

/// Sum of known content lengths (missing treated as 0).
int totalKnownBytes(List<SniffedMedia> media) {
  return media.fold<int>(
    0,
    (total, item) => total + (item.contentLengthBytes ?? 0),
  );
}

/// Icon for a sniffed media type.
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

/// Multi-line metadata string for catch-sheet / info display.
String metadataLabel(
  SniffedMedia item, {
  required SniffedMediaDisplayMode displayMode,
}) {
  final parts = <String>[];
  switch (displayMode) {
    case SniffedMediaDisplayMode.size:
      parts.add(
        sizeLabel(item.contentLengthBytes, isEstimated: item.isSizeEstimated),
      );
      break;
    case SniffedMediaDisplayMode.duration:
      parts.add(durationLabel(item.duration));
      break;
    case SniffedMediaDisplayMode.both:
      parts.add(
        sizeLabel(item.contentLengthBytes, isEstimated: item.isSizeEstimated),
      );
      parts.add(durationLabel(item.duration));
      break;
  }
  if (item.contentType != null) parts.add(item.contentType!);
  if (item.sourcePageUrl != null && item.sourcePageUrl!.isNotEmpty) {
    parts.add(item.sourcePageUrl!);
  }
  parts.add(item.url);
  return parts.where((part) => part.isNotEmpty).join(' | ');
}
