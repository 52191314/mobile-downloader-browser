enum DownloadState { scheduled, idle, downloading, paused, completed, failed, merging }

/// How to handle a download whose URL or filename already exists in the queue.
enum DuplicateChoice {
  /// Skip this item (do nothing).
  skip,
  /// Replace the existing task — delete it from queue, add the new one.
  replace,
  /// Create a new separate task alongside the existing one.
  createNew,
}

/// Batch duplicate policy: remembers a user's choice to apply to all remaining items.
class DuplicatePolicy {
  DuplicateChoice choice;
  bool applyToAll;
  DuplicatePolicy({required this.choice, this.applyToAll = false});
}

/// Classifies the reason a download failed.
/// Used for programmatic error handling (different retry strategies,
/// UI icons, actionable suggestions) instead of string-matching.
enum DownloadFailure {
  // ── Network ──
  /// Device has no network connectivity.
  noInternet,
  /// Could not resolve hostname (DNS failure).
  dnsLookupFailed,
  /// Server refused the TCP connection.
  connectionRefused,
  /// TCP connect timed out before the server responded.
  connectionTimeout,
  /// Server accepted the connection but never sent a response.
  responseTimeout,
  /// TCP connection was reset mid-stream (ISP/CDN killed it).
  connectionReset,

  // ── HTTP ──
  /// 401 — credentials or authentication required.
  httpUnauthorized,
  /// 403 — access denied, WAF blocked, or IP rate-limited.
  httpForbidden,
  /// 404 — resource not found or removed.
  httpNotFound,
  /// 429 — too many requests / rate-limited.
  httpRateLimited,
  /// 500/502/503/504 — server-side problem.
  httpServerError,
  /// Any other non-2xx status code.
  httpUnexpectedStatus,

  // ── Content ──
  /// Signed URL or authentication token has expired.
  urlExpired,
  /// Malformed, unsupported, or invalid URL (blob:, empty, etc.).
  urlInvalid,
  /// Server returned an HTML error page instead of the media file.
  contentMismatch,
  /// SHA-256 hash verification failed after download.
  hashMismatch,
  /// Server returned 0 bytes — the response was empty.
  emptyResponse,
  /// ETag or Last-Modified changed mid-download — file was modified.
  resourceChanged,

  // ── HLS-specific ──
  /// HLS playlist contained no media segments.
  hlsPlaylistEmpty,
  /// All fetch tiers failed to retrieve the HLS playlist.
  hlsPlaylistFetchFailed,
  /// Could not fetch the HLS encryption key.
  hlsKeyFetchFailed,
  /// Token refresh exhausted — the stream URL has expired.
  hlsTokenExpired,
  /// Too many consecutive 403s — CDN blocked access.
  hlsCircuitBreaker,

  /// Native torrent engine is not available (required for torrent downloads).
  nativeEngineUnavailable,

  // ── File I/O ──
  /// No space left on device.
  diskFull,
  /// Cannot write to the output directory (missing permissions).
  permissionDenied,
  /// Other filesystem error (corrupt FS, path too long, etc.).
  fileSystemError,

  // ── Download integrity ──
  /// Not all chunks/segments completed successfully.
  chunkIncomplete,
  /// A chunk file was truncated, missing, or corrupt.
  chunkCorrupt,
  /// Merge was interrupted on a previous run.
  mergeInterrupted,
  /// Force merge failed.
  mergeFailed,

  // ── Stall / Speed ──
  /// Speed stayed below the configured threshold for too long.
  speedStall,
  /// Download stalled near completion — partial file is salvageable.
  partialDownload,

  // ── Torrent ──
  /// Could not parse the torrent file or fetch torrent metadata.
  torrentMetadataFailed,
  /// The libtorrent engine reported an error.
  torrentEngineError,

  // ── Other ──
  /// Unclassified or unexpected error.
  unknown,
}

enum DownloadPriority implements Comparable<DownloadPriority> {
  low(0),
  medium(1),
  high(2);

  final int value;
  const DownloadPriority(this.value);

  @override
  int compareTo(DownloadPriority other) => value.compareTo(other.value);
}

class DownloadChunk {
  final int index;
  final int start;
  /// The end byte of this chunk's range.  Mutable so dynamic chunk
  /// splitting (Phase 4) can shrink a slow chunk and redistribute its
  /// remaining range to a newly-created child chunk.
  int end;
  int bytesDownloaded;
  bool isCompleted;

  /// When non-null, this chunk was created by splitting another chunk.
  /// The value is the [index] of the original (parent) chunk.  Used by
  /// the speed tracker and merge-ordering logic.
  final int? splitFromIndex;

  DownloadChunk({
    required this.index,
    required this.start,
    required this.end,
    this.bytesDownloaded = 0,
    this.isCompleted = false,
    this.splitFromIndex,
  });

  /// Returns the expected byte length of this chunk, or `-1` if the
  /// chunk has no known end (open-ended / unknown-content-length).
  int get size => end >= start ? end - start + 1 : -1;

  /// True when this chunk's end is unknown (the server did not report a
  /// content-length, so the chunk spans from [start] to the end of the
  /// response). Open-ended chunks are not size-checked on resume.
  bool get isOpenEnded => end == -1;

  Map<String, dynamic> toJson() => {
    'index': index,
    'start': start,
    'end': end,
    'bytesDownloaded': bytesDownloaded,
    'isCompleted': isCompleted,
    if (splitFromIndex != null) 'splitFromIndex': splitFromIndex,
  };

  factory DownloadChunk.fromJson(Map<String, dynamic> json) => DownloadChunk(
    index: (json['index'] as num?)?.toInt() ?? 0,
    start: (json['start'] as num?)?.toInt() ?? 0,
    end: (json['end'] as num?)?.toInt() ?? 0,
    bytesDownloaded: (json['bytesDownloaded'] as num?)?.toInt() ?? 0,
    isCompleted: json['isCompleted'] as bool? ?? false,
    splitFromIndex: (json['splitFromIndex'] as num?)?.toInt(),
  );
}

class DownloadTask implements Comparable<DownloadTask> {
  final String id;
  String url;
  final String? sourcePageUrl;
  String savePath;
  final String tempDir;
  final String? expectedHash;
  final String? contentType;
  Map<String, String>? headers;
  DownloadPriority priority;
  DownloadState state;
  int totalBytes;
  int downloadedBytes;
  /// Discrete progress for HLS (segments) or multi-chunk HTTP.
  /// When [totalParts] > 0, [progress] uses completed/total parts instead of
  /// byte estimates — keeps Queue + notifications consistent.
  int completedParts;
  int totalParts;
  double speed; // In bytes/second
  String? actualHash;
  String? errorMessage;
  /// Transient UI status (resuming, converting, token refresh, rate-limit
  /// waits). Not persisted — cleared on terminal state transitions.
  String? statusMessage;
  /// Structured failure reason — set alongside [errorMessage] when the
  /// download fails.  Enables programmatic error handling (e.g. different
  /// retry strategies per failure type) without string-matching.
  DownloadFailure? failureReason;
  String? publicUri;
  String? publicPathLabel;
  String? publishErrorMessage;
  String? etag;
  String? lastModified;
  List<DownloadChunk> chunks;
  final DateTime createdAt;
  /// When set, the download will start at this time (Pro scheduled/night queue).
  DateTime? scheduledStartAt;
  Future<String?> Function({bool forceReload})? onTokenExpired;
  /// Optional callback that fetches a playlist/text URL through the WebView
  /// (sniffer-grade `fetchPlaylistBodyViaJavaScript`), bypassing Cloudflare
  /// WAF blocks that affect Dart's HTTP client.  Set when the task is created
  /// from a browser tab context (sniffed media or in-app-pasted URL).
  Future<String?> Function(String url, {Map<String, String>? headers})? fetchViaWebView;
  /// Optional lookup for HLS playlist response bodies captured by
  /// browser_guard.js during page load. Returns the cached playlist text
  /// for a given URL, or null if not cached. Avoids any network request
  /// when the playlist body was already captured.
  String? Function(String url)? hlsPlaylistCache;
  /// Optional callback that fetches binary data (e.g. HLS .ts segments)
  /// through the WebView's JavaScript XHR with arraybuffer response type.
  /// Returns the raw bytes as List<int>, or null on failure.
  Future<List<int>?> Function(String url)? fetchBinaryViaWebView;
  /// Optional callback that returns cookies from the WebView's cookie jar
  /// for a given URL.  Used by [HlsDownloader] to add Cloudflare cf_clearance
  /// and session cookies to Dart HTTP requests when the WebView XHR fetch
  /// fails (cross-origin) and the HTTP fallback would otherwise get 403.
  Future<Map<String, String>> Function(String url)? cookieProvider;
  bool isBackupImport;
  String? exportUri;
  String? exportDirectoryUri;

  DownloadTask({
    required this.id,
    required String url,
    this.sourcePageUrl,
    required this.savePath,
    required this.tempDir,
    this.expectedHash,
    this.contentType,
    this.headers,
    this.fetchViaWebView,
    this.hlsPlaylistCache,
    this.fetchBinaryViaWebView,
    this.cookieProvider,
    this.priority = DownloadPriority.medium,
    this.state = DownloadState.idle,
    this.totalBytes = -1,
    this.downloadedBytes = 0,
    this.completedParts = 0,
    this.totalParts = 0,
    this.speed = 0.0,
    this.actualHash,
    this.errorMessage,
    this.statusMessage,
    this.failureReason,
    this.publicUri,
    this.publicPathLabel,
    this.publishErrorMessage,
    this.etag,
    this.lastModified,
    this.chunks = const [],
    DateTime? createdAt,
    this.scheduledStartAt,
    this.isBackupImport = false,
    this.exportUri,
    this.exportDirectoryUri,
  }) : url = _cleanUrl(url),
       createdAt = createdAt ?? DateTime.now();

  static String _cleanUrl(String rawUrl) {
    var cleaned = rawUrl.trim();
    while (cleaned.startsWith('"') ||
        cleaned.startsWith("'") ||
        cleaned.startsWith('`')) {
      cleaned = cleaned.substring(1);
    }
    while (cleaned.endsWith('"') ||
        cleaned.endsWith("'") ||
        cleaned.endsWith('`')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    cleaned = cleaned.trim();
    cleaned = cleaned.replaceAll(' ', '%20');
    return cleaned;
  }

  /// 0.0–1.0 for UI / notifications.
  ///
  /// Priority:
  /// 1. **Parts** — HLS segments or HTTP chunks (`completedParts / totalParts`)
  /// 2. **Bytes** — `downloadedBytes / totalBytes` (clamped; estimates can lag)
  /// 3. **Legacy chunks list** — completed chunk objects
  double get progress {
    if (totalParts > 0) {
      final p = completedParts / totalParts;
      if (p.isNaN || p.isInfinite) return 0.0;
      return p.clamp(0.0, 1.0);
    }
    if (chunks.isNotEmpty) {
      final done = chunks.where((c) => c.isCompleted).length;
      return (done / chunks.length).clamp(0.0, 1.0);
    }
    if (totalBytes <= 0) return 0.0;
    final p = downloadedBytes / totalBytes;
    if (p.isNaN || p.isInfinite) return 0.0;
    return p.clamp(0.0, 1.0);
  }

  /// Integer 0–100 for notifications / FGS (same source as [progress]).
  int get progressPercent => (progress * 100).round().clamp(0, 100);

  /// True when this task is scheduled to start at a future time.
  bool get isScheduled => scheduledStartAt != null && scheduledStartAt!.isAfter(DateTime.now());

  /// Copies runtime browser bridges from [donor]. These closures cannot be
  /// persisted to JSON and are lost after app restart / queue reload — they
  /// must be re-attached from a live browser tab (or a freshly sniffed task).
  void copyBrowserBridgesFrom(DownloadTask donor) {
    if (donor.fetchViaWebView != null) {
      fetchViaWebView = donor.fetchViaWebView;
    }
    if (donor.fetchBinaryViaWebView != null) {
      fetchBinaryViaWebView = donor.fetchBinaryViaWebView;
    }
    if (donor.hlsPlaylistCache != null) {
      hlsPlaylistCache = donor.hlsPlaylistCache;
    }
    if (donor.cookieProvider != null) {
      cookieProvider = donor.cookieProvider;
    }
    if (donor.onTokenExpired != null) {
      onTokenExpired = donor.onTokenExpired;
    }
  }

  /// True when at least one WAF-bypass bridge is attached.
  bool get hasBrowserBridges =>
      fetchViaWebView != null ||
      cookieProvider != null ||
      onTokenExpired != null ||
      fetchBinaryViaWebView != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'sourcePageUrl': sourcePageUrl,
    'savePath': savePath,
    'tempDir': tempDir,
    'expectedHash': expectedHash,
    'contentType': contentType,
    'headers': headers,
    'priority': priority.name,
    'state': state.name,
    'totalBytes': totalBytes,
    'downloadedBytes': downloadedBytes,
    'completedParts': completedParts,
    'totalParts': totalParts,
    'speed': speed,
    'actualHash': actualHash,
    'errorMessage': errorMessage,
    'failureReason': failureReason?.name,
    'publicUri': publicUri,
    'publicPathLabel': publicPathLabel,
    'publishErrorMessage': publishErrorMessage,
    'etag': etag,
    'lastModified': lastModified,
    'chunks': chunks.map((c) => c.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    if (scheduledStartAt != null)
      'scheduledStartAt': scheduledStartAt!.toIso8601String(),
    'isBackupImport': isBackupImport,
    'exportUri': exportUri,
    'exportDirectoryUri': exportDirectoryUri,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    String optString(String key, String defaultValue) {
      final v = json[key];
      if (v == null) return defaultValue;
      return v.toString();
    }

    int optInt(String key, int defaultValue) {
      final v = json[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? defaultValue;
      return defaultValue;
    }

    final id = optString('id', '');
    final url = optString('url', '');
    final savePath = optString('savePath', '');
    final tempDir = optString('tempDir', '');
    final priorityStr = optString('priority', 'medium');
    final stateStr = optString('state', 'paused');
    final totalBytes = optInt('totalBytes', 0);
    final downloadedBytes = optInt('downloadedBytes', 0);
    final completedParts = optInt('completedParts', 0);
    final totalParts = optInt('totalParts', 0);

    final chunksList = json['chunks'];
    final chunks = <DownloadChunk>[];
    if (chunksList is List) {
      for (final c in chunksList) {
        if (c is Map<String, dynamic>) {
          chunks.add(DownloadChunk.fromJson(c));
        } else if (c is Map) {
          chunks.add(DownloadChunk.fromJson(Map<String, dynamic>.from(c)));
        }
      }
    }

    DownloadPriority priority;
    try {
      priority = DownloadPriority.values.byName(priorityStr);
    } catch (_) {
      priority = DownloadPriority.medium;
    }

    DownloadState state;
    try {
      state = DownloadState.values.byName(stateStr);
    } catch (_) {
      state = DownloadState.paused;
    }

    return DownloadTask(
      id: id,
      url: url,
      sourcePageUrl: json['sourcePageUrl'] as String?,
      savePath: savePath,
      tempDir: tempDir,
      expectedHash: json['expectedHash'] as String?,
      contentType: json['contentType'] as String?,
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      priority: priority,
      state: state,
      totalBytes: totalBytes,
      downloadedBytes: downloadedBytes,
      completedParts: completedParts,
      totalParts: totalParts,
      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
      actualHash: json['actualHash'] as String?,
      errorMessage: json['errorMessage'] as String?,
      failureReason: json['failureReason'] != null
          ? DownloadFailure.values.cast<DownloadFailure?>().firstWhere(
              (e) => e?.name == json['failureReason'],
              orElse: () => DownloadFailure.unknown,
            )
          : null,
      publicUri: json['publicUri'] as String?,
      publicPathLabel: json['publicPathLabel'] as String?,
      publishErrorMessage: json['publishErrorMessage'] as String?,
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      chunks: chunks,
      createdAt: json['createdAt'] != null
          ? (DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now())
          : DateTime.now(),
      scheduledStartAt: json['scheduledStartAt'] != null
          ? DateTime.tryParse(json['scheduledStartAt'] as String)
          : null,
      isBackupImport: json['isBackupImport'] as bool? ?? false,
      exportUri: json['exportUri'] as String?,
      exportDirectoryUri: json['exportDirectoryUri'] as String?,
    );
  }

  @override
  int compareTo(DownloadTask other) {
    // Priority order is descending (high priority first)
    final priorityComparison = other.priority.compareTo(priority);
    if (priorityComparison != 0) {
      return priorityComparison;
    }
    // Creation time is ascending (older first = FIFO)
    return createdAt.compareTo(other.createdAt);
  }
}

/// Fields by which a list of [DownloadTask] can be sorted.
/// Used by [DownloadQueue.queryTasks].
enum TaskSortField {
  /// Sort by [DownloadTask.createdAt] (newest first).
  date,

  /// Sort by the filename portion of [DownloadTask.savePath].
  name,

  /// Sort by [DownloadTask.totalBytes] (largest first).
  size,

  /// Sort by [DownloadTask.priority] (highest priority first).
  priority,

  /// Sort by [DownloadTask.state] (terminal states last).
  state,

  /// Sort by [DownloadTask.speed] (fastest first).
  speed,
}

class PublishedDownload {
  final String uri;
  final String pathLabel;

  const PublishedDownload({required this.uri, required this.pathLabel});
}

abstract interface class CompletedDownloadPublisher {
  Future<PublishedDownload?> publishCompletedFile(DownloadTask task);
}

abstract interface class BaseDownloader {
  Stream<DownloadTask> get onTaskUpdated;
  Future<void> start();
  Future<void> pause({DownloadState targetState});
  Future<void> dispose();
}

