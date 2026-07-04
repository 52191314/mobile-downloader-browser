enum DownloadState { idle, downloading, paused, completed, failed }

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
  final int end;
  int bytesDownloaded;
  bool isCompleted;

  DownloadChunk({
    required this.index,
    required this.start,
    required this.end,
    this.bytesDownloaded = 0,
    this.isCompleted = false,
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
  };

  factory DownloadChunk.fromJson(Map<String, dynamic> json) => DownloadChunk(
    index: (json['index'] as num?)?.toInt() ?? 0,
    start: (json['start'] as num?)?.toInt() ?? 0,
    end: (json['end'] as num?)?.toInt() ?? 0,
    bytesDownloaded: (json['bytesDownloaded'] as num?)?.toInt() ?? 0,
    isCompleted: json['isCompleted'] as bool? ?? false,
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
  final Map<String, String>? headers;
  DownloadPriority priority;
  DownloadState state;
  int totalBytes;
  int downloadedBytes;
  double speed; // In bytes/second
  String? actualHash;
  String? errorMessage;
  String? publicUri;
  String? publicPathLabel;
  String? publishErrorMessage;
  String? etag;
  String? lastModified;
  List<DownloadChunk> chunks;
  final DateTime createdAt;
  Future<String?> Function({bool forceReload})? onTokenExpired;
  /// Optional callback that fetches a URL through the WebView's JavaScript
  /// `fetch()` API, bypassing Cloudflare WAF blocks that affect Dart's HTTP
  /// client.  Set when the task is created from a browser tab context
  /// (sniffed media or in-app-pasted URL).
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
    this.priority = DownloadPriority.medium,
    this.state = DownloadState.idle,
    this.totalBytes = -1,
    this.downloadedBytes = 0,
    this.speed = 0.0,
    this.actualHash,
    this.errorMessage,
    this.publicUri,
    this.publicPathLabel,
    this.publishErrorMessage,
    this.etag,
    this.lastModified,
    this.chunks = const [],
    DateTime? createdAt,
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

  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

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
    'speed': speed,
    'actualHash': actualHash,
    'errorMessage': errorMessage,
    'publicUri': publicUri,
    'publicPathLabel': publicPathLabel,
    'publishErrorMessage': publishErrorMessage,
    'etag': etag,
    'lastModified': lastModified,
    'chunks': chunks.map((c) => c.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
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
      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
      actualHash: json['actualHash'] as String?,
      errorMessage: json['errorMessage'] as String?,
      publicUri: json['publicUri'] as String?,
      publicPathLabel: json['publicPathLabel'] as String?,
      publishErrorMessage: json['publishErrorMessage'] as String?,
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      chunks: chunks,
      createdAt: json['createdAt'] != null
          ? (DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now())
          : DateTime.now(),
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

