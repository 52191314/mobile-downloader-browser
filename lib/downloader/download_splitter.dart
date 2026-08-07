import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'models.dart';
import 'download_error_classifier.dart';
import 'range_calculator.dart';
import 'file_combiner.dart';
import '../platform/ts_remux_service.dart';
import '../platform/native_download_client.dart';
import 'speed_limiter.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  final message = '[DownloadSplitter] $context: $error';
  debugPrint(message);
  debugPrint(message);
}

class DownloadSplitter implements BaseDownloader {
  static const Duration defaultProbeTimeout = Duration(seconds: 12);
  static const Duration defaultResponseTimeout = Duration(seconds: 20);
  static const Duration defaultBodyIdleTimeout = Duration(seconds: 15);

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

  /// Optional global speed limiter injected by [DownloadQueue].
  /// When non-null and active, individual chunk writes are throttled
  /// to stay within the configured rate.
  final SpeedLimiter? _speedLimiter;
  bool _stallDetected = false;
  double _stallAccumSeconds = 0.0;
  Future<void>? _runningFuture;
  Object? _activeRunToken;
  final List<StreamSubscription<List<int>>> _subscriptions = [];
  final List<IOSink> _sinks = [];
  final List<Completer<void>> _completers = [];

  Timer? _speedTimer;
  int _lastBytesTick = 0;
  /// Diagnostic: counts consecutive 500ms ticks where speed was 0 while
  /// the task is in downloading state.  Reset to 0 whenever data flows.
  int _zeroSpeedTickCount = 0;

  /// Dirty flag — set true whenever a chunk writes bytes.
  /// Cleared by [_updateProgress] so it can skip summing chunks when idle.
  bool _progressDirty = false;

  // ── Dynamic chunk splitting fields ──────────────────────────────────
  /// Set of futures for all active chunk downloads (including dynamically
  /// added split chunks).  Futures are added when a chunk starts and
  /// removed via [whenComplete] when the chunk finishes.  Used by
  /// [_waitForChunks] to await all chunks before merging.
  final Set<Future<void>> _activeChunkFutures = {};

  /// Set of active native chunk indexes.
  final Set<int> _activeNativeChunks = {};

  /// Map of chunk index to active native downloadId.
  final Map<int, String> _activeNativeChunkIds = {};



  /// Per-chunk bytesDownloaded at last split-check sample point.
  final Map<int, int> _lastChunkBytes = {};

  /// Timestamp of last split-check pass.
  DateTime _lastSplitCheck = DateTime.now();

  /// Counts consecutive slow-speed samples for each chunk.  Reset to 0
  /// when the chunk's speed normalizes or the chunk completes.
  final Map<int, int> _slowChunkSampleCount = {};

  /// Maximum number of chunk splits allowed for this task.  Prevents
  /// unlimited fragmentation from a pathological speed pattern.
  int _splitsRemaining = 4;

  /// Counter for reconnect attempts per chunk.  Reset after a successful
  /// stream write.
  int _reconnectAttempts = 0;
  static const int _maxReconnectsPerChunk = 5;

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
    this.remuxTsToMp4 = true,
    SpeedLimiter? speedLimiter,
  }) : _ownsClient = client == null,
       client = client ?? http.Client(),
       _speedLimiter = speedLimiter;

  /// When a download stalls and exceeds this ratio (0.0–1.0), the task
  /// is flagged as a partial download candidate instead of a plain failure.
  final double partialDownloadThreshold;

  /// When true, MPEG-TS (.ts) output is remuxed to MP4 after completion
  /// via Android's native MediaExtractor + MediaMuxer.
  final bool remuxTsToMp4;

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
          // Drain (not cancel) so the connection returns to the keep-alive
          // pool — but only when the body is small. If the server ignored
          // the Range header and streamed the whole file, abort instead of
          // downloading it all just to discard it.
          final probeLen = getResponse.contentLength;
          if (getResponse.statusCode == 206 ||
              (probeLen != null && probeLen <= 65536)) {
            try {
              await getResponse.stream.drain<void>();
            } catch (_) {}
          } else {
            try {
              await getResponse.stream.listen((_) {}, onError: (_) {}).cancel();
            } catch (_) {}
          }
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

  /// Called on resume (when [meta.json] exists) to re-validate the server
  /// resource.  Sends a lightweight HEAD (or GET bytes=0-0 fallback) and
  /// compares [etag]/[lastModified]/[content-length] against the stored
  /// values.  If the resource changed, deletes stale partials and re-initializes
  /// chunks so the download restarts fresh instead of silently corrupting.
  Future<void> _revalidateOnResume() async {
    String? currentEtag;
    String? currentLastModified;
    int currentTotalBytes = -1;

    try {
      final headResponse = await client
          .head(Uri.parse(task.url), headers: task.headers)
          .timeout(probeTimeout);
      if (headResponse.statusCode == 200) {
        currentEtag =
            headResponse.headers['etag'] ?? headResponse.headers['ETag'];
        currentLastModified =
            headResponse.headers['last-modified'] ??
            headResponse.headers['Last-Modified'];
        final cl = headResponse.headers['content-length'] ??
            headResponse.headers['Content-Length'];
        if (cl != null) {
          currentTotalBytes = int.tryParse(cl) ?? -1;
        }
      } else {
        // Server blocks HEAD — fall back to GET bytes=0-0 probe.
        currentEtag = null;
        currentTotalBytes = -1;
      }
    } catch (e, s) {
      _logError('HEAD revalidate failed, falling back to GET probe', e, s);
    }

    // If HEAD failed to give us etag (server blocks HEAD), try a GET
    // bytes=0-0 probe.
    if (currentEtag == null && currentTotalBytes <= 0) {
      final getRequest = http.Request('GET', Uri.parse(task.url));
      if (task.headers != null) {
        getRequest.headers.addAll(task.headers!);
      }
      getRequest.headers['Range'] = 'bytes=0-0';
      try {
        final getResponse =
            await client.send(getRequest).timeout(probeTimeout);
        try {
          currentEtag =
              getResponse.headers['etag'] ?? getResponse.headers['ETag'];
          currentLastModified =
              getResponse.headers['last-modified'] ??
              getResponse.headers['Last-Modified'];
          if (getResponse.statusCode == 206) {
            final cr = getResponse.headers['content-range'] ??
                getResponse.headers['Content-Range'];
            if (cr != null) {
              final m = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(cr);
              if (m != null) {
                currentTotalBytes = int.tryParse(m.group(1)!) ?? -1;
              }
            }
          } else if (getResponse.statusCode >= 200 &&
              getResponse.statusCode < 300) {
            final cl = getResponse.headers['content-length'] ??
                getResponse.headers['Content-Length'];
            if (cl != null) {
              currentTotalBytes = int.tryParse(cl) ?? -1;
            }
          }
        } finally {
          // Drain (not cancel) so the connection returns to the keep-alive
          // pool — but only when the body is small. If the server ignored
          // the Range header and streamed the whole file, abort instead of
          // downloading it all just to discard it.
          final probeLen = getResponse.contentLength;
          if (getResponse.statusCode == 206 ||
              (probeLen != null && probeLen <= 65536)) {
            try {
              await getResponse.stream.drain<void>();
            } catch (_) {}
          } else {
            try {
              await getResponse.stream.listen((_) {}, onError: (_) {}).cancel();
            } catch (_) {}
          }
        }
      } catch (e, s) {
        _logError('GET revalidate failed, proceeding with stored meta', e, s);
        return; // Cannot validate — trust stored meta and continue.
      }
    }

    // ── Compare and decide ──────────────────────────────────────
    bool changed = false;
    String reason = '';

    if (task.etag != null && currentEtag != null &&
        task.etag != currentEtag) {
      changed = true;
      reason = 'etag changed from "${task.etag}" to "$currentEtag"';
    } else if (task.etag == null && currentEtag != null) {
      // Previously had no etag, now server provides one — store it.
      task.etag = currentEtag;
    } else if (task.etag != null && currentEtag == null) {
      // Resource no longer provides etag — safer to treat as changed.
      changed = true;
      reason = 'server stopped providing etag';
    }

    if (!changed && task.lastModified != null &&
        currentLastModified != null &&
        task.lastModified != currentLastModified) {
      changed = true;
      reason =
          'Last-Modified changed from "${task.lastModified}" to "$currentLastModified"';
    }

    if (!changed && task.etag == null && task.lastModified == null &&
        currentTotalBytes > 0 && task.totalBytes > 0 &&
        currentTotalBytes != task.totalBytes) {
      // No etag or Last-Modified to compare — fall back to content-length
      // as a weak indicator of change.
      changed = true;
      reason =
          'content-length changed from ${task.totalBytes} to $currentTotalBytes';
    }

    if (changed) {
      debugPrint(
        '[DownloadSplitter] Resource changed ($reason) for ${task.url}. '
        'Wiping partials and restarting fresh.',
      );
      debugPrint('Resource changed ($reason). '
        'Wiping partials for ${task.savePath.split("/").last}.');

      // Delete tempDir to discard all partial chunks.
      final dir = Directory(task.tempDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      // Re-probe server and re-initialize chunks from scratch.
      await _probeServerAndInit();
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
      // Reset stall state so retry after a stall actually re-downloads
      // instead of silently no-oping (every chunk checks _stallDetected).
      _stallDetected = false;
      _stallAccumSeconds = 0.0;

      _emitTask();

      try {
        final metaLoaded = await _loadMeta();

        if (metaLoaded) {
          await _revalidateOnResume();
        } else {
          await _probeServerAndInit();
        }

        await _saveMeta();

        if (_isPaused) return;

        _lastBytesTick = task.downloadedBytes;
        _speedTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
          _updateProgress();
          final currentBytes = task.downloadedBytes;
          task.speed = (currentBytes - _lastBytesTick) * 4.0;
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
              isInProgress &&
              _activeNativeChunks.isEmpty) {
            if (task.speed < minSpeedBytesPerSec) {
              _stallAccumSeconds += 0.25;
              if (_stallAccumSeconds >= stallTimeoutSeconds) {
                _stallAccumSeconds = 0.0;
                _handleStall();
                return;
              }
            } else {
              _stallAccumSeconds = 0.0;
            }
          }

          // Diagnostic: track consecutive zero-speed ticks while
          // actively downloading.  Log a warning after 4 ticks (2 s)
          // so we can detect when the Dart event loop is starved by
          // WebView activity (the primary cause of the "0 KB/s on
          // non-Queue tab" symptom).
          if (task.state == DownloadState.downloading && task.speed <= 0) {
            _zeroSpeedTickCount++;
            if (_zeroSpeedTickCount == 4) {
              debugPrint(
                '[DownloadSplitter] ⚠ Speed 0 for ${_zeroSpeedTickCount * 0.25}s '
                'on ${task.savePath.split("/").last} '
                '(downloaded ${task.downloadedBytes}/${task.totalBytes} bytes, '
                '${task.chunks.where((c) => c.isCompleted).length}/${task.chunks.length} chunks complete)',
              );
              debugPrint('Speed 0 for ${_zeroSpeedTickCount * 0.25}s '
                'on ${task.savePath.split("/").last} '
                '(downloaded ${task.downloadedBytes}/${task.totalBytes} bytes, '
                '${task.chunks.where((c) => c.isCompleted).length}/${task.chunks.length} chunks complete)');
            } else if (_zeroSpeedTickCount > 4 && _zeroSpeedTickCount % 10 == 0) {
              // Every 2.5 s after the initial warning
              debugPrint(
                '[DownloadSplitter] ⚠ Speed still 0 after ${_zeroSpeedTickCount * 0.25}s '
                'on ${task.savePath.split("/").last}',
              );
              debugPrint('Speed still 0 after ${_zeroSpeedTickCount * 0.25}s '
                'on ${task.savePath.split("/").last}');
            }
          } else {
            _zeroSpeedTickCount = 0;
          }

          // Every 2 seconds, check for slow chunks to split dynamically.
          final now = DateTime.now();
          if (now.difference(_lastSplitCheck) >= const Duration(seconds: 2)) {
            _lastSplitCheck = now;
            _checkAndSplitSlowChunks();
          }

          _emitTask();
        });

        _activeChunkFutures.clear();
        Object? firstChunkError;
        StackTrace? firstChunkStack;
        for (final chunk in task.chunks) {
          final future = _downloadChunk(chunk);
          // .catchError on each chunk future satisfies test-zone error
          // tracking, preventing spurious [E] failures.  The first error
          // is stored and rethrown by _waitForChunks.
          final safeFuture = future.catchError((Object e, StackTrace s) {
            firstChunkError ??= e;
            firstChunkStack ??= s;
          });
          _activeChunkFutures.add(safeFuture);
          safeFuture.whenComplete(() => _activeChunkFutures.remove(safeFuture));
        }
        await _waitForChunks();
        if (firstChunkError != null) {
          Error.throwWithStackTrace(firstChunkError!, firstChunkStack!);
        }

        if (_isPaused || _stallDetected) return;

        // Update progress/downloaded bytes immediately before run-end checks
        _updateProgress();

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

        // Sort chunks by byte range start for correct merge order.
        // Dynamic chunk splitting can create chunks out of order.
        final sortedChunks = List<DownloadChunk>.from(task.chunks)
          ..sort((a, b) => a.start.compareTo(b.start));
        final chunkFiles = sortedChunks
            .map((c) => File('${task.tempDir}/part_${c.index}'))
            .toList();
        final finalFile = File(task.savePath);

        // Pre-merge validation:
        //   1. Verify completed chunks actually exist and have the expected
        //      size.  A crash / OS cleanup may have truncated the file
        //      after meta.json committed it.  If so, throw so the task
        //      auto-retries (and _downloadChunk's own check re-fetches).
        //   2. Clamp any oversized chunk files to their expected size.
        //      This is a belt-and-suspenders defense: even if a chunk file
        //      somehow grew beyond its range (e.g. server bugs,
        //      206-with-full-body through Content-Range gap), the merge
        //      output will not contain duplicate/corrupt data.
        for (int ci = 0; ci < sortedChunks.length; ci++) {
          final ch = sortedChunks[ci];
          final cf = chunkFiles[ci];

          // Verify completed chunks.
          if (ch.isCompleted && !ch.isOpenEnded && ch.size > 0) {
            if (await cf.exists()) {
              final actualSize = await cf.length();
              if (actualSize < ch.size) {
                throw Exception(
                  'Chunk ${ch.index} is marked completed but file is '
                  '$actualSize bytes (expected ${ch.size}). '
                  'The resource may have changed or the file was truncated. '
                  'Retry will re-download.',
                );
              }
            } else {
              throw Exception(
                'Chunk ${ch.index} is marked completed but chunk file '
                'is missing. Retry will re-download.',
              );
            }
          }

          // Clamp oversized chunks (belt-and-suspenders).
          if (ch.isOpenEnded || ch.size <= 0) continue;
          if (!await cf.exists()) continue;
          final actualSize = await cf.length();
          if (actualSize > ch.size) {
            final raf = await cf.open(mode: FileMode.append);
            await raf.truncate(ch.size);
            await raf.close();
            debugPrint(
              '[DownloadSplitter] Pre-merge clamped chunk ${ch.index} '
              'from $actualSize to ${ch.size} bytes.',
            );
          }
        }

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

        // Remux .ts → .mp4 for direct MPEG-TS downloads.
        final mergedPath = task.savePath;
        if (remuxTsToMp4 && p.extension(mergedPath).toLowerCase() == '.ts') {
          final mp4Path = '${p.withoutExtension(mergedPath)}.mp4';
          task.statusMessage = 'Converting .ts to .mp4 so it plays in any app.';
          task.errorMessage = null;
          _emitTask();
          final remux = await TsRemuxService.remuxTsToMp4(mergedPath, mp4Path);
          if (remux.success) {
            try {
              await File(mergedPath).delete();
            } catch (_) {}
            task.savePath = mp4Path;
            task.statusMessage = null;
            task.errorMessage = null;
          } else {
            debugPrint('TS→MP4 remux failed for ${task.savePath.split("/").last}: '
              '${remux.error ?? "unknown"}');
            task.statusMessage = null;
            task.errorMessage =
                'Couldn\'t convert to .mp4 — keeping original .ts. '
                'Open it in a player that supports MPEG-TS, or re-download. '
                '${remux.error ?? "The stream may use an unsupported codec."}';
          }
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
        final classified = DownloadErrorClassifier.classifyAndMessage(e);
        task.failureReason = classified.reason;
        task.errorMessage = classified.message;
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
        // If meta says completed, verify the on-disk file actually has
        // the expected number of bytes.  A crash or OS cleanup may have
        // truncated the file after meta.json was written.
        if (chunk.isCompleted && chunk.size > 0) {
          if (await chunkFile.exists()) {
            final actualBytes = await chunkFile.length();
            if (actualBytes >= chunk.size) {
              chunk.bytesDownloaded = chunk.size;
              return;
            }
          }
          // File missing or too short — re-download from scratch.
          chunk.isCompleted = false;
          chunk.bytesDownloaded = 0;
          diskBytes = 0;
          if (await chunkFile.exists()) {
            await chunkFile.writeAsBytes([], flush: true);
          }
          debugPrint(
            '[DownloadSplitter] Completed chunk ${chunk.index} is corrupt '
            'or missing re-downloading.',
          );
          // Fall through to the normal download path below.
        } else {
          chunk.bytesDownloaded = chunk.size;
          chunk.isCompleted = true;
          return;
        }
      } else {
        return; // Open-ended chunk, can't validate size.
      }
    }

    final bool rangeSupported = task.chunks.length > 1;
    final int rangeStart = chunk.start + diskBytes;
    final int rangeEnd = chunk.end;

    if (!rangeSupported && diskBytes > 0) {
      await chunkFile.writeAsBytes([]);
      diskBytes = 0;
    }

    // 0th attempt: Native OkHttp engine with HTTP/2, connection pooling,
    // and direct-to-disk streaming.  Avoids the HTTP/1.1 and base64
    // overhead of the Dart HTTP path, and uses a native TLS fingerprint
    // that is less likely to trigger CDN blocks.
    if (!_isPaused && !_stallDetected) {
      final downloadId = '${task.id}_${chunk.index}_${DateTime.now().millisecondsSinceEpoch}';
      _activeNativeChunkIds[chunk.index] = downloadId;
      _activeNativeChunks.add(chunk.index);

      // Race the native download against a per-chunk stall watchdog.
      // The speed-timer stall detector is intentionally disabled while
      // native chunks are active (see _startTask), so a native
      // connection that hangs without ever delivering bytes would
      // otherwise block _waitForChunks forever and the download would
      // never stop. This watchdog aborts a native chunk that makes no
      // forward progress for [stallTimeoutSeconds] and lets us fall
      // through to the Dart HTTP fallback (which resumes from the
      // partial bytes already on disk).
      final nativeCompleter = Completer<NativeChunkResult?>();
      NativeDownloadClient.downloadChunk(
        url: task.url,
        filePath: chunkPath,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        headers: task.headers,
        downloadId: downloadId,
      ).then((r) {
        if (!nativeCompleter.isCompleted) nativeCompleter.complete(r);
      }).catchError((Object e, StackTrace s) {
        if (!nativeCompleter.isCompleted) nativeCompleter.completeError(e, s);
      });

      var lastNativeBytes = diskBytes;
      var nativeStallSeconds = 0.0;
      // Start progress polling + stall watchdog timer every 500ms
      final progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        try {
          if (await chunkFile.exists()) {
            final actualBytes = await chunkFile.length();
            if (actualBytes > chunk.bytesDownloaded) {
              chunk.bytesDownloaded = actualBytes;
              _progressDirty = true;
            }
            // Watchdog: abort a native download that makes no forward
            // progress for stallTimeoutSeconds so we fall through to the
            // Dart HTTP fallback instead of hanging forever on a dead
            // native connection.
            if (actualBytes > lastNativeBytes) {
              lastNativeBytes = actualBytes;
              nativeStallSeconds = 0.0;
            } else {
              nativeStallSeconds += 0.5;
              if (nativeStallSeconds >= stallTimeoutSeconds &&
                  !nativeCompleter.isCompleted) {
                unawaited(NativeDownloadClient.cancelChunk(downloadId));
                nativeCompleter.complete(null);
              }
            }
          }
        } catch (_) {}
      });

      try {
        final nativeResult = await nativeCompleter.future;
        if (nativeResult != null &&
            !nativeResult.cancelled &&
            nativeResult.statusCode >= 200 &&
            nativeResult.statusCode < 300 &&
            nativeResult.bytesWritten > 0) {
          // Native path succeeded — update chunk state directly.
          if (await chunkFile.exists()) {
            final actualBytes = await chunkFile.length();
            diskBytes = actualBytes;
            chunk.bytesDownloaded = actualBytes;
            _progressDirty = true;
            if (!chunk.isOpenEnded && actualBytes >= chunk.size) {
              chunk.isCompleted = true;
            }
          }
          return; // Native path handled this chunk.
        }
        // Native path returned no data or non-2xx — fall through to Dart.
        _logError(
          'Native download returned status ${nativeResult?.statusCode} '
          'bytes=${nativeResult?.bytesWritten} for chunk ${chunk.index}',
          'Falling back to Dart HTTP',
        );
      } catch (e, s) {
        _logError(
          'Native download threw for chunk ${chunk.index}, '
          'falling back to Dart HTTP',
          e,
          s,
        );
      } finally {
        progressTimer.cancel();
        _activeNativeChunks.remove(chunk.index);
        _activeNativeChunkIds.remove(chunk.index);
      }
    }

    // Re-read disk bytes in case the native attempt wrote partial data
    // before we fell through to the Dart HTTP fallback (timeout/stall/
    // cancel/error). The Dart path resumes from this offset via Range.
    if (await chunkFile.exists()) {
      diskBytes = await chunkFile.length();
      chunk.bytesDownloaded = diskBytes;
    }

    // Fallback: Dart HTTP client (with 429/403/401 retry).
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

      // If-Range: when resuming an existing partial chunk, tell the server
      // to only send the range if the resource hasn't changed.  If it has
      // changed, the server will return 200 with the full body (which we
      // handle below by truncating and re-downloading).
      if (diskBytes > 0 && !chunk.isOpenEnded) {
        if (task.etag != null) {
          request.headers['If-Range'] = task.etag!;
        } else if (task.lastModified != null) {
          request.headers['If-Range'] = task.lastModified!;
        }
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
        // Add random jitter of 0-2s to avoid thundering-herd retries.
        final jitterSecs = math.Random().nextInt(3); // 0, 1, or 2
        final wait = Duration(seconds: waitSecs + jitterSecs);
        task.errorMessage =
            'Server asked Aurora to slow down. Waiting ${wait.inSeconds}s '
            'before retry ${attempt + 1} of 3.';
        _emitTask();
        await Future<void>.delayed(wait);
        response = null;
        continue;
      }

      // --- HTTP 403/401: try token refresh once ---
      if (response.statusCode == 403 || response.statusCode == 401) {
        await response.stream.listen((_) {}).cancel();
        if (retriedWithRefresh || task.onTokenExpired == null) {
          // Null the response like the 429 branch does: the consumed
          // stream must never reach the status checks below, which would
          // re-listen it and crash with "Stream has already been listened
          // to" instead of failing with the clean 403/401 error.
          response = null;
          break;
        }
        retriedWithRefresh = true;
        try {
          task.errorMessage = 'Access token expired. Aurora is fetching a fresh one.';
          _emitTask();
          final newUrl = await task.onTokenExpired!(forceReload: false);
          if (newUrl == null || newUrl == task.url) {
            response = null;
            break;
          }
          task.url = newUrl;
          continue;
        } catch (e, s) {
          _logError('Token refresh failed for direct download', e, s);
          response = null;
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
      // Handle resume with If-Range: if the resource changed, the server
      // returns 200 with the full body instead of 206 with the range.
      if (diskBytes > 0 && response.statusCode == 200) {
        await chunkFile.writeAsBytes([], flush: true);
        diskBytes = 0;
        debugPrint(
          '[DownloadSplitter] Resource changed (got 200 instead of 206 '
          'during resume) for chunk ${chunk.index}; '
          'truncated file for fresh re-download.',
        );
      } else if (response.statusCode != 206) {
        await response.stream.listen((_) {}).cancel();
        throw Exception(
          'Server returned status ${response.statusCode} instead of 206 Partial Content',
        );
      }
      // Content-Range verification: when resuming (diskBytes > 0),
      // verify the server actually started at the requested byte offset
      // and didn't send the full body from byte 0 under a 206 status
      // (which would cause the full body to be appended after existing
      // partial data, producing a doubled, corrupt chunk).
      if (diskBytes > 0 && !chunk.isOpenEnded) {
        final contentRange = response.headers['content-range'] ??
            response.headers['Content-Range'];
        if (contentRange != null) {
          final match = RegExp(r'bytes (\d+)-').firstMatch(contentRange);
          if (match != null) {
            final responseStart = int.tryParse(match.group(1)!) ?? -1;
            if (responseStart != rangeStart) {
              if (responseStart == chunk.start) {
                // Server sent the full chunk from byte 0 (ignored our
                // Range header despite returning 206).  Truncate the
                // existing partial file and set diskBytes=0 so the
                // response body (full chunk) is written fresh — do NOT
                // cancel the stream, we will use the full body.
                await chunkFile.writeAsBytes([], flush: true);
                diskBytes = 0;
                debugPrint(
                  '[DownloadSplitter] 206 Content-Range started at '
                  '${chunk.start} instead of $rangeStart for chunk '
                  '${chunk.index}; truncated file for fresh re-download.',
                );
                debugPrint('206 Content-Range started at ${chunk.start} '
                  'instead of $rangeStart for chunk ${chunk.index}; '
                  'truncated file for fresh re-download.');
              } else {
                // Server returned 206 from a completely different
                // offset — cannot safely use this response.
                await response.stream.listen((_) {}).cancel();
                throw Exception(
                  'Server returned 206 with Content-Range starting at '
                  '$responseStart, but expected byte $rangeStart for '
                  'chunk ${chunk.index}. Cannot safely resume.',
                );
              }
            }
          } else {
            // Unparseable Content-Range header — log and proceed
            // with normal append; the merge-time clamping (Fix 2)
            // will reject oversized chunks.
            debugPrint(
              '[DownloadSplitter] Unparseable Content-Range header '
              '"$contentRange" for chunk ${chunk.index}.',
            );
          }
        }
        // No Content-Range header on a 206 — technically malformed,
        // but some CDNs omit it.  Proceed with normal append; the
        // merge-time clamping (Fix 2) catches any resulting oversize.
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
        debugPrint('Open-ended resume returned 200 OK for '
          'chunk ${chunk.index}; truncated file for fresh re-download.');
      }
    }

    // ── Stream-receive with mid-chunk reconnect ───────────────────
    // On stream error/timeout: close subscription, re-read diskBytes,
    // reconnect with updated Range, and continue appending.
    _reconnectAttempts = 0;

    try {
      await _streamAndWriteChunk(
        chunk, chunkFile, response, rangeSupported, rangeStart,
        rangeEnd, diskBytes,
      );
    } finally {
      // Clean up any remaining subscription/sink from reconnect attempts
      // (the helper cleans up after itself on success, but on a final
      // failure the caller handles it via the exception path in start()).
    }
  }

  // ── Mid-chunk reconnect ─────────────────────────────────────────────

  /// Streams the response body to [chunkFile] with automatic mid-stream
  /// reconnect on time-out or network error.
  ///
  /// When a stream error occurs (SocketException, timeout, etc.), this
  /// method re-reads the current file size from disk, reconnects with an
  /// updated `Range` header, and continues appending — exactly like 1DM
  /// does.  Up to [_maxReconnectsPerChunk] reconnects per chunk.
  Future<void> _streamAndWriteChunk(
    DownloadChunk chunk,
    File chunkFile,
    http.StreamedResponse response,
    bool rangeSupported,
    int rangeStart,
    int rangeEnd,
    int diskBytes,
  ) async {
    int reconnectAttempt = _reconnectAttempts;

    // We need mutable references for the loop.
    var currentResponse = response;
    var currentRangeStart = rangeStart;
    var currentDiskBytes = diskBytes;

    while (true) {
      // ── Sink + subscription ──────────────────────────────────
      final sink = chunkFile.openWrite(mode: FileMode.append);
      _sinks.add(sink);

      final completer = Completer<void>();
      _completers.add(completer);
      StreamSubscription<List<int>>? subscription;

      subscription = currentResponse.stream
          .timeout(bodyIdleTimeout)
          .listen(
            (data) {
              if (_isPaused || _stallDetected || completer.isCompleted) return;

              // Global speed limiter gate.
              final limiter = _speedLimiter;
              if (limiter != null && limiter.isActive) {
                if (!limiter.tryConsume(data.length)) {
                  subscription?.pause();
                  limiter.onCapacityAvailable.then((_) {
                    if (!_isPaused &&
                        !_stallDetected &&
                        !completer.isCompleted) {
                      subscription?.resume();
                    }
                  });
                }
              }

              try {
                sink.add(data);
              } catch (e, s) {
                _logError('Failed to write data to sink', e, s);
                return;
              }
              currentDiskBytes += data.length;
              chunk.bytesDownloaded = currentDiskBytes;
              task.downloadedBytes += data.length;
              _progressDirty = true;
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

      bool shouldRetry = false;

      try {
        await completer.future;

        // ── Post-stream validation ──────────────────────────────
        // Clamp oversized chunk to expected size.
        if (!chunk.isOpenEnded && chunk.size > 0) {
          if (!await chunkFile.exists()) {
            currentDiskBytes = 0;
            chunk.bytesDownloaded = 0;
          } else {
            final actualSize = await chunkFile.length();
            if (actualSize > chunk.size) {
              final raf = await chunkFile.open(mode: FileMode.append);
              await raf.truncate(chunk.size);
              await raf.close();
              final excess = actualSize - chunk.size;
              currentDiskBytes = chunk.size;
              chunk.bytesDownloaded = chunk.size;
              task.downloadedBytes -= excess;
              debugPrint(
                '[DownloadSplitter] Clamped oversized chunk ${chunk.index} '
                'from $actualSize to ${chunk.size} bytes (excess $excess).',
              );
              debugPrint('Clamped oversized chunk ${chunk.index} '
                'from $actualSize to ${chunk.size} bytes (excess $excess).');
            }
          }
        }

        if (!_isPaused) {
          if (currentDiskBytes >= chunk.size || chunk.end == -1) {
            if (!(currentDiskBytes == 0 && chunk.end == -1)) {
              chunk.isCompleted = true;
            }
          }
        }

        return; // ── Success ──
      } on TimeoutException {
        shouldRetry = true;
        if (reconnectAttempt >= _maxReconnectsPerChunk || _isPaused || _stallDetected) {
          rethrow;
        }
      } catch (_) {
        shouldRetry = true;
        if (reconnectAttempt >= _maxReconnectsPerChunk || _isPaused || _stallDetected) {
          rethrow;
        }
      } finally {
        _subscriptions.remove(subscription);
        _sinks.remove(sink);
        _completers.remove(completer);
        if (!shouldRetry) {
          await sink.close();
        } else {
          // Close the old sink silently (don't await — we'll re-open).
          try {
            await sink.close();
          } catch (_) {}
        }
      }

      // ── Reconnect ────────────────────────────────────────────────
      if (!shouldRetry) return;
      reconnectAttempt++;
      _reconnectAttempts = reconnectAttempt;

      // Early pause check before any delay or network I/O.
      if (_isPaused || _stallDetected) {
        throw StateError('Download paused/stalled during reconnect');
      }

      // Re-read disk bytes from what was actually written.
      if (await chunkFile.exists()) {
        currentDiskBytes = await chunkFile.length();
        chunk.bytesDownloaded = currentDiskBytes;
      }

      debugPrint(
        '[DownloadSplitter] Reconnect attempt $reconnectAttempt '
        'for chunk ${chunk.index} at byte $currentDiskBytes '
        '(range ${chunk.start + currentDiskBytes}-${chunk.end}).',
      );

      // Exponential backoff: 200ms, 400ms, 800ms, 1.6s, 3.2s
      // Check pause every 100ms so pause never waits more than ~100ms.
      final totalDelay = (200 * (1 << (reconnectAttempt - 1))).clamp(200, 4000);
      var waited = 0;
      while (waited < totalDelay) {
        if (_isPaused || _stallDetected) {
          throw StateError('Download paused/stalled during reconnect');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waited += 100;
      }

      // Re-open the HTTP connection with updated Range.
      final reconnectRequest = http.Request('GET', Uri.parse(task.url));
      if (task.headers != null) {
        reconnectRequest.headers.addAll(task.headers!);
      }
      if (rangeSupported) {
        currentRangeStart = chunk.start + currentDiskBytes;
        reconnectRequest.headers['Range'] =
            'bytes=$currentRangeStart-${chunk.end}';
      }
      currentResponse = await client
          .send(reconnectRequest)
          .timeout(responseTimeout);

      if (_isPaused || _stallDetected) {
        await currentResponse.stream.listen((_) {}).cancel();
        throw StateError('Download paused/stalled during reconnect');
      }

      if (currentResponse.statusCode == 206 || currentResponse.statusCode == 200) {
        if (rangeSupported && currentResponse.statusCode != 206) {
          // Server ignored our Range — can't resume safely.
          throw Exception(
            'Reconnect: server returned ${currentResponse.statusCode} '
            'instead of 206 for chunk ${chunk.index}. Cannot resume.',
          );
        }
        // Continue the loop to write this new response.
      } else {
        await currentResponse.stream.listen((_) {}).cancel();
        throw Exception(
          'Reconnect: server returned status ${currentResponse.statusCode} '
          'for chunk ${chunk.index}.',
        );
      }

      // Loop to create a new sink + subscription for this response.
    }
  }

  // ── Dynamic chunk splitting ─────────────────────────────────────────

  /// Awaits all active chunk downloads, including any chunks that are
  /// dynamically added by [_splitChunk] during the download.
  ///
  /// Loops, re-snapshotting [_activeChunkFutures] each pass, until the
  /// set is empty — so child chunks created by slow-chunk splitting are
  /// awaited before the caller's completion check runs.
  /// Errors are handled upstream via [catchError] on each chunk future
  /// (registered in [start]), so this method only needs to wait for
  /// completion — it does NOT need to propagate errors itself.
  Future<void> _waitForChunks() async {
    // Loop until no active chunk futures remain.  Chunks can be added
    // dynamically by [_splitChunk] (slow-chunk splitting) while we wait,
    // so we must re-snapshot and re-wait rather than awaiting a single
    // fixed snapshot — otherwise the completion check in [start] would
    // observe an incomplete child chunk and fail the download spuriously
    // ("not all chunks completed").
    while (_activeChunkFutures.isNotEmpty) {
      final futures = List<Future<void>>.from(_activeChunkFutures);
      await Future.wait(futures);
    }
  }

  /// Checks each active (non-completed) chunk for slow speed and splits
  /// chunks that are significantly slower than the average.
  ///
  /// Called every 2 seconds from the speed timer.
  void _checkAndSplitSlowChunks() {
    if (_isPaused || _stallDetected) return;
    if (_splitsRemaining <= 0) return;
    if (task.chunks.length >= 32) return; // Cap fragmentation.

    // Compute average delta for active chunks.
    int totalDelta = 0;
    int activeCount = 0;
    for (final chunk in task.chunks) {
      if (chunk.isCompleted || chunk.isOpenEnded) continue;
      final prev = _lastChunkBytes[chunk.index] ?? chunk.bytesDownloaded;
      totalDelta += chunk.bytesDownloaded - prev;
      activeCount++;
      _lastChunkBytes[chunk.index] = chunk.bytesDownloaded;
    }
    if (activeCount <= 1 || totalDelta <= 0) return;
    final avgDelta = totalDelta ~/ activeCount;

    for (final chunk in task.chunks) {
      if (chunk.isCompleted || chunk.isOpenEnded) continue;
      final prev = _lastChunkBytes[chunk.index] ?? chunk.bytesDownloaded;
      final delta = chunk.bytesDownloaded - prev;
      final remaining = chunk.size - chunk.bytesDownloaded;

      // Slow if less than 50% of average AND at least 2 MB remaining.
      if (delta < avgDelta * 0.5 && remaining > 2 * 1024 * 1024) {
        final count = (_slowChunkSampleCount[chunk.index] ?? 0) + 1;
        _slowChunkSampleCount[chunk.index] = count;
        if (count >= 3) {
          // 3 consecutive slow samples (6 seconds) → split.
          _splitChunk(chunk);
          _slowChunkSampleCount[chunk.index] = 0;
        }
      } else {
        _slowChunkSampleCount[chunk.index] = 0;
      }
    }
  }

  /// Splits [slowChunk] into two chunks at the midpoint of its remaining
  /// byte range.  The original chunk is shrunk; a new child chunk is
  /// created for the second half and starts downloading immediately.
  void _splitChunk(DownloadChunk slowChunk) {
    if (_isPaused || _stallDetected) return;
    if (_splitsRemaining <= 0) return;

    final remaining = slowChunk.size - slowChunk.bytesDownloaded;
    if (remaining <= 2 * 1024 * 1024) return; // Not worth splitting.

    // Find the next unused index.
    final usedIndices = task.chunks.map((c) => c.index).toSet();
    var newIndex = 0;
    while (usedIndices.contains(newIndex)) newIndex++;

    // Split at the midpoint of the remaining range.
    final splitPoint = slowChunk.end - (remaining ~/ 2);

    // Create the new child chunk.
    final newChunk = DownloadChunk(
      index: newIndex,
      start: splitPoint + 1,
      end: slowChunk.end,
      splitFromIndex: slowChunk.index,
    );

    // Shrink the original chunk.
    slowChunk.end = splitPoint;

    task.chunks.add(newChunk);
    _splitsRemaining--;

    // Record the initial byte position for the new chunk.
    _lastChunkBytes[newChunk.index] = 0;

    debugPrint(
      '[DownloadSplitter] Split chunk ${slowChunk.index} at byte $splitPoint '
      '→ chunk $newIndex (${newChunk.size} bytes). '
      '$_splitsRemaining splits remaining.',
    );

    // Start the new chunk download and track its future.
    final newFuture = _downloadChunk(newChunk);
    _activeChunkFutures.add(newFuture);
    newFuture.whenComplete(() => _activeChunkFutures.remove(newFuture));
  }

  void _updateProgress() {
    if (!_progressDirty) return;
    _progressDirty = false;
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

    // Cancel active native downloads
    if (_activeNativeChunkIds.isNotEmpty) {
      final ids = List<String>.from(_activeNativeChunkIds.values);
      for (final id in ids) {
        unawaited(NativeDownloadClient.cancelChunk(id));
      }
      _activeNativeChunkIds.clear();
      _activeNativeChunks.clear();
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

    // Cancel active native downloads
    if (_activeNativeChunkIds.isNotEmpty) {
      final ids = List<String>.from(_activeNativeChunkIds.values);
      for (final id in ids) {
        unawaited(NativeDownloadClient.cancelChunk(id));
      }
      _activeNativeChunkIds.clear();
      _activeNativeChunks.clear();
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
        task.failureReason = DownloadFailure.partialDownload;
        task.errorMessage =
            'Download stopped at ${pct}%. '
            'Try Force Merge to save what downloaded so far.';
        _emitTask();
        return;
      }
    }

    task.failureReason = DownloadFailure.speedStall;
    task.errorMessage =
        'Speed dropped below $thresholdKbps KB/s. '
        'Aurora is retrying the download.';
    // Complete all active chunk completers so Future.wait() unblocks
    for (final completer in List<Completer<void>>.from(_completers)) {
      if (!completer.isCompleted) completer.complete();
    }
    _emitTask();
  }
}


