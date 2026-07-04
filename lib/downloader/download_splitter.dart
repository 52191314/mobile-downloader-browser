import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'range_calculator.dart';
import 'file_combiner.dart';
import 'download_logger.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  final message = '[DownloadSplitter] $context: $error';
  debugPrint(message);
  DownloadLogger.instance.error(message);
}

class DownloadSplitter implements BaseDownloader {
  static const Duration defaultProbeTimeout = Duration(seconds: 12);
  static const Duration defaultResponseTimeout = Duration(seconds: 20);
  static const Duration defaultBodyIdleTimeout = Duration(seconds: 30);

  final DownloadTask task;
  final http.Client client;
  final bool _ownsClient;
  final int numChunks;
  final Duration probeTimeout;
  final Duration responseTimeout;
  final Duration bodyIdleTimeout;
  final int minSpeedBytesPerSec;
  final int stallTimeoutSeconds;
  bool _isPaused = false;
  bool _started = false;
  bool _stallDetected = false;
  double _stallAccumSeconds = 0.0;
  Future<void>? _runningFuture;
  Object? _activeRunToken;
  final List<StreamSubscription<List<int>>> _subscriptions = [];
  final List<IOSink> _sinks = [];
  final List<Completer<void>> _completers = [];

  Timer? _speedTimer;
  int _lastBytesTick = 0;

  final StreamController<DownloadTask> _taskUpdateController =
      StreamController<DownloadTask>.broadcast();
  @override
  Stream<DownloadTask> get onTaskUpdated => _taskUpdateController.stream;

  DownloadSplitter({
    required this.task,
    http.Client? client,
    this.numChunks = 8,
    this.probeTimeout = defaultProbeTimeout,
    this.responseTimeout = defaultResponseTimeout,
    this.bodyIdleTimeout = defaultBodyIdleTimeout,
    this.minSpeedBytesPerSec = 0,
    this.stallTimeoutSeconds = 20,
    this.partialDownloadThreshold = 0.95,
  }) : _ownsClient = client == null,
       client = client ?? http.Client();

  /// When a download stalls and exceeds this ratio (0.0–1.0), the task
  /// is flagged as a partial download candidate instead of a plain failure.
  final double partialDownloadThreshold;

  Future<void> _saveMeta() async {
    final dir = Directory(task.tempDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${task.tempDir}/meta.json');
    await file.parent.create(recursive: true);
    try {
      await file.writeAsString(jsonEncode(task.toJson()));
    } on PathNotFoundException {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(task.toJson()));
    }
  }

  Future<bool> _loadMeta() async {
    final file = File('${task.tempDir}/meta.json');
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final loadedTask = DownloadTask.fromJson(json);
        if (loadedTask.url == task.url) {
          task.totalBytes = loadedTask.totalBytes;
          task.etag = loadedTask.etag;
          task.lastModified = loadedTask.lastModified;
          task.chunks = loadedTask.chunks;
          task.downloadedBytes = loadedTask.downloadedBytes;
          return true;
        }
      } catch (e) {
        // Ignore parsing errors and proceed with fresh start
      }
    }
    return false;
  }

  Future<void> _probeServerAndInit() async {
    int totalBytes = -1;
    bool supportsRanges = false;
    String? etag;
    String? lastModified;

    try {
      final headResponse = await client
          .head(Uri.parse(task.url), headers: task.headers)
          .timeout(probeTimeout);
      final contentLengthHeader =
          headResponse.headers['content-length'] ??
          headResponse.headers['Content-Length'];
      final acceptRangesHeader =
          headResponse.headers['accept-ranges'] ??
          headResponse.headers['Accept-Ranges'];

      if (headResponse.statusCode == 200) {
        if (contentLengthHeader != null) {
          totalBytes = int.tryParse(contentLengthHeader) ?? -1;
        }
        if (acceptRangesHeader?.toLowerCase() == 'bytes') {
          supportsRanges = true;
        }
        etag = headResponse.headers['etag'] ?? headResponse.headers['ETag'];
        lastModified =
            headResponse.headers['last-modified'] ??
            headResponse.headers['Last-Modified'];
      } else if (headResponse.statusCode == 403 ||
          headResponse.statusCode == 401 ||
          headResponse.statusCode == 405) {
        // Some CDNs block HEAD entirely. Skip directly to the GET probe
        // instead of waiting for the full timeout — the GET will tell us
        // if the resource is accessible.
        _logError(
          'HEAD returned ${headResponse.statusCode}, falling back to GET probe',
          'Server blocks HEAD requests',
        );
      }
    } catch (e, s) {
      _logError('HEAD probe failed, falling back to GET probe', e, s);
    }

    if (totalBytes <= 0 || !supportsRanges) {
      final getRequest = http.Request('GET', Uri.parse(task.url));
      if (task.headers != null) {
        getRequest.headers.addAll(task.headers!);
      }
      getRequest.headers['Range'] = 'bytes=0-0';

      try {
        final getResponse = await client.send(getRequest).timeout(probeTimeout);
        try {
          if (getResponse.statusCode == 206) {
            supportsRanges = true;
            final contentRange =
                getResponse.headers['content-range'] ??
                getResponse.headers['Content-Range'];
            if (contentRange != null) {
              final match = RegExp(
                r'bytes \d+-\d+/(\d+)',
              ).firstMatch(contentRange);
              if (match != null) {
                totalBytes = int.tryParse(match.group(1)!) ?? -1;
              }
            }
          } else if (getResponse.statusCode >= 200 &&
              getResponse.statusCode < 300) {
            final contentLengthHeaderGet =
                getResponse.headers['content-length'] ??
                getResponse.headers['Content-Length'];
            if (contentLengthHeaderGet != null) {
              totalBytes = int.tryParse(contentLengthHeaderGet) ?? -1;
            }
            supportsRanges = false;
          }
          etag ??= getResponse.headers['etag'] ?? getResponse.headers['ETag'];
          lastModified ??=
              getResponse.headers['last-modified'] ??
              getResponse.headers['Last-Modified'];
        } finally {
          await getResponse.stream.listen((_) {}).cancel();
        }
      } catch (e, s) {
        _logError('GET range probe failed, falling back to full GET', e, s);
        totalBytes = -1;
        supportsRanges = false;
      }
    }

    task.totalBytes = totalBytes;
    task.etag = etag;
    task.lastModified = lastModified;

    if (supportsRanges && totalBytes > 0) {
      task.chunks = HttpRangeCalculator.calculate(
        contentLength: totalBytes,
        maxChunks: numChunks,
      );
    } else {
      // single chunk fallback
      task.chunks = [
        DownloadChunk(
          index: 0,
          start: 0,
          end: totalBytes > 0 ? totalBytes - 1 : -1,
          bytesDownloaded: 0,
          isCompleted: false,
        ),
      ];
    }
  }

  @override
  Future<void> start() async {
    final runToken = Object();
    _activeRunToken = runToken;

    if (_started) {
      if (!_isPaused) return;
      if (_runningFuture != null) {
        try {
          await _runningFuture;
        } catch (e, s) {
          _logError('Waiting for previous run future failed', e, s);
        }
      }
      if (_activeRunToken != runToken) return;
      if (task.state != DownloadState.downloading) {
        _started = false;
        return;
      }
    }

    _started = true;
    _isPaused = false;

    final currentRunFuture = () async {
      task.state = DownloadState.downloading;
      task.errorMessage = null;

      _emitTask();

      try {
        final metaLoaded = await _loadMeta();

        if (!metaLoaded) {
          await _probeServerAndInit();
        }

        await _saveMeta();

        if (_isPaused) return;

        _lastBytesTick = task.downloadedBytes;
        _speedTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
          _updateProgress();
          final currentBytes = task.downloadedBytes;
          task.speed = (currentBytes - _lastBytesTick) * 2.0;
          _lastBytesTick = currentBytes;

          // Stall detection: if speed stays below threshold for stallTimeoutSeconds
          // mark the task as failed so DownloadQueue auto-retry can restart it.
          // Enabled for both known-length (totalBytes > 0) and unknown-length
          // downloads (where stall detection must rely on downloadedBytes > 0
          // instead, since totalBytes is -1).
          final isInProgress = task.totalBytes > 0
              ? task.downloadedBytes < task.totalBytes
              : task.downloadedBytes > 0;
          if (minSpeedBytesPerSec > 0 &&
              task.state == DownloadState.downloading &&
              isInProgress) {
            if (task.speed < minSpeedBytesPerSec) {
              _stallAccumSeconds += 0.5;
              if (_stallAccumSeconds >= stallTimeoutSeconds) {
                _stallAccumSeconds = 0.0;
                _handleStall();
                return;
              }
            } else {
              _stallAccumSeconds = 0.0;
            }
          }
          _emitTask();
        });

        final futures = task.chunks
            .map((chunk) => _downloadChunk(chunk))
            .toList();
        await Future.wait(futures);

        if (_isPaused || _stallDetected) return;

        // --- Defensive checks: reject clearly bad downloads ---
        // Run these BEFORE the allComplete check so a 0-byte response
        // surfaces as a clear "0 bytes" error rather than the generic
        // "not all chunks completed" message.
        if (task.downloadedBytes == 0) {
          throw Exception(
            'Server returned 0 bytes. The URL may have expired, '
            'require authentication, or be invalid.',
          );
        }

        final allComplete = task.chunks.every((c) => c.isCompleted);
        if (!allComplete) {
          throw Exception('Download interrupted: not all chunks completed.');
        }

        // If the server didn't report a content-length (totalBytes <= 0)
        // and the response is suspiciously small, check whether it looks
        // like an HTML error page that was served as 200 OK.
        if (task.totalBytes <= 0 || task.downloadedBytes < 4096) {
          final samplePath = '${task.tempDir}/part_${task.chunks.first.index}';
          final sampleFile = File(samplePath);
          if (await sampleFile.exists()) {
            final raf = await sampleFile.open();
            try {
              final bytes = await raf.read(256);
              if (_looksLikeHtmlError(bytes)) {
                throw Exception(
                  'Server returned an HTML error page instead of the media file. '
                  'Authentication may be required, or the URL has expired.',
                );
              }
            } finally {
              await raf.close();
            }
          }
        }

        final chunkFiles = task.chunks
            .map((c) => File('${task.tempDir}/part_${c.index}'))
            .toList();
        final finalFile = File(task.savePath);

        final actualHash = await FileCombiner.combineAndHash(
          chunks: chunkFiles,
          destination: finalFile,
          deleteChunks: true,
        );

        task.actualHash = actualHash;

        if (task.expectedHash != null) {
          if (actualHash.toLowerCase() != task.expectedHash!.toLowerCase()) {
            // Clean up the corrupt file so we don't leave a 0KB/bad file
            // on disk that looks like a valid download.
            if (await finalFile.exists()) {
              try {
                await finalFile.delete();
              } catch (_) {}
            }
            throw Exception(
              'SHA-256 mismatch: Expected ${task.expectedHash}, got $actualHash',
            );
          }
        }

        final tempDir = Directory(task.tempDir);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }

        _updateProgress();
        if (task.totalBytes <= 0) {
          task.totalBytes = task.downloadedBytes;
        }
        task.state = DownloadState.completed;
        _emitTask();
      } catch (e) {
        if (_isPaused) {
          return;
        }

        for (final sub in List<StreamSubscription<List<int>>>.from(
          _subscriptions,
        )) {
          try {
            sub.cancel();
          } catch (e, s) {
            _logError(
              'Failed to cancel subscription during error cleanup',
              e,
              s,
            );
          }
        }
        _subscriptions.clear();

        for (final sink in List<IOSink>.from(_sinks)) {
          try {
            sink.close();
          } catch (e, s) {
            _logError('Failed to close sink during error cleanup', e, s);
          }
        }
        _sinks.clear();

        for (final completer in List<Completer<void>>.from(_completers)) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
        _completers.clear();

        // Clean up the final file so we don't leave a 0KB file on disk
        // that looks like a successful download.
        try {
          final finalFile = File(task.savePath);
          if (await finalFile.exists()) {
            final len = await finalFile.length();
            if (len == 0) {
              await finalFile.delete();
            }
          }
        } catch (_) {}

        _updateProgress();
        task.state = DownloadState.failed;
        task.errorMessage = e.toString();
        _emitTask();
        rethrow;
      } finally {
        _started = false;
        _runningFuture = null;
        _speedTimer?.cancel();
        task.speed = 0;
      }
    }();

    _runningFuture = currentRunFuture;
    await currentRunFuture;
  }

  /// Heuristic check for an HTML error page served as 200 OK.
  /// Some CDNs/websites return a 200 with a small "Access Denied" or login
  /// page when the request is missing auth headers, instead of a real 403.
  bool _looksLikeHtmlError(List<int> bytes) {
    if (bytes.isEmpty) return false;
    // Decode ASCII prefix (case-insensitive)
    final ascii = String.fromCharCodes(
      bytes.take(256).where((b) => b < 128),
    ).trimLeft().toLowerCase();
    if (ascii.startsWith('<!doctype html') ||
        ascii.startsWith('<!doctype\x20') ||
        ascii.startsWith('<html') ||
        ascii.startsWith('<head') ||
        ascii.startsWith('<body')) {
      // Look for common error/login markers
      return ascii.contains('access denied') ||
          ascii.contains('forbidden') ||
          ascii.contains('not authorized') ||
          ascii.contains('login') ||
          ascii.contains('sign in') ||
          ascii.contains('error') ||
          ascii.contains('403') ||
          ascii.contains('401');
    }
    return false;
  }

  Future<void> _downloadChunk(DownloadChunk chunk) async {
    if (_isPaused) return;
    final chunkPath = '${task.tempDir}/part_${chunk.index}';
    final chunkFile = File(chunkPath);
    int diskBytes = 0;
    if (await chunkFile.exists()) {
      diskBytes = await chunkFile.length();
    }

    if (chunk.isCompleted || (!chunk.isOpenEnded && diskBytes >= chunk.size)) {
      if (!chunk.isOpenEnded) {
        chunk.bytesDownloaded = chunk.size;
        chunk.isCompleted = true;
      }
      return;
    }

    final bool rangeSupported = task.chunks.length > 1;
    final int rangeStart = chunk.start + diskBytes;
    final int rangeEnd = chunk.end;

    if (!rangeSupported && diskBytes > 0) {
      await chunkFile.writeAsBytes([]);
      diskBytes = 0;
    }

    // Try the download; on 403/401, refresh the URL via onTokenExpired
    // and retry once. This mirrors the HLS token-refresh pattern and
    // recovers downloads where the direct file URL has a short-lived
    // signed token.
    http.StreamedResponse? response;
    bool retriedWithRefresh = false;
    // 429: allow up to 3 rate-limit retries in addition to the auth retry
    for (int attempt = 0; attempt < 5; attempt++) {
      if (_isPaused || _stallDetected) return;
      final request = http.Request('GET', Uri.parse(task.url));
      if (task.headers != null) {
        request.headers.addAll(task.headers!);
      }
      if (rangeSupported) {
        request.headers['Range'] = 'bytes=$rangeStart-$rangeEnd';
      } else if (chunk.isOpenEnded && diskBytes > 0) {
        // Open-ended resume: append from the last downloaded byte.
        request.headers['Range'] = 'bytes=$diskBytes-';
      }

      response = await client.send(request).timeout(responseTimeout);

      if (_isPaused || _stallDetected) {
        await response.stream.listen((_) {}).cancel();
        return;
      }

      // --- HTTP 429 Rate Limited: back off then retry ---
      if (response.statusCode == 429) {
        await response.stream.listen((_) {}).cancel();
        final retryAfterRaw = response.headers['retry-after'];
        Duration backoff = const Duration(seconds: 30);
        if (retryAfterRaw != null) {
          final secs = int.tryParse(retryAfterRaw.trim());
          if (secs != null) {
            backoff = Duration(seconds: secs.clamp(5, 120));
          }
        }
        // Exponential: attempt 0→1×, 1→2×, 2→4×, capped at 2 min
        final waitSecs = (backoff.inSeconds * (1 << attempt.clamp(0, 2)))
            .clamp(5, 120);
        final wait = Duration(seconds: waitSecs);
        final thresholdLabel = minSpeedBytesPerSec > 0
            ? '${(minSpeedBytesPerSec / 1024).toStringAsFixed(0)} KB/s threshold'
            : 'rate limit';
        task.errorMessage =
            '[Rate limited] Host returned 429 — waiting ${wait.inSeconds}s '
            'before retry ${attempt + 1}/3... ($thresholdLabel)';
        _emitTask();
        await Future<void>.delayed(wait);
        response = null;
        continue;
      }

      // --- HTTP 403/401: try token refresh once ---
      if (response.statusCode == 403 || response.statusCode == 401) {
        await response.stream.listen((_) {}).cancel();
        if (retriedWithRefresh || task.onTokenExpired == null) {
          break;
        }
        retriedWithRefresh = true;
        try {
          task.errorMessage = 'Token expired, refreshing...';
          _emitTask();
          final newUrl = await task.onTokenExpired!(forceReload: false);
          if (newUrl == null || newUrl == task.url) break;
          task.url = newUrl;
          continue;
        } catch (e, s) {
          _logError('Token refresh failed for direct download', e, s);
          break;
        }
      }
      break;
    }

    if (response == null) {
      throw Exception(
        'Download failed: server returned 403/401 and token refresh was unavailable.',
      );
    }

    if (rangeSupported) {
      if (response.statusCode != 206) {
        await response.stream.listen((_) {}).cancel();
        throw Exception(
          'Server returned status ${response.statusCode} instead of 206 Partial Content',
        );
      }
    } else {
      if (response.statusCode >= 400) {
        await response.stream.listen((_) {}).cancel();
        throw Exception(
          'Server returned status ${response.statusCode} instead of 200 OK',
        );
      }
      if (chunk.isOpenEnded && diskBytes > 0 &&
          response.statusCode == 200) {
        // Open-ended resume was answered with 200 OK — the server ignored
        // the Range header and is re-sending the full body. Truncate the
        // file and reset diskBytes so the full body is written fresh from
        // the beginning instead of being appended after existing bytes
        // (which would produce a corrupt file with duplicate data).
        await chunkFile.writeAsBytes([], flush: true);
        diskBytes = 0;
        debugPrint(
          '[DownloadSplitter] Open-ended resume returned 200 OK for '
          'chunk ${chunk.index}; truncated file for fresh re-download.',
        );
      }
    }

    final sink = chunkFile.openWrite(mode: FileMode.append);
    _sinks.add(sink);

    final completer = Completer<void>();
    _completers.add(completer);
    StreamSubscription<List<int>>? subscription;

    subscription = response.stream
        .timeout(bodyIdleTimeout)
        .listen(
          (data) {
            if (_isPaused || _stallDetected || completer.isCompleted) return;
            try {
              sink.add(data);
            } catch (e, s) {
              _logError('Failed to write data to sink', e, s);
              return;
            }
            diskBytes += data.length;
            chunk.bytesDownloaded = diskBytes;
          },
          onError: (Object error) {
            if (!completer.isCompleted) {
              completer.completeError(error);
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
          cancelOnError: true,
        );

    _subscriptions.add(subscription);

    try {
      await completer.future;
      if (!_isPaused) {
        if (diskBytes >= chunk.size || chunk.end == -1) {
          // If the server didn't report a total size (chunk.end == -1)
          // and we received zero bytes, don't mark the chunk as complete.
          // The defensive 0-byte check in start() will surface a clear
          // error to the user instead of a 0KB file.
          if (!(diskBytes == 0 && chunk.end == -1)) {
            chunk.isCompleted = true;
          }
        }
      }
    } finally {
      _subscriptions.remove(subscription);
      _sinks.remove(sink);
      _completers.remove(completer);
      await sink.close();
    }
  }



  void _updateProgress() {
    int total = 0;
    for (final chunk in task.chunks) {
      total += chunk.bytesDownloaded;
    }
    task.downloadedBytes = total;
  }

  @override
  Future<void> pause({DownloadState targetState = DownloadState.paused}) async {
    if (task.state != DownloadState.downloading &&
        !_started &&
        _runningFuture == null) {
      return;
    }
    _updateProgress();
    _isPaused = true;
    task.state = targetState;
    task.speed = 0;
    _speedTimer?.cancel();

    for (final completer in List<Completer<void>>.from(_completers)) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _completers.clear();

    for (final sub in List<StreamSubscription<List<int>>>.from(
      _subscriptions,
    )) {
      await sub.cancel();
    }

    if (_runningFuture != null) {
      try {
        await _runningFuture;
      } catch (e, s) {
        _logError('Waiting for running download during pause failed', e, s);
      }
    }

    _subscriptions.clear();
    _sinks.clear();

    await _saveMeta();
    _emitTask();
  }

  Future<void> cancel() async {
    _isPaused = true;

    for (final completer in List<Completer<void>>.from(_completers)) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _completers.clear();

    for (final sub in List<StreamSubscription<List<int>>>.from(
      _subscriptions,
    )) {
      await sub.cancel();
    }

    if (_runningFuture != null) {
      try {
        await _runningFuture;
      } catch (e, s) {
        _logError('Waiting for running download during cancel failed', e, s);
      }
    }

    _subscriptions.clear();
    _sinks.clear();

    final tempDir = Directory(task.tempDir);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }

    final finalFile = File(task.savePath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }

    task.state = DownloadState.idle;
    task.downloadedBytes = 0;
    task.chunks = [];
    _emitTask();
  }

  @override
  Future<void> dispose() async {
    await pause(targetState: task.state);
    if (_ownsClient) {
      client.close();
    }
    if (!_taskUpdateController.isClosed) {
      await _taskUpdateController.close();
    }
  }

  void _emitTask() {
    if (!_taskUpdateController.isClosed) {
      _taskUpdateController.add(task);
    }
  }

  /// Called by the stall-detection timer when speed has been below
  /// [minSpeedBytesPerSec] for [stallTimeoutSeconds] seconds.
  /// Marks the task failed so [DownloadQueue] auto-retry can restart it.
  void _handleStall() {
    _stallDetected = true;
    _speedTimer?.cancel();
    task.state = DownloadState.failed;
    task.speed = 0;
    final thresholdKbps = (minSpeedBytesPerSec / 1024).toStringAsFixed(0);

    // Check if this is a partial download candidate
    if (task.totalBytes > 0 && partialDownloadThreshold < 1.0) {
      final ratio = task.downloadedBytes / task.totalBytes;
      if (ratio >= partialDownloadThreshold) {
        final pct = (ratio * 100).toStringAsFixed(1);
        task.errorMessage =
            '[PARTIAL:$pct] Server closed connection at ${pct}%. '
            'Merge the partial file?';
        _emitTask();
        return;
      }
    }

    task.errorMessage =
        '[Speed stall] Speed stayed below $thresholdKbps KB/s '
        'for ${stallTimeoutSeconds}s. Auto-retrying...';
    // Complete all active chunk completers so Future.wait() unblocks
    for (final completer in List<Completer<void>>.from(_completers)) {
      if (!completer.isCompleted) completer.complete();
    }
    _emitTask();
  }
}


