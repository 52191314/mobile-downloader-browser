import '../../downloader/downloader.dart';
import '../../downloader/models.dart';

// --- Download speed / size / name formatters ---
// Shared across queue_page.dart and download_task_row.dart.

/// Formats a download speed in bytes per second to a human-readable label.
///   * ≤ 0 → '0 KB/s'
///   * < 1 MB/s → 'X.X KB/s'
///   * ≥ 1 MB/s → 'X.X MB/s'  (or 'X.XX MB/s' in the queue_page variant — unified here as 1 decimal)
String formatSpeed(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 KB/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

/// Formats a byte count to a human-readable label.
///   * < 1024 B → 'X B'
///   * < 1 MB   → 'X.X KB'
///   * < 1 GB   → 'X.X MB'
///   * ≥ 1 GB   → 'X.XX GB'
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Formats a downloaded/total pair into a label like '12.3 MB / 45.6 MB'.
/// When [total] ≤ 0, returns 'X.X MB downloaded'.
String formatBytesPair(int downloaded, int total) {
  if (total <= 0) return '${formatBytes(downloaded)} downloaded';
  return '${formatBytes(downloaded)} / ${formatBytes(total)}';
}

/// Converts [DownloadState] to a short human-readable label.
String stateLabel(DownloadState state) {
  return switch (state) {
    DownloadState.completed => 'Completed',
    DownloadState.failed => 'Failed',
    DownloadState.paused => 'Paused',
    DownloadState.scheduled => 'Scheduled',
    DownloadState.downloading => 'Downloading',
    DownloadState.idle => 'Waiting',
    DownloadState.merging => 'Merging',
  };
}

/// Extracts a display-friendly filename from a [DownloadTask]'s save path.
/// For HLS/DASH tasks without a recognisable file extension, appends `.mp4`.
/// Returns the filename with the extension always visible.
///
/// Mirrors the logic previously inlined in both queue_page.dart and
/// download_task_row.dart.
String taskDisplayName(DownloadTask task) {
  final normalized = task.savePath.replaceAll('\\', '/');
  final filename = normalized.split('/').last;

  // Check if filename already has a recognizable extension
  final dotIdx = filename.lastIndexOf('.');
  if (dotIdx != -1 && dotIdx > 0 && filename.length - dotIdx <= 6) {
    return filename;
  }

  // Try to get extension from task.contentType or task.url
  String? ext;
  if (task.contentType != null && task.contentType!.isNotEmpty) {
    final cleanMime = task.contentType!.split(';').first.trim().toLowerCase();
    if (cleanMime == 'application/vnd.apple.mpegurl' || cleanMime == 'application/x-mpegurl') {
      ext = '.mp4';
    } else if (cleanMime == 'application/dash+xml') {
      ext = '.mp4';
    } else {
      ext = _extensionForMime(cleanMime);
    }
  }

  if (ext == null || ext.isEmpty) {
    final parsedUri = Uri.tryParse(task.url);
    if (parsedUri != null && parsedUri.pathSegments.isNotEmpty) {
      final lastSeg = parsedUri.pathSegments.last;
      final lastDot = lastSeg.lastIndexOf('.');
      if (lastDot != -1 && lastDot > 0 && lastSeg.length - lastDot <= 6) {
        final urlExt = lastSeg.substring(lastDot).toLowerCase();
        if (urlExt == '.m3u8' || urlExt == '.mpd') {
          ext = '.mp4';
        } else {
          ext = urlExt;
        }
      }
    }
  }

  if (ext == null || ext.isEmpty) {
    if (task.url.toLowerCase().contains('.m3u8')) {
      ext = '.mp4';
    } else if (task.url.toLowerCase().contains('.mpd')) {
      ext = '.mp4';
    } else if (task.url.startsWith('magnet:')) {
      ext = '.torrent';
    }
  }

  if (ext != null && ext.isNotEmpty) {
    return '$filename$ext';
  }
  return filename;
}

/// Helper used by [taskDisplayName] to resolve a few well-known MIME types
/// to file extensions.  Kept private; the authoritative mapper is
/// [PublicDownloadsService.extensionForMime].
String? _extensionForMime(String mime) {
  // Minimal mapping for the display-name use case; the full mapper lives
  // in PublicDownloadsService.
  const map = <String, String>{
    'video/mp4': '.mp4',
    'video/webm': '.webm',
    'video/x-matroska': '.mkv',
    'audio/mpeg': '.mp3',
    'audio/mp4': '.m4a',
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'application/pdf': '.pdf',
    'application/zip': '.zip',
  };
  return map[mime];
}

const _sizeKbPresets = [0, 100, 500, 1024, 5120, 10240, 51200, 102400];
const _durationPresets = [0, 10, 30, 60, 120, 300, 600, 900];

String formatSizeKb(int kb) {
  if (kb == 0) return 'Off';
  if (kb < 1024) return '${kb}KB';
  if (kb == 1024) return '1MB';
  return '${(kb / 1024).toStringAsFixed(0)}MB';
}

int sizeKbToSliderIndex(int kb) {
  final idx = _sizeKbPresets.indexOf(kb);
  return idx < 0 ? 0 : idx;
}

int sliderIndexToSizeKb(int index) {
  if (index < 0 || index >= _sizeKbPresets.length) return 0;
  return _sizeKbPresets[index];
}

String formatDurationSeconds(int seconds) {
  if (seconds == 0) return 'Off';
  if (seconds < 60) return '${seconds}s';
  if (seconds == 60) return '1min';
  return '${(seconds / 60).toStringAsFixed(0)}min';
}

int durationSecondsToSliderIndex(int seconds) {
  final idx = _durationPresets.indexOf(seconds);
  return idx < 0 ? 0 : idx;
}

int sliderIndexToDurationSeconds(int index) {
  if (index < 0 || index >= _durationPresets.length) return 0;
  return _durationPresets[index];
}

// Stall-detection speed threshold presets (0 = Off, values in KB/s)
const _speedKbpsPresets = [0, 50, 100, 200, 500, 1000, 2000, 5000];

int speedKbpsToSliderIndex(int kbps) {
  final idx = _speedKbpsPresets.indexOf(kbps);
  return idx < 0 ? 0 : idx;
}

int sliderIndexToSpeedKbps(int index) {
  if (index < 0 || index >= _speedKbpsPresets.length) return 0;
  return _speedKbpsPresets[index];
}

/// ETA smoothing helper. Returns a coarse-bucket estimate like "~30s",
/// "~2m", "~5m", "~15m", "~1h", "~2h", or null when ETA is not meaningful.
///
/// [speedEmaBytesPerSec] should be an EMA-smoothed speed to avoid thrash.
String? formatEta({
  required int downloadedBytes,
  required int totalBytes,
  required double speedEmaBytesPerSec,
}) {
  if (totalBytes <= 0 || speedEmaBytesPerSec <= 8192) return null; // min 8 KB/s
  final remaining = totalBytes - downloadedBytes;
  if (remaining <= 0) return null;
  final etaSeconds = (remaining / speedEmaBytesPerSec).round();
  if (etaSeconds < 45) return '~30s';
  if (etaSeconds < 150) return '~2m';
  if (etaSeconds < 450) return '~5m';
  if (etaSeconds < 1050) return '~15m';
  if (etaSeconds < 4500) return '~${(etaSeconds / 3600 * 2).round() / 2}h';
  if (etaSeconds < 9000) return '~${(etaSeconds / 3600).round()}h';
  return '~2h';
}
