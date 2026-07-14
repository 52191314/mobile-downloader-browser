import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'speed_limiter.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import '../logging/aurora_log.dart';
import 'hls_decryptor.dart';
import 'hls_models.dart';
import 'hls_playlist_parser.dart';
import '../platform/network_binding_service.dart';
import '../platform/ts_remux_service.dart';
import 'headless_webview_fetcher.dart';
import 'download_error_classifier.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  final message = '[HlsDownloader] $context: $error';
  debugPrint(message);
  print(message); // Also emit via print() which always reaches logcat
  AuroraLog.instance.error(
    message,
    category: LogCategory.hls,
    screen: LogScreen.background,
    eventType: LogEventType.error,
    stackTrace: stack,
  );
}

class HlsDownloader implements BaseDownloader {
  final DownloadTask task;
  final http.Client client;
  final bool _ownsClient;
  final int maxConcurrentSegments;
  final int maxSegmentProbeConcurrency;

  /// Optional global speed limiter injected by [DownloadQueue].
  final SpeedLimiter? _speedLimiter;

  bool _isPaused = false;
  bool _isRetry = false;
  bool _needsRefresh = false;
  final Set<int> _staleSegmentIndexes = {};
  final Set<int> _countedSegmentIndexes = {};
  /// True when [_probeSegmentSizes] determined the total size before
  /// downloading segments.  Prevents per-segment accumulation from
  /// overwriting the pre-calculated total (which would make progress
  /// track downloaded bytes 1:1 and always show ~100%).
  bool _totalBytesLocked = false;
  HlsPlaylist? _playlist;
  Uint8List? _encryptionKeyBytes;
  String _currentPlaylistUrl = '';

  /// Circuit breaker: counts consecutive segment download failures
  /// (403/401/timeout).  After [_maxConsecutiveFailures] in a row,
  /// the downloader aborts immediately to avoid hammering the CDN
  /// and triggering a Cloudflare IP block.
  int _consecutiveSegmentFailures = 0;
  static const int _maxConsecutiveFailures = 5;
  bool _hostBlocked = false;

  /// Headless WebView fallback for CDN hosts that block both Dart HTTP
  /// (Cloudflare TLS fingerprint) and cross-origin XHR from the main
  /// WebView (CORS).  Lazily initialized on first need.
  HeadlessWebViewFetcher? _headlessFetcher;


  Timer? _speedTimer;
  int _lastBytesTick = 0;
  /// Diagnostic: counts consecutive 500ms ticks where speed was 0 while
  /// the task is in downloading state.  Reset to 0 whenever data flows.
  int _zeroSpeedTickCount = 0;
  final StreamController<DownloadTask> _taskUpdateController =
      StreamController<DownloadTask>.broadcast();

  HlsDownloader({
    required this.task,
    http.Client? client,
    this.maxConcurrentSegments = 4,
    this.maxSegmentProbeConcurrency = 10,
    SpeedLimiter? speedLimiter,
  }) : _ownsClient = client == null,
       client = client ?? http.Client(),
       _speedLimiter = speedLimiter;

  @override
  Stream<DownloadTask> get onTaskUpdated => _taskUpdateController.stream;

  @override
  Future<void> start() async {
    _isPaused = false;
    _hostBlocked = false;
    _consecutiveSegmentFailures = 0;

    task.state = DownloadState.downloading;
    task.errorMessage = null;

    // Detect resume: if tempDir has existing segment files, treat as retry
    // so we skip already-downloaded segments instead of wiping them.
    if (!_isRetry) {
      final tempDir = Directory(task.tempDir);
      if (await tempDir.exists()) {
        final files = await tempDir.list().toList();
        final segmentFiles =
            files.where((e) => e.path.contains('segment_')).toList();
        if (segmentFiles.isNotEmpty) {
          _isRetry = true;
          // Immediately compute downloadedBytes from existing segment file
          // sizes so the UI shows correct progress before the segment-skip
          // logic in _downloadSegments() runs (which recomputes from valid
          // segments only).
          int totalBytes = 0;
          for (final entity in segmentFiles) {
            if (entity is File) {
              try {
                totalBytes += await entity.length();
              } catch (_) {}
            }
          }
          task.downloadedBytes = totalBytes;
          AuroraLog.instance.info(
            'Resume detected: ${segmentFiles.length} segment files '
            '(${(totalBytes / 1048576).toStringAsFixed(1)} MB) in ${task.tempDir}',
            category: LogCategory.hls,
            eventType: LogEventType.stateChange,
            taskId: task.id,
          );
        } else {
          AuroraLog.instance.info(
            'No segment files in ${task.tempDir} '
            '(${files.length} other files) — fresh start',
            category: LogCategory.hls,
            eventType: LogEventType.stateChange,
            taskId: task.id,
          );
        }
      } else {
        AuroraLog.instance.info(
          'tempDir does not exist: ${task.tempDir} — fresh start',
          category: LogCategory.hls,
          eventType: LogEventType.stateChange,
          taskId: task.id,
        );
      }
    }

    // On retry, preserve already-downloaded bytes so we don't
    // re-download successfully fetched segments from scratch.
    // On a fresh start, reset to zero.
    if (!_isRetry) {
      task.downloadedBytes = 0;
    }
    if (task.totalBytes > 0) {
      // Size already determined (previous run or sniffer estimate) — keep it.
      _totalBytesLocked = true;
    } else {
      task.totalBytes = -1;
      _totalBytesLocked = false;
    }
    _countedSegmentIndexes.clear();
    _taskUpdateController.add(task);

    try {
      _currentPlaylistUrl = task.url;
      HlsPlaylist playlist;
      try {
        playlist = await _loadMediaPlaylist(Uri.parse(_currentPlaylistUrl));
      } catch (initialError) {
        // Playlist fetch failed — surface the real error so the user
        // can tell whether it's 403/404/timeout vs a token issue.
        _logError('Initial playlist fetch failed', initialError);
        // If the server told us to try a different URL (e.g. CDN
        // returned a redirect to a fresh token), use it.
        String detail = initialError.toString();
        final match = RegExp(r'status (\d{3})').firstMatch(detail);
        final code = match?.group(1);
        if (task.onTokenExpired != null) {
          try {
            task.errorMessage =
                'Server returned ${code ?? "error"}, refreshing…';
            _taskUpdateController.add(task);
            final newUrl = await task.onTokenExpired!(forceReload: false);
            if (newUrl != null && newUrl != _currentPlaylistUrl) {
              _currentPlaylistUrl = newUrl;
              playlist = await _loadMediaPlaylist(Uri.parse(newUrl));
            } else {
              rethrow;
            }
          } catch (refreshError, refreshStack) {
            _logError(
              'Refresh-after-failure also failed',
              refreshError,
              refreshStack,
            );
            throw StateError(
              'HLS download failed ($detail). '
              'Token refresh also failed: $refreshError',
            );
          }
        } else {
          throw StateError(
            'HLS download failed: $detail. '
            'Re-sniff the link from the page.',
          );
        }
      }
      _assertSupported(playlist);
      if (playlist.segments.isEmpty) {
        throw StateError('HLS playlist did not contain any media segments.');
      }
      _playlist = playlist;
      try {
        _encryptionKeyBytes = await _loadEncryptionKey(playlist);
      } catch (keyError) {
        if (task.onTokenExpired != null) {
          final detail = keyError.toString();
          final match = RegExp(r'status (\d{3})').firstMatch(detail);
          final code = match?.group(1);
          task.errorMessage = 'Key fetch failed (${code ?? "error"}), refreshing…';
          _taskUpdateController.add(task);
          final newUrl = await task.onTokenExpired!(forceReload: false);
          if (newUrl != null && newUrl != _currentPlaylistUrl) {
            _currentPlaylistUrl = newUrl;
            playlist = await _loadMediaPlaylist(Uri.parse(newUrl));
            _playlist = playlist;
            _encryptionKeyBytes = await _loadEncryptionKey(playlist);
          } else {
            rethrow;
          }
        } else {
          rethrow;
        }
      }

      await _probeSegmentSizes(playlist);

      final tempDir = Directory(task.tempDir);
      if (!_isRetry) {
        // On a fresh start (not a retry), wipe the temp dir.
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }

      _lastBytesTick = task.downloadedBytes;
      _zeroSpeedTickCount = 0;
      debugPrint(
        '[HlsDownloader] Starting speed timer for ${task.savePath.split("/").last} '
        '(url=${task.url.length > 80 ? "${task.url.substring(0, 80)}..." : task.url})',
      );
      _speedTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        final currentBytes = task.downloadedBytes;
        task.speed = (currentBytes - _lastBytesTick) * 2.0;
        _lastBytesTick = currentBytes;

        // Diagnostic: track consecutive zero-speed ticks while
        // actively downloading.  Log a warning after 4 ticks (2 s)
        // so we can detect when the Dart event loop is starved by
        // WebView activity (the primary cause of the "0 KB/s on
        // non-Queue tab" symptom).
        if (task.state == DownloadState.downloading && task.speed <= 0) {
          _zeroSpeedTickCount++;
          if (_zeroSpeedTickCount == 4) {
            debugPrint(
              '[HlsDownloader] ⚠ Speed 0 for ${_zeroSpeedTickCount * 0.5}s '
              'on ${task.savePath.split("/").last} '
              '(downloaded ${task.downloadedBytes}/${task.totalBytes} bytes)',
            );
            AuroraLog.instance.warn(
              'Speed 0 for ${_zeroSpeedTickCount * 0.5}s '
              'on ${task.savePath.split("/").last} '
              '(downloaded ${task.downloadedBytes}/${task.totalBytes} bytes)',
              category: LogCategory.hls,
              screen: LogScreen.background,
              eventType: LogEventType.network,
              taskId: task.id,
            );
          } else if (_zeroSpeedTickCount > 4 && _zeroSpeedTickCount % 10 == 0) {
            // Every 5 s after the initial warning
            debugPrint(
              '[HlsDownloader] ⚠ Speed still 0 after ${_zeroSpeedTickCount * 0.5}s '
              'on ${task.savePath.split("/").last}',
            );
            AuroraLog.instance.warn(
              'Speed still 0 after ${_zeroSpeedTickCount * 0.5}s '
              'on ${task.savePath.split("/").last}',
              category: LogCategory.hls,
              screen: LogScreen.background,
              eventType: LogEventType.network,
              taskId: task.id,
            );
          }
        } else {
          _zeroSpeedTickCount = 0;
        }

        _taskUpdateController.add(task);
      });

      var partFiles = await _downloadSegments(playlist);
      if (_needsRefresh && _staleSegmentIndexes.isNotEmpty) {
        // CDN rejected segments (401/403) — try to get a fresh token.
        // Up to 2 refresh attempts; on each attempt, only re-download the
        // stale segments instead of the whole playlist.
        for (
          int attempt = 0;
          attempt < 2 && _needsRefresh && !_isPaused;
          attempt++
        ) {
          if (task.onTokenExpired == null) break;
          task.errorMessage = attempt == 0
              ? 'Token expired, refreshing...'
              : 'Still expired, refreshing again...';
          _taskUpdateController.add(task);
          final newUrl = await task.onTokenExpired!(forceReload: attempt > 0);
          if (newUrl == null || newUrl == _currentPlaylistUrl) break;
          try {
            _currentPlaylistUrl = newUrl;
            _playlist = await _loadMediaPlaylist(Uri.parse(newUrl));
            _encryptionKeyBytes = await _loadEncryptionKey(_playlist!);
          } catch (e, s) {
            _logError('Refresh produced an invalid playlist', e, s);
            break;
          }
          _needsRefresh = false;
          final staleSnapshot = Set<int>.from(_staleSegmentIndexes);
          _staleSegmentIndexes.clear();
          await _redownloadStaleSegments(_playlist!, partFiles, staleSnapshot);
        }
        if (_needsRefresh && _staleSegmentIndexes.isNotEmpty) {
          task.failureReason = DownloadFailure.hlsTokenExpired;
          task.errorMessage =
              'Token refresh failed — the stream URL may have expired. Re-sniff from the page.';
          _taskUpdateController.add(task);
        }
      }
      if (_isPaused) return;
      await _mergeSegments(partFiles, isFmp4: playlist.hasFmp4);
      if (_isPaused || task.state == DownloadState.failed) return;

      // Remux TS → MP4 for MPEG-TS streams (no transcoding, just container change).
      // fMP4 streams already produce .mp4; audio-only produces .m4a. Only MPEG-TS
      // needs the remux step.
      final mergedPath = task.savePath;
      if (_playlist != null &&
          !_isAudioOnlyPlaylist(_playlist!) &&
          !playlist.hasFmp4 &&
          p.extension(mergedPath).toLowerCase() == '.ts') {
        final mp4Path = '${p.withoutExtension(mergedPath)}.mp4';
        task.errorMessage = 'Converting to MP4...';
        _taskUpdateController.add(task);
        final remux = await TsRemuxService.remuxTsToMp4(mergedPath, mp4Path);
        if (remux.success) {
          try {
            File(mergedPath).delete();
          } catch (_) {}
          task.savePath = mp4Path;
          task.errorMessage = null;
        } else {
          AuroraLog.instance.error(
            'TS→MP4 remux failed for ${task.savePath.split("/").last}: '
            '${remux.error ?? "unknown"}',
            category: LogCategory.hls,
            screen: LogScreen.background,
            eventType: LogEventType.error,
            taskId: task.id,
          );
          task.errorMessage = 'Could not convert to MP4 (kept as .ts). '
              '${remux.error ?? "The stream may use an unsupported codec."}';
        }
      }

      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      task.totalBytes = math.max(task.totalBytes, task.downloadedBytes);
      task.state = DownloadState.completed;
      _taskUpdateController.add(task);
    } catch (error) {
      if (_isPaused) return;
      task.state = DownloadState.failed;
      final classified = DownloadErrorClassifier.classifyAndMessage(error);
      task.failureReason = classified.reason;
      task.errorMessage = classified.message;
      _taskUpdateController.add(task);
      rethrow;
    } finally {
      _isRetry = false;
      _speedTimer?.cancel();
      task.speed = 0;
      _taskUpdateController.add(task);
    }
  }

  Future<void> _probeSegmentSizes(HlsPlaylist playlist) async {
    // 0. Skip if total is already locked (previous run or sniffer estimate)
    if (_totalBytesLocked && task.totalBytes > 0) {
      return;
    }

    // 1. Skip if resuming
    if (task.downloadedBytes > 0) {
      return;
    }

    // 2. Skip if live
    if (playlist.isLive) {
      task.totalBytes = -1;
      _taskUpdateController.add(task);
      return;
    }

    // 3. Byte-range fast path
    final brSize = playlist.totalByteRangeLength;
    if (brSize != null && brSize > 0) {
      task.totalBytes = brSize;
      _totalBytesLocked = true;
      _taskUpdateController.add(task);
      return;
    }

    // 4. HEAD probe phase
    task.errorMessage = 'Calculating size…';
    _taskUpdateController.add(task);

    // Collect all unique segment URIs + init segment URI
    final uris = <Uri>[];
    if (playlist.initSegmentUri != null) {
      uris.add(playlist.initSegmentUri!);
    }
    for (final segment in playlist.segments) {
      uris.add(segment.uri);
    }

    if (uris.isEmpty) {
      task.totalBytes = -1;
      task.errorMessage = null;
      _taskUpdateController.add(task);
      return;
    }

    // A. Send test HEAD request to first URI to see if HEAD is supported
    bool headSupported = false;
    try {
      final testUri = uris.first;
      final request = http.Request('HEAD', testUri);
      if (task.headers != null) {
        request.headers.addAll(task.headers!);
      }
      final response = await client.send(request).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final len = response.contentLength;
        if (len != null && len > 0) {
          headSupported = true;
        }
      }
    } catch (_) {}

    if (!headSupported) {
      AuroraLog.instance.debug('HEAD request not supported by server/CDN, falling back to indeterminate mode.', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
      // Preserve the sniffer's estimated totalBytes if one was carried over
      // from SniffedMedia.contentLengthBytes (e.g. segment-sampling estimate).
      if (task.totalBytes > 0) {
        _totalBytesLocked = true;
      } else {
        task.totalBytes = -1;
      }
      task.errorMessage = null;
      _taskUpdateController.add(task);
      return;

    }

    // B. Concurrency-limited probe worker pool
    int totalSize = 0;
    int index = 0;
    final maxConcurrency = maxSegmentProbeConcurrency;

    Future<void> worker() async {
      while (true) {
        if (_isPaused) break;
        int currentIndex;
        if (index >= uris.length) break;
        currentIndex = index++;

        final uri = uris[currentIndex];
        try {
          final request = http.Request('HEAD', uri);
          if (task.headers != null) {
            request.headers.addAll(task.headers!);
          }
          final response = await client.send(request).timeout(const Duration(seconds: 4));
          if (response.statusCode == 200) {
            final len = response.contentLength;
            if (len != null && len > 0) {
              totalSize += len;
            }
          }
        } catch (_) {
          // Ignore individual segment probe failures
        }
      }
    }

    final workers = List.generate(
      math.min(maxConcurrency, uris.length),
      (_) => worker(),
    );
    await Future.wait(workers);

    if (!_isPaused) {
      if (totalSize > 0) {
        task.totalBytes = totalSize;
        _totalBytesLocked = true;
      } else {
        task.totalBytes = -1;
      }
    }

    task.errorMessage = null;
    _taskUpdateController.add(task);
  }

  @override
  Future<void> pause({DownloadState targetState = DownloadState.paused}) async {
    _isPaused = true;
    task.state = targetState;
    task.speed = 0;
    _speedTimer?.cancel();
    _taskUpdateController.add(task);
  }

  /// Retry the download by first asking the sniffer for a fresh URL, then
  /// re-running start() with that URL. If no fresh URL is obtained, just
  /// re-runs start() with the original URL.
  Future<void> retryWithRefresh({bool forceReload = false}) async {
    if (task.onTokenExpired != null) {
      task.errorMessage = 'Refreshing from page...';
      _taskUpdateController.add(task);
      final newUrl = await task.onTokenExpired!(forceReload: forceReload);
      if (newUrl != null && newUrl != task.url) {
        task.url = newUrl;
        _currentPlaylistUrl = newUrl;
        // URL changed — full restart is needed since old segments are stale.
        _isRetry = false;
        // Wipe stale segments from the old URL so the resume-detection
        // in start() doesn't mistake them for valid segments.
        try {
          final oldTempDir = Directory(task.tempDir);
          if (await oldTempDir.exists()) {
            await oldTempDir.delete(recursive: true);
          }
        } catch (_) {}
      } else {
        _isRetry = true;
      }
    } else {
      _isRetry = true;
    }
    task.state = DownloadState.idle;
    task.errorMessage = null;
    // Reset progress — on retry, valid existing segments are counted
    // during the skip check in _downloadSegments.
    task.downloadedBytes = 0;
    // Clean up stale completed files at savePath from a prior attempt
    // (the new merge may produce a different extension).
    try {
      final saveDir = File(task.savePath).parent;
      final baseName = p.basenameWithoutExtension(task.savePath);
      if (await saveDir.exists()) {
        await for (final entity in saveDir.list()) {
          if (entity is File &&
              p.basenameWithoutExtension(entity.path) == baseName) {
            await entity.delete();
          }
        }
      }
    } catch (_) {
      // Non-fatal — merge will overwrite via openWrite() anyway.
    }
    if (task.totalBytes > 0) {
      _totalBytesLocked = true;
    } else {
      task.totalBytes = -1;
      _totalBytesLocked = false;
    }
    _hostBlocked = false;
    _consecutiveSegmentFailures = 0;
    _needsRefresh = false;
    _staleSegmentIndexes.clear();
    _countedSegmentIndexes.clear();
    _taskUpdateController.add(task);
    await start();
  }

  Future<void> cancel() async {
    _isPaused = true;
    _isRetry = false;
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
    task.totalBytes = -1;
    _taskUpdateController.add(task);
  }

  @override
  Future<void> dispose() async {
    await pause(targetState: task.state);
    await _headlessFetcher?.dispose();
    _headlessFetcher = null;
    if (_ownsClient) {
      client.close();
    }
    if (!_taskUpdateController.isClosed) {
      await _taskUpdateController.close();
    }
  }

  Future<HlsPlaylist> _loadMediaPlaylist(Uri uri) async {
    final first = await _fetchPlaylist(uri);
    if (!first.isMaster) return first;
    final variants = [...first.variants]
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return _fetchPlaylist(variants.first.uri);
  }

  static const _defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// Returns the headers to use for this playlist request.  If the task has
  /// null or empty headers (e.g. the user pasted the URL manually), builds a
  /// browser-like default set keyed on the URL's own origin.  This prevents
  /// Cloudflare WAF (which blocks bare Dart HTTP requests) and surrit.com's
  /// CDN (which requires a same-origin Referer) from returning 403.
  Map<String, String> _requestHeaders(Uri uri) {
    if (task.headers != null && task.headers!.isNotEmpty) {
      return task.headers!;
    }
    final origin = '${uri.scheme}://${uri.host}';
    final h = <String, String>{
      'User-Agent': _defaultUserAgent,
      'Referer': '$origin/',
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Origin': origin,
      'Accept-Encoding': 'gzip, deflate, br',
    };
    return h;
  }

  Future<HlsPlaylist> _fetchPlaylist(Uri uri) async {
    // 0th attempt: cached HLS playlist body from browser_guard.js capture.
    // When the browser page loaded, browser_guard.js intercepted the fetch/XHR
    // for this .m3u8 URL and cached the response body.  Using it here avoids
    // any network request — no Cloudflare WAF, no cookie mismatch, no 403.
    if (task.hlsPlaylistCache != null) {
      final urlStr = uri.toString();
      final cached = task.hlsPlaylistCache!(urlStr);
      if (cached != null && cached.isNotEmpty) {
        AuroraLog.instance.debug('Using cached HLS playlist body for $uri (${cached.length} chars)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
        return HlsPlaylistParser.parse(cached, uri);
      }
      AuroraLog.instance.debug('Cache MISS for $urlStr (hlsPlaylistCache is set but returned null)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
    } else {
      AuroraLog.instance.debug('hlsPlaylistCache is null (task not created from browser tab)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
    }

    var headers = _requestHeaders(uri);
    AuroraLog.instance.debug('_fetchPlaylist uri=$uri headers_count=${headers.length}', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);

    // 1st attempt: WebView JS fetch() when available — this is the ONLY
    // path that sees Cloudflare clearance cookies because it runs inside
    // the WebView's browser context and uses the raw UA that earned the
    // cf_clearance token.  Skip the Dart HTTP client entirely when we
    // have a WebView bridge so we don't waste retries on a path known
    // to fail for Cloudflare-protected hosts.
    if (task.fetchViaWebView != null) {
      try {
        final jsBody = await task.fetchViaWebView!(uri.toString(), headers: headers)
            .timeout(const Duration(seconds: 15));
        if (jsBody != null && jsBody.isNotEmpty) {
          AuroraLog.instance.debug('WebView JS fetch succeeded for $uri (${jsBody.length} chars)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
          return HlsPlaylistParser.parse(jsBody, uri);
        }
        AuroraLog.instance.debug('WebView JS fetch returned null/empty', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
      } catch (e) {
        AuroraLog.instance.debug('WebView JS fetch threw: $e', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
        _logError('WebView JS fetch threw', e);
      }
    } else {
      AuroraLog.instance.debug('fetchViaWebView is null (no WebView context)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
    }

    // 2nd attempt: Dart HTTP client.
    AuroraLog.instance.debug('Trying Dart HTTP client for $uri', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
    // Inject Cloudflare cookies for the Dart HTTP fallback.
    if (task.cookieProvider != null) {
      try {
        final cookieHeaders = await task.cookieProvider!(uri.toString());
        if (cookieHeaders.isNotEmpty) {
          headers = {...headers, ...cookieHeaders};
        }
      } catch (_) {}
    }
    final response = await client
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return HlsPlaylistParser.parse(response.body, uri);
    }
    AuroraLog.instance.debug('Dart client returned ${response.statusCode}', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
    var lastErrorDetail = 'Dart:${response.statusCode}';

    // 3rd attempt: Android native HttpURLConnection.
    try {
      final nativeResult = await NetworkBindingService.fetchUrl(
        uri.toString(),
        headers: headers,
      );
      if (nativeResult != null) {
        final sc = nativeResult['statusCode'] as int? ?? 0;
        final body = nativeResult['body'] as String? ?? '';
        lastErrorDetail += ' Native:$sc';
        if (sc >= 200 && sc < 300 && body.isNotEmpty) {
          AuroraLog.instance.debug('Native HTTP fallback succeeded for $uri (status $sc)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
          return HlsPlaylistParser.parse(body, uri);
        }
      } else {
        lastErrorDetail += ' Native:null';
      }
    } catch (e) {
      lastErrorDetail += ' Native:throw($e)';
      _logError('Native HTTP fallback threw', e);
    }

    AuroraLog.instance.debug('All fetch attempts failed for $uri. Detail: $lastErrorDetail', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
    throw HttpException(
      'HLS playlist request failed (403). Fallback results: $lastErrorDetail',
      uri: uri,
    );
  }

  void _assertSupported(HlsPlaylist playlist) {
    if (playlist.hasEncryption && playlist.encryptionKey?.isAes128 != true) {
      final method = playlist.encryptionKey?.method ?? 'unknown';
      throw UnsupportedError(
        'HLS encryption method "$method" is not supported. Only AES-128 is supported.',
      );
    }
  }

  Future<Uint8List?> _loadEncryptionKey(HlsPlaylist playlist) async {
    final key = playlist.encryptionKey;
    if (key == null || !key.isAes128) return null;

    // 1st attempt: WebView binary fetch (bypasses Cloudflare WAF).
    if (task.fetchBinaryViaWebView != null) {
      try {
        final data = await task.fetchBinaryViaWebView!(key.uri.toString())
            .timeout(const Duration(seconds: 15));
        if (data != null && data.length == 16) {
          AuroraLog.instance.debug('WebView binary fetch key OK (16 bytes)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
          return Uint8List.fromList(data);
        }
      } catch (e) {
        AuroraLog.instance.debug('WebView binary fetch key threw: $e', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
      }
    }

    // 2nd attempt: Dart HTTP client.
    final request = http.Request('GET', key.uri);
    request.headers.addAll(_requestHeaders(key.uri));
    if (task.cookieProvider != null) {
      try {
        final cookieHeaders = await task.cookieProvider!(key.uri.toString());
        if (cookieHeaders.isNotEmpty) {
          request.headers.addAll(cookieHeaders);
        }
      } catch (_) {}
    }
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final bodyPreview = response.contentLength == 0
          ? ''
          : '(body unavailable)';
      _logError(
        'HLS key request failed: status ${response.statusCode} $bodyPreview',
        '',
      );
      throw HttpException(
        'HLS key request failed with status ${response.statusCode}',
        uri: key.uri,
      );
    }
    final bytes = await response.stream.toBytes();
    if (bytes.length != 16) {
      throw StateError(
        'AES-128 key must be exactly 16 bytes, got ${bytes.length}',
      );
    }
    return bytes;
  }

  Uint8List _buildAesIv(
    HlsEncryptionKey? key,
    int segmentIndex,
    int mediaSequence,
  ) {
    if (key?.iv != null) return key!.iv!;
    final sequenceNumber = segmentIndex + mediaSequence;
    final iv = Uint8List(16);
    final buffer = ByteData.view(iv.buffer);
    buffer.setUint64(8, sequenceNumber);
    return iv;
  }



  Future<List<File>> _downloadSegments(HlsPlaylist playlist) async {
    final segments = playlist.segments;
    final initUri = playlist.initSegmentUri;
    final hasInit = initUri != null;
    final totalCount = segments.length + (hasInit ? 1 : 0);
    final files = List<File?>.filled(totalCount, null);

    // Reset downloadedBytes so the segment-skip logic below recomputes
    // from valid segments only (the initial value from the resume
    // detection was a quick sum without validity checking).
    if (_isRetry) {
      task.downloadedBytes = 0;
    }

    // Circuit breaker: if host was already blocked, don't attempt any segments.
    if (_hostBlocked) {
      throw StateError(
        'Download aborted: CDN blocked access. '
        'Wait a few minutes and re-sniff from the video page.',
      );
    }

    if (hasInit) {
      files[0] = await _downloadSegment(0, initUri, isInit: true);
    }

    var nextSegIndex = 0;
    final workerCount = math.max(
      1,
      math.min(maxConcurrentSegments, segments.length),
    );

    Future<void> worker() async {
      while (!_isPaused && !_hostBlocked) {
        final segIndex = nextSegIndex;
        nextSegIndex++;
        if (segIndex >= segments.length) return;

        final fileIndex = hasInit ? segIndex + 1 : segIndex;

        // On retry, check if this segment already exists on disk.
        if (_isRetry) {
          final uri = segments[segIndex].uri;
          final ext = uri.path.toLowerCase().endsWith('.m4s') ? 'm4s' : 'ts';
          final isInitSeg = hasInit && segIndex == 0;
          final existing = File(
            '${task.tempDir}/segment_${fileIndex.toString().padLeft(6, '0')}.$ext',
          );
          if (await existing.exists()) {
            final size = await existing.length();
            if (size > 0 &&
                await _isSegmentValid(existing, ext, isInitSeg)) {
              files[fileIndex] = existing;
              task.downloadedBytes += size;
              AuroraLog.instance.debug(
                'Seg $segIndex skipped ($size bytes)',
                category: LogCategory.hls,
                eventType: LogEventType.network,
                taskId: task.id,
              );
              continue; // Valid segment — already downloaded and decrypted.
            }
            // Invalid (likely pre-fix encrypted) — delete and re-download.
            AuroraLog.instance.info(
              'Seg $segIndex invalid — re-downloading',
              category: LogCategory.hls,
              eventType: LogEventType.network,
              taskId: task.id,
            );
            try {
              await existing.delete();
            } catch (_) {}
          }
        }

        files[fileIndex] = await _downloadSegment(
          fileIndex,
          segments[segIndex].uri,
          segmentIndex: segIndex,
        );
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    // Replace any null entries with stub files so _mergeSegments can
    // detect and report failed segments instead of crashing with a cast error.
    for (int i = 0; i < files.length; i++) {
      if (files[i] == null) {
        final stub = File('${task.tempDir}/stub_$i');
        if (!await stub.exists()) {
          await stub.writeAsString('');
        }
        files[i] = stub;
      }
    }
    return List<File>.from(files);
  }

  /// Re-download only the segments in [staleIndexes] from a refreshed
  /// playlist and replace their entries in [files]. Bounded concurrency so
  /// we don't hammer the CDN after a token refresh.
  Future<void> _redownloadStaleSegments(
    HlsPlaylist playlist,
    List<File> files,
    Set<int> staleIndexes,
  ) async {
    if (staleIndexes.isEmpty) return;
    final hasInit = playlist.initSegmentUri != null;
    final sorted = staleIndexes.toList()..sort();

    Future<void> downloadOne(int fileIndex) async {
      if (_isPaused) return;
      final segIndex = hasInit ? fileIndex - 1 : fileIndex;
      if (segIndex < 0 || segIndex >= playlist.segments.length) return;
      try {
        final newFile = await _downloadSegment(
          fileIndex,
          playlist.segments[segIndex].uri,
          segmentIndex: segIndex,
        );
        // Clean up the old stub if it's a different file
        final old = files[fileIndex];
        if (old.path != newFile.path) {
          try {
            if (await old.exists()) await old.delete();
          } catch (_) {}
        }
        files[fileIndex] = newFile;
      } catch (e, s) {
        _logError('Stale segment re-download failed', e, s);
      }
    }

    final workerCount = math.max(
      1,
      math.min(maxConcurrentSegments, sorted.length),
    );
    final queue = List<int>.from(sorted);
    Future<void> worker() async {
      while (!_isPaused && queue.isNotEmpty) {
        final idx = queue.removeAt(0);
        await downloadOne(idx);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<File> _downloadSegment(
    int index,
    Uri uri, {
    bool isInit = false,
    int segmentIndex = -1,
  }) async {
    // 0th attempt: WebView binary fetch (bypasses Cloudflare WAF).
    if (task.fetchBinaryViaWebView != null) {
      try {
        final data = await task.fetchBinaryViaWebView!(uri.toString())
            .timeout(const Duration(seconds: 30));
        if (data != null && data.isNotEmpty) {
          final ext = isInit
              ? 'mp4'
              : (uri.path.toLowerCase().endsWith('.m4s') ? 'm4s' : 'ts');
          final finalPath =
              '${task.tempDir}/segment_${index.toString().padLeft(6, '0')}.$ext';
          final partPath = '$finalPath.part';
          final partFile = File(partPath);
          await partFile.parent.create(recursive: true);
          // Speed limiter gate (WebView fallback path).
          final limiter = _speedLimiter;
          if (limiter != null && limiter.isActive) {
            while (!limiter.tryConsume(data.length)) {
              await limiter.onCapacityAvailable;
              if (_isPaused) break;
            }
          }
          if (!_isPaused) {
            await partFile.writeAsBytes(data);
          }
          // Decrypt before rename — if decryption fails the .part
          // file is left behind and the segment will be re-downloaded.
          final keyBytes = _encryptionKeyBytes;
          if (!isInit && keyBytes != null && segmentIndex >= 0) {
            final iv = _buildAesIv(
              _playlist?.encryptionKey,
              segmentIndex,
              _playlist?.mediaSequence ?? 0,
            );
            await HlsDecryptor.decryptInPlace(partFile, keyBytes, iv);
          }
          // Rename .part to final only after successful write + decrypt.
          await partFile.rename(finalPath);
          final file = File(finalPath);
          if (!_totalBytesLocked &&
              !isInit &&
              !_countedSegmentIndexes.contains(index)) {
            _countedSegmentIndexes.add(index);
            if (task.totalBytes < 0) task.totalBytes = 0;
            task.totalBytes += data.length;
          }
          task.downloadedBytes += data.length;
          if (task.totalBytes > 0 && task.downloadedBytes > task.totalBytes) {
            task.totalBytes = task.downloadedBytes;
          }
          _taskUpdateController.add(task);
          _consecutiveSegmentFailures = 0; // Circuit breaker reset
          AuroraLog.instance.debug('WebView binary fetch segment $index OK (${data.length} bytes)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
          return file;
        }
      } catch (e) {
        AuroraLog.instance.debug('WebView binary fetch segment $index threw: $e', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
      }
    }

    // 1st fallback: headless WebView (before Dart HTTP). The headless
    // WebView creates its own Chromium TLS session on the CDN's domain,
    // which bypasses Cloudflare TLS fingerprint detection that blocks
    // Dart's TLS stack even when valid cookies are sent.
    if (!_isPaused && !_hostBlocked) {
      try {
        _headlessFetcher ??= HeadlessWebViewFetcher();
        final data = await _headlessFetcher!.fetchBinary(uri.toString())
            .timeout(const Duration(seconds: 30));
        if (data != null && data.isNotEmpty) {
          final ext = isInit
              ? 'mp4'
              : (uri.path.toLowerCase().endsWith('.m4s') ? 'm4s' : 'ts');
          final finalPath =
              '${task.tempDir}/segment_${index.toString().padLeft(6, '0')}.$ext';
          final partPath = '$finalPath.part';
          final partFile = File(partPath);
          await partFile.parent.create(recursive: true);
          // Speed limiter gate (headless WebView path).
          final limiter = _speedLimiter;
          if (limiter != null && limiter.isActive) {
            while (!limiter.tryConsume(data.length)) {
              await limiter.onCapacityAvailable;
              if (_isPaused) break;
            }
          }
          if (!_isPaused) {
            await partFile.writeAsBytes(data);
          }
          if (!_totalBytesLocked &&
              !isInit &&
              !_countedSegmentIndexes.contains(index)) {
            _countedSegmentIndexes.add(index);
            if (task.totalBytes < 0) task.totalBytes = 0;
            task.totalBytes += data.length;
          }
          task.downloadedBytes += data.length;
          if (task.totalBytes > 0 && task.downloadedBytes > task.totalBytes) {
            task.totalBytes = task.downloadedBytes;
          }
          _taskUpdateController.add(task);
          _consecutiveSegmentFailures = 0;

          // Decrypt before rename — if decryption fails the .part
          // file is left behind and the segment will be re-downloaded.
          final keyBytes = _encryptionKeyBytes;
          if (!isInit && keyBytes != null && segmentIndex >= 0) {
            final iv = _buildAesIv(
              _playlist?.encryptionKey,
              segmentIndex,
              _playlist?.mediaSequence ?? 0,
            );
            await HlsDecryptor.decryptInPlace(partFile, keyBytes, iv);
          }
          // Rename .part to final only after successful write + decrypt.
          await partFile.rename(finalPath);
          final hlFile = File(finalPath);
          AuroraLog.instance.debug(
            'Headless WebView fetched segment $index OK (${data.length} bytes)',
            category: LogCategory.hls,
            screen: LogScreen.background,
            eventType: LogEventType.network,
          );
          return hlFile;
        }
      } catch (e) {
        AuroraLog.instance.debug(
          'Headless WebView fallback failed for segment $index: $e',
          category: LogCategory.hls,
          screen: LogScreen.background,
          eventType: LogEventType.network,
        );
      }
    }

    // Circuit breaker: if host is already blocked, don't even try HTTP.
    if (_hostBlocked) {
      final file = File('${task.tempDir}/stub_$index');
      await file.writeAsString('');
      return file;
    }

    const maxRetries = 5;
    var attempt = 0;

    while (true) {
      attempt++;
      try {
        final request = http.Request('GET', uri);
        request.headers.addAll(_requestHeaders(uri));
        // Inject Cloudflare cf_clearance and session cookies from the
        // WebView cookie jar so the HTTP fallback doesn't get 403'd
        // when the WebView XHR path fails (cross-origin or timeout).
        if (task.cookieProvider != null) {
          try {
            final cookieHeaders = await task.cookieProvider!(uri.toString());
            if (cookieHeaders.isNotEmpty) {
              request.headers.addAll(cookieHeaders);
            }
          } catch (e) {
            AuroraLog.instance.debug('cookieProvider threw for segment $index: $e', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
          }
        }
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
        AuroraLog.instance.debug('HTTP segment $index: status ${response.statusCode} (attempt $attempt)', category: LogCategory.hls, screen: LogScreen.background, eventType: LogEventType.network);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Drain the error/response body to free the connection.
          // Use onError to prevent unhandled stream errors if the
          // connection is reset while draining.
          await response.stream.listen((_) {}, onError: (_) {}).cancel();
          if (response.statusCode == 403 || response.statusCode == 401) {
            // Circuit breaker: track consecutive 403/401 failures.
            // After too many in a row, abort to avoid triggering a
            // Cloudflare IP block from hammering the CDN.
            _consecutiveSegmentFailures++;
            if (_consecutiveSegmentFailures >= _maxConsecutiveFailures &&
                !_hostBlocked) {
              _hostBlocked = true;
              task.state = DownloadState.failed;
              task.failureReason = DownloadFailure.hlsCircuitBreaker;
              task.errorMessage =
                  'Server blocked access ($_consecutiveSegmentFailures consecutive 403s). '
                  'The CDN may have rate-limited or blocked this device. '
                  'Wait a few minutes and try again, or re-sniff from the video page.';
              _taskUpdateController.add(task);
              AuroraLog.instance.error(
                'Circuit breaker tripped: $_consecutiveSegmentFailures consecutive 403/401 failures — aborting to prevent Cloudflare IP block',
                category: LogCategory.hls,
                screen: LogScreen.background,
                eventType: LogEventType.error,
                taskId: task.id,
              );
              final file = File('${task.tempDir}/stub_$index');
              await file.writeAsString('');
              return file;
            }

            _needsRefresh = true;
            _staleSegmentIndexes.add(index);
            task.state = DownloadState.downloading;
            task.errorMessage = 'Token expired, refreshing...';
            _taskUpdateController.add(task);
            // Return a dummy file — the merge step will detect it as a
            // stub and refuse to produce a partial/corrupt file.
            final file = File('${task.tempDir}/stub_$index');
            await file.writeAsString('');
            return file;
          }
          throw HttpException(
            'HLS segment request failed with status ${response.statusCode}',
            uri: uri,
          );
        }

        final contentLength = response.contentLength;
        if (!_totalBytesLocked &&
            contentLength != null &&
            contentLength > 0 &&
            !isInit &&
            !_countedSegmentIndexes.contains(index)) {
          _countedSegmentIndexes.add(index);
          if (task.totalBytes < 0) task.totalBytes = 0;
          task.totalBytes += contentLength;
        }

        final ext = isInit
            ? 'mp4'
            : (uri.path.toLowerCase().endsWith('.m4s') ? 'm4s' : 'ts');
        final finalPath =
            '${task.tempDir}/segment_${index.toString().padLeft(6, '0')}.$ext';
        final partPath = '$finalPath.part';
        final partFile = File(partPath);
        await partFile.parent.create(recursive: true);
        final sink = partFile.openWrite();
        var bytesDownloadedInThisAttempt = 0;
        try {
          await for (final chunk in response.stream) {
            if (_isPaused) break;

            // Global speed limiter gate.
            final limiter = _speedLimiter;
            if (limiter != null && limiter.isActive) {
              while (!limiter.tryConsume(chunk.length)) {
                await limiter.onCapacityAvailable;
                if (_isPaused) break;
              }
              if (_isPaused) break;
            }

            sink.add(chunk);
            bytesDownloadedInThisAttempt += chunk.length;
            task.downloadedBytes += chunk.length;
            if (task.totalBytes > 0 && task.downloadedBytes > task.totalBytes) {
              task.totalBytes = task.downloadedBytes;
            }
          }
        } catch (e) {
          task.downloadedBytes -= bytesDownloadedInThisAttempt;
          rethrow;
        } finally {
          await sink.close();
        }

        // Decrypt AES-128-CBC segments after download.
        // If the segment was truncated by a pause, skip decryption — it would
        // fail on incomplete data and trigger a confusing error cascade.
        if (_isPaused) {
          // Leave the .part file on disk — it will be overwritten on
          // resume/retry (the retry-skip check looks for the final name,
          // not .part, so this segment will be re-downloaded).
          return partFile;
        }
        _consecutiveSegmentFailures = 0; // Circuit breaker reset on success

        final keyBytes = _encryptionKeyBytes;
        if (!isInit && keyBytes != null && segmentIndex >= 0) {
          try {
            final iv = _buildAesIv(
              _playlist?.encryptionKey,
              segmentIndex,
              _playlist?.mediaSequence ?? 0,
            );
            await HlsDecryptor.decryptInPlace(partFile, keyBytes, iv);
          } catch (e, s) {
            _logError('Segment decryption failed', e, s);
            // Delete the .part file so retry does a fresh download.
            try {
              await partFile.delete();
            } catch (_) {}
            throw StateError(
              'HLS segment decryption failed: $e. '
              'The key may have expired or the stream uses an unsupported cipher.',
            );
          }
        }
        // Rename .part to final only after successful write + decrypt.
        await partFile.rename(finalPath);
        final file = File(finalPath);
        return file;
      } catch (error) {
        if (attempt >= maxRetries || _isPaused) {
          final msg = error.toString().toLowerCase();
          if (error is SocketException ||
              msg.contains('socketexception') ||
              msg.contains('failed host lookup') ||
              msg.contains('no address associated with hostname')) {
            throw StateError(
              'HLS download failed: Could not reach the video server (${uri.host}). '
              'The stream token may have expired. '
              'Please go back to the video page and re-sniff the link.',
            );
          }

          // All attempts exhausted — rethrow the original error.
          rethrow;
        }
        // Wait before retrying (exponential backoff: 1s, 2s, 4s...)
        final backoffMs = math.pow(2, attempt) * 500;
        await Future.delayed(Duration(milliseconds: backoffMs.toInt()));
      }
    }
  }

  bool _isAudioOnlyPlaylist(HlsPlaylist playlist) {
    final url = playlist.uri.toString().toLowerCase();
    if (url.contains('/a1/') ||
        url.contains('_a1.') ||
        url.contains('/audio') ||
        url.contains('/audio_only')) {
      return true;
    }
    if (playlist.segments.isNotEmpty &&
        playlist.segments.every(
          (s) => s.uri.path.toLowerCase().endsWith('.aac'),
        )) {
      return true;
    }
    return false;
  }

  /// Quickly validates that a downloaded segment file contains decrypted
  /// media data (not AES-128-CBC ciphertext). Encrypted segments fail
  /// this check and are re-downloaded on retry.
  ///
  /// - `.ts` (MPEG-TS): checks for the 0x47 sync byte at offset 0 and 188.
  /// - `.m4s` / init (fMP4): checks for a valid ISO BMFF box type.
  Future<bool> _isSegmentValid(File file, String ext, bool isInit) async {
    try {
      final raf = await file.open(mode: FileMode.read);
      final bytes = await raf.read(376); // 2 TS packets
      await raf.close();
      if (bytes.length < 8) return false;
      if (ext == 'ts') {
        // MPEG-TS sync byte 0x47 at offset 0 and every 188 bytes.
        return bytes[0] == 0x47 &&
            (bytes.length < 188 || bytes[188] == 0x47);
      }
      // fMP4 / init: check for a known ISO BMFF box type.
      final type = String.fromCharCodes(bytes.sublist(4, 8));
      return ['ftyp', 'styp', 'moof', 'mdat', 'free', 'skip', 'sidx',
              'moov', 'mvhd', 'trak', 'mdia', 'minf', 'stbl', 'dinf',
              'edts', 'mvex', 'trex', 'emsg', 'saiz', 'saio', 'tenc',
              'uuid', 'pssh', 'prft']
          .contains(type);
    } catch (_) {
      return false;
    }
  }

  Future<void> _mergeSegments(List<File> files, {bool isFmp4 = false}) async {
    final currentExt = p.extension(task.savePath).toLowerCase();

    String finalPath = task.savePath;
    if (_playlist != null && _isAudioOnlyPlaylist(_playlist!)) {
      // Audio-only HLS — wrap AAC in .m4a container label
      if (currentExt != '.m4a') {
        finalPath = '${p.withoutExtension(task.savePath)}.m4a';
      }
    } else if (isFmp4 && currentExt != '.mp4') {
      finalPath = '${p.withoutExtension(task.savePath)}.mp4';
    } else if (!isFmp4 && currentExt != '.ts') {
      finalPath = '${p.withoutExtension(task.savePath)}.ts';
    }

    // Count how many segment files are empty or are 403/401 stubs.
    // We refuse to merge if ANY non-init segment is missing/empty — a
    // partial merge produces a corrupt file that looks "completed" to
    // the user, which is worse than a clear failure.
    final hasInit = _playlist?.initSegmentUri != null;
    final initIndex = hasInit ? 0 : -1;
    var emptyOrStubCount = 0;
    var segmentCount = 0;
    final stubIndexes = <int>[];
    final segmentLengths = await Future.wait(
      List.generate(files.length, (i) => files[i].length()),
    );
    for (int i = 0; i < files.length; i++) {
      if (i == initIndex) continue;
      segmentCount++;
      final isStub = files[i].path.contains(RegExp(r'[/\\]stub_\d+$'));
      final length = segmentLengths[i];
      if (isStub || length == 0) {
        emptyOrStubCount++;
        stubIndexes.add(i);
      }
    }

    if (segmentCount > 0 && emptyOrStubCount > 0) {
      // Clean up the destination if it already exists and throw so the
      // start() catch block marks the task as failed.
      final dest = File(finalPath);
      if (await dest.exists()) {
        try {
          await dest.delete();
        } catch (_) {}
      }
      if (emptyOrStubCount == segmentCount) {
        throw StateError(
          'All $segmentCount segments failed (403/401). '
          'The video token has expired — re-sniff the link from the page.',
        );
      } else {
        throw StateError(
          '$emptyOrStubCount of $segmentCount segments failed (403/401). '
          'Partial downloads are not merged. Re-sniff the link from the page.',
        );
      }
    }

    final destination = File(finalPath);
    final parent = destination.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final sink = destination.openWrite();
    var totalMerged = 0;
    try {
      for (final file in files) {
        if (_isPaused) break;
        final length = await file.length();
        if (length == 0) continue;
        await sink.addStream(file.openRead());
        totalMerged += length;
      }
    } finally {
      await sink.close();
    }
    task.savePath = finalPath;

    if (totalMerged == 0) {
      // Belt-and-braces: if we somehow got here with zero bytes merged,
      // delete the empty destination and throw.
      if (await destination.exists()) {
        try {
          await destination.delete();
        } catch (_) {}
      }
      throw StateError(
        'HLS merge produced 0 bytes. The stream URL has likely expired.',
      );
    }
  }

}
