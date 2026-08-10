import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'speed_limiter.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'hls_decrypt_pool.dart';
import 'hls_models.dart';
import 'hls_playlist_parser.dart';
import 'hls_size_estimator.dart';
import '../platform/network_binding_service.dart';
import '../platform/ts_remux_service.dart';
import 'headless_webview_fetcher.dart';
import 'download_error_classifier.dart';
import 'hls_playlist_fetch_limiter.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  final message = '[HlsDownloader] $context: $error';
  debugPrint(message);
  print(message); // Also emit via print() which always reaches logcat
  debugPrint(message);
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

  /// True when total size was determined before (or refined during)
  /// segment download. Prevents naive per-segment accumulation from
  /// making progress always show ~100%.
  bool _totalBytesLocked = false;

  /// Exact byte-range sum — never refine downward except at completion.
  bool _totalBytesExact = false;

  /// Sampled / bandwidth estimate — progressively refined as segments finish.
  bool _totalBytesEstimated = false;
  final List<int> _completedSegSizes = [];
  double _completedSegDurationSec = 0;
  int _completedSegCount = 0;
  int _initSegmentBytes = 0;

  /// First locked estimate (sniffer or sample probe). Progressive refine is
  /// lightly guided by this — never used as a hard ceiling once real
  /// downloaded bytes exceed it (that caused "100% · 5 GB / 377 MB").
  int _initialSizeEstimate = 0;

  /// When true, [task.downloadedBytes] was already seeded from on-disk
  /// segment files at resume — skip paths must not `+=` those sizes again.
  bool _resumeDiskBytesSeeded = false;
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

  /// After repeated HTTP 403/401 on a WAF host, skip Dart HTTP entirely and
  /// rely on native / WebView / headless. Hammering 403s trips the circuit
  /// breaker and can get the device IP banned by Cloudflare.
  bool _skipHttpFallback = false;
  int _httpForbiddenStreak = 0;

  /// After repeated native HttpURLConnection 403s, skip native segment path
  /// and fall back to WebView/headless (slower but CF-clearance capable).
  bool _skipNativeSegment = false;
  int _nativeForbiddenStreak = 0;

  Timer? _speedTimer;
  int _lastBytesTick = 0;

  /// Diagnostic: counts consecutive 500ms ticks where speed was 0 while
  /// the task is in downloading state.  Reset to 0 whenever data flows.
  int _zeroSpeedTickCount = 0;
  final StreamController<DownloadTask> _taskUpdateController =
      StreamController<DownloadTask>.broadcast();

  /// When true, MPEG-TS merge output is remuxed to MP4 after completion.
  /// fMP4 and audio-only playlists never remux regardless of this flag.
  ///
  /// Remux uses MediaExtractor→MediaMuxer with **PTS rewriting**: plain
  /// byte-concat of HLS .ts segments leaves discontinuous timestamps, which
  /// otherwise become multi-minute freezes (last frame + silence) in HW
  /// players after a naive remux.
  final bool remuxTsToMp4;

  HlsDownloader({
    required this.task,
    http.Client? client,
    this.maxConcurrentSegments = 4,
    this.maxSegmentProbeConcurrency = 10,
    this.remuxTsToMp4 = true,
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
    _skipHttpFallback = false;
    _httpForbiddenStreak = 0;

    // Detect resume: if tempDir has existing segment files, treat as retry
    // so we skip already-downloaded segments instead of wiping them.
    _resumeDiskBytesSeeded = false;
    if (!_isRetry) {
      // Directory listing + per-file stat runs on a background isolate so a
      // ~500-segment resume never blocks the UI isolate on ~1000 file ops.
      final scan = await _scanResumeSegments(task.tempDir);
      if (scan != null) {
        final segmentSizes = scan.segmentSizes;
        // Only finished segments (not `.part` partials).
        if (segmentSizes.isNotEmpty) {
          _isRetry = true;
          // Seed downloadedBytes once from disk. Skip-logic must NOT add
          // those sizes again (that caused multi-GB "100%" with a small
          // estimated total still showing).
          int diskBytes = 0;
          for (final size in segmentSizes.values) {
            diskBytes += size;
          }
          task.downloadedBytes = diskBytes;
          _resumeDiskBytesSeeded = true;
          debugPrint(
            'Resume detected: ${segmentSizes.length} segment files '
            '(${(diskBytes / 1048576).toStringAsFixed(1)} MB) in ${task.tempDir}',
          );
        } else {
          debugPrint(
            'No segment files in ${task.tempDir} '
            '(${scan.entryCount} other files) — fresh start',
          );
        }
      } else {
        debugPrint('tempDir does not exist: ${task.tempDir} — fresh start');
      }
    }

    // On retry, keep seeded/restored downloadedBytes. Fresh start → zero.
    if (!_isRetry) {
      task.downloadedBytes = 0;
      task.completedParts = 0;
      task.totalParts = 0;
      _resumeDiskBytesSeeded = false;
    }
    if (task.totalBytes > 0) {
      // Size already determined (previous run or sniffer estimate) — keep it
      // and refine as real segments complete unless we already know exact.
      _totalBytesLocked = true;
      if (!_totalBytesExact) _totalBytesEstimated = true;
    } else {
      task.totalBytes = -1;
      _totalBytesLocked = false;
      _totalBytesExact = false;
      _totalBytesEstimated = false;
    }
    if (!_isRetry) {
      _completedSegSizes.clear();
      _completedSegDurationSec = 0;
      _completedSegCount = 0;
      _initSegmentBytes = 0;
      _totalBytesExact = false;
      _initialSizeEstimate = task.totalBytes > 0 ? task.totalBytes : 0;
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
                'Server responded with ${code ?? "an error"}. Aurora is refreshing the link.';
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
          task.errorMessage =
              'Couldn\'t fetch encryption key (${code ?? "error"}). Aurora is refreshing the link.';
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
            debugPrint(
              'Speed 0 for ${_zeroSpeedTickCount * 0.5}s '
              'on ${task.savePath.split("/").last} '
              '(downloaded ${task.downloadedBytes}/${task.totalBytes} bytes)',
            );
          } else if (_zeroSpeedTickCount > 4 && _zeroSpeedTickCount % 10 == 0) {
            // Every 5 s after the initial warning
            debugPrint(
              '[HlsDownloader] ⚠ Speed still 0 after ${_zeroSpeedTickCount * 0.5}s '
              'on ${task.savePath.split("/").last}',
            );
            debugPrint(
              'Speed still 0 after ${_zeroSpeedTickCount * 0.5}s '
              'on ${task.savePath.split("/").last}',
            );
          }
        } else {
          _zeroSpeedTickCount = 0;
        }

        _taskUpdateController.add(task);
      });

      // Prewarm the persistent decryption pool so the first encrypted
      // segment doesn't stall on one-shot isolate creation (and so the AES
      // key schedule is cached across segments of this playlist). Size the
      // pool to the effective segment concurrency so fast connections don't
      // serialize downloads through the decrypt workers.
      HlsDecryptPool.instance.poolSize = maxConcurrentSegments.clamp(2, 6);
      unawaited(HlsDecryptPool.instance.ensureInitialized());

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
              ? 'Access token expired. Aurora is fetching a fresh one.'
              : 'Token still expired. Aurora is trying again with a fresh reload.';
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
              'Token refresh didn\'t work. The stream URL may have expired. Re-sniff from the page.';
          _taskUpdateController.add(task);
        }
      }
      if (_isPaused) return;
      await _mergeSegments(partFiles, isFmp4: playlist.hasFmp4);
      if (_isPaused || task.state == DownloadState.failed) return;

      // Remux TS → MP4 for MPEG-TS streams (no transcoding, just container change).
      // fMP4 streams already produce .mp4; audio-only produces .m4a. Only MPEG-TS
      // needs the remux step — and only when the setting allows it.
      final mergedPath = task.savePath;
      if (remuxTsToMp4 &&
          _playlist != null &&
          !_isAudioOnlyPlaylist(_playlist!) &&
          !playlist.hasFmp4 &&
          p.extension(mergedPath).toLowerCase() == '.ts') {
        final mp4Path = '${p.withoutExtension(mergedPath)}.mp4';
        task.statusMessage = 'Converting .ts to .mp4 so it plays in any app.';
        task.errorMessage = null;
        _taskUpdateController.add(task);
        final remux = await TsRemuxService.remuxTsToMp4(mergedPath, mp4Path);
        if (remux.success) {
          try {
            await File(mergedPath).delete();
          } catch (_) {}
          task.savePath = mp4Path;
          task.statusMessage = null;
          task.errorMessage = null;
        } else {
          debugPrint(
            'TS→MP4 remux failed for ${task.savePath.split("/").last}: '
            '${remux.error ?? "unknown"}',
          );
          task.statusMessage = null;
          task.errorMessage =
              'Couldn\'t convert to .mp4 — keeping original .ts. '
              'Open it in a player that supports MPEG-TS, or re-download. '
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
    // Skip if we already have an exact size from a prior run.
    if (_totalBytesExact && task.totalBytes > 0) return;

    // On resume, keep prior estimate and refine as segments complete.
    if (task.downloadedBytes > 0) {
      if (task.totalBytes > 0) {
        _totalBytesEstimated = true;
        _totalBytesLocked = true;
      }
      return;
    }

    if (playlist.isLive) {
      task.totalBytes = -1;
      _totalBytesLocked = false;
      _totalBytesExact = false;
      _totalBytesEstimated = false;
      _taskUpdateController.add(task);
      return;
    }

    // Exact byte-range sum (best case — no network).
    final brSize = playlist.totalByteRangeLength;
    if (brSize != null && brSize > 0) {
      int initBytes = 0;
      if (playlist.initSegmentUri != null) {
        initBytes = await _probeUriContentLength(playlist.initSegmentUri!) ?? 0;
        _initSegmentBytes = initBytes;
      }
      task.totalBytes = brSize + initBytes;
      _totalBytesExact = true;
      _totalBytesEstimated = false;
      _totalBytesLocked = true;
      debugPrint(
        'HLS size exact from byte-ranges: ${task.totalBytes}B '
        '(${playlist.segments.length} segs + init=$initBytes)',
      );
      _taskUpdateController.add(task);
      return;
    }

    final segs = playlist.segments;
    if (segs.isEmpty) {
      task.totalBytes = -1;
      _taskUpdateController.add(task);
      return;
    }

    task.statusMessage = 'Estimating total size from sample segments.';
    _taskUpdateController.add(task);

    // Probe init segment once (not multiplied).
    int initBytes = 0;
    if (playlist.initSegmentUri != null) {
      initBytes = await _probeUriContentLength(playlist.initSegmentUri!) ?? 0;
      _initSegmentBytes = initBytes;
    }

    // Strategic sample — never HEAD every segment (slow + rate-limit risk).
    final indices = HlsSizeEstimator.selectSampleIndices(
      segs.length,
      maxSamples: math.min(8, segs.length),
    );

    final samples = <HlsSizeSample>[];
    var next = 0;
    final concurrency = math.min(4, indices.length);

    Future<void> worker() async {
      while (!_isPaused) {
        final i = next++;
        if (i >= indices.length) break;
        final segIndex = indices[i];
        final seg = segs[segIndex];
        final size = await _probeUriContentLength(seg.uri);
        if (size != null &&
            size >= HlsSizeEstimator.minSegmentBytes &&
            size <= HlsSizeEstimator.maxSegmentBytes) {
          samples.add(
            HlsSizeSample(
              index: segIndex,
              bytes: size,
              durationSeconds: seg.durationSeconds,
            ),
          );
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));

    // Prefer playlist BANDWIDTH if the media playlist carried it via
    // a prior master selection — stored on task via sniffer totalBytes
    // fallback. Bandwidth from playlist variants isn't on media playlist;
    // use sniffer estimate as bandwidthDuration fallback only if samples fail.
    final estimate = HlsSizeEstimator.estimate(
      playlist: playlist,
      samples: samples,
      initSegmentBytes: initBytes,
    );

    if (!_isPaused) {
      if (estimate.totalBytes != null && estimate.totalBytes! > 0) {
        final snifferBytes = task.totalBytes;
        var chosen = estimate.totalBytes!;
        // If sniffer and sample disagree by >2×, prefer the more conservative
        // (lower) estimate — inflated Content-Lengths on sample HEADs are a
        // common CDN quirk and caused multi‑GB queue totals vs ~1GB capture.
        if (snifferBytes > 0 &&
            estimate.isEstimated &&
            (chosen > snifferBytes * 2 || snifferBytes > chosen * 2)) {
          chosen = math.min(chosen, snifferBytes);
          debugPrint(
            'HLS size sample/sniffer disagree '
            '(sample=$chosen sniffer=$snifferBytes) — using lower',
          );
          // recompute with min already assigned
          chosen = math.min(estimate.totalBytes!, snifferBytes);
        }
        task.totalBytes = chosen;
        _totalBytesExact =
            estimate.source == HlsSizeEstimateSource.byteRangeExact;
        _totalBytesEstimated = estimate.isEstimated;
        _totalBytesLocked = true;
        _initialSizeEstimate = chosen;
        debugPrint(
          'HLS size estimate: ${task.totalBytes}B via ${estimate.source.name} '
          '(${estimate.detail}, samples=${samples.length}/${segs.length})',
        );
      } else if (task.totalBytes > 0) {
        // Keep sniffer-provided estimate (bandwidth×duration or enricher sample).
        _totalBytesEstimated = true;
        _totalBytesLocked = true;
        _initialSizeEstimate = task.totalBytes;
        debugPrint('HLS size preserving sniffer estimate: ${task.totalBytes}B');
      } else {
        task.totalBytes = -1;
        _totalBytesLocked = false;
        _totalBytesEstimated = false;
        _initialSizeEstimate = 0;
        debugPrint(
          'HLS size unknown after sampling '
          '(${samples.length} valid samples of ${indices.length} probes)',
        );
      }
    }

    task.statusMessage = null;
    _taskUpdateController.add(task);
  }

  /// Drains a probe/error response body back into the connection pool, but
  /// aborts (rather than download-and-discard) when the server streamed a
  /// large body — e.g. it ignored the `Range: bytes=0-0` header and sent
  /// the whole file.
  Future<void> _drainOrAbort(http.StreamedResponse response) async {
    final len = response.contentLength;
    if (response.statusCode == 206 || (len != null && len <= 65536)) {
      try {
        await response.stream.drain<void>();
      } catch (_) {}
    } else {
      try {
        await response.stream.listen((_) {}, onError: (_) {}).cancel();
      } catch (_) {}
    }
  }

  /// Probe a single URI for Content-Length via HEAD, then Range-GET.
  Future<int?> _probeUriContentLength(Uri uri) async {
    try {
      final headReq = http.Request('HEAD', uri);
      if (task.headers != null) headReq.headers.addAll(task.headers!);
      final headResp = await client
          .send(headReq)
          .timeout(const Duration(seconds: 4));
      try {
        // Drain (not cancel) so the connection returns to the keep-alive
        // pool instead of being torn down after every probe.
        await headResp.stream.drain<void>();
      } catch (_) {}
      if (headResp.statusCode >= 200 && headResp.statusCode < 400) {
        final len = headResp.contentLength;
        if (len != null && len > 0) return len;
        final cl = headResp.headers['content-length'];
        final parsed = cl != null ? int.tryParse(cl) : null;
        if (parsed != null && parsed > 0) return parsed;
      }
    } catch (_) {}

    try {
      final getReq = http.Request('GET', uri);
      if (task.headers != null) getReq.headers.addAll(task.headers!);
      getReq.headers['Range'] = 'bytes=0-0';
      getReq.followRedirects = true;
      final getResp = await client
          .send(getReq)
          .timeout(const Duration(seconds: 5));
      await _drainOrAbort(getResp);
      if (getResp.statusCode >= 200 && getResp.statusCode < 400) {
        final cr = getResp.headers['content-range'] ?? '';
        final m = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(cr);
        if (m != null) {
          final total = int.tryParse(m.group(1)!);
          if (total != null && total > 0) return total;
        }
        final len = getResp.contentLength;
        if (len != null && len > 1) return len;
      }
    } catch (_) {}

    // Note: task.fetchViaWebView returns a response *body* (String), not
    // headers — it cannot be used for Content-Length probes.
    return null;
  }

  /// Progressive size refinement after each completed media segment.
  ///
  /// Uses finished-segment sizes for the formula. When the sniffer/sample
  /// estimate is far too low, **segment-fraction extrapolation** raises
  /// [task.totalBytes] so the queue never sits at "100% · 5 GB / 377 MB".
  void _refineSizeAfterSegment({
    required int bytes,
    required int segmentIndex,
    required bool isInit,
  }) {
    if (isInit) {
      if (bytes > 0) _initSegmentBytes = bytes;
      return;
    }
    if (bytes < HlsSizeEstimator.minSegmentBytes ||
        bytes > HlsSizeEstimator.maxSegmentBytes) {
      // Still fix a stuck total when actual download already overshot it.
      _ensureTotalCoversDownloaded();
      return;
    }

    final playlist = _playlist;
    final dur =
        (playlist != null &&
            segmentIndex >= 0 &&
            segmentIndex < playlist.segments.length)
        ? playlist.segments[segmentIndex].durationSeconds
        : 0.0;

    _completedSegSizes.add(bytes);
    _completedSegDurationSec += dur > 0 ? dur : 0;
    _completedSegCount++;

    if (_totalBytesExact) {
      _ensureTotalCoversDownloaded();
      return;
    }

    final totalSegs = playlist?.segments.length ?? 0;
    if (totalSegs <= 0) {
      _ensureTotalCoversDownloaded();
      return;
    }

    // Need a few real segments before overriding a sniffer/sample estimate.
    if (_completedSegCount < 3 && _initialSizeEstimate > 0) {
      _ensureTotalCoversDownloaded(totalSegs: totalSegs);
      return;
    }

    final refined = HlsSizeEstimator.refine(
      completedSegmentCount: _completedSegCount,
      totalSegmentCount: totalSegs,
      completedDurationSeconds: _completedSegDurationSec,
      totalDurationSeconds: playlist?.durationSeconds ?? 0,
      initSegmentBytes: _initSegmentBytes,
      completedSegmentSizes: _completedSegSizes,
      downloadedBytesFloor: 0,
    );

    var next = refined.totalBytes ?? 0;

    // Soft guide from the initial estimate only when we have little real
    // data — never keep a low ceiling once downloaded bytes exceed it.
    final segFrac = _completedSegCount / totalSegs;
    if (_initialSizeEstimate > 0 &&
        segFrac < 0.15 &&
        next > 0 &&
        task.downloadedBytes < _initialSizeEstimate) {
      final maxAllowed = (_initialSizeEstimate * 2.0).round();
      final minAllowed = (_initialSizeEstimate * 0.4).round();
      if (next > maxAllowed) next = maxAllowed;
      if (next < minAllowed) next = minAllowed;
    }

    // Prefer extrapolating from real download + segment fraction when the
    // estimate is clearly wrong (the Queue "100% / tiny total" bug).
    if (task.downloadedBytes > 0 && segFrac > 0.02) {
      final fromProgress = (task.downloadedBytes / segFrac).round();
      if (fromProgress > next) next = fromProgress;
    }

    if (task.downloadedBytes > next) {
      // Headroom so the bar does not pin at 100% mid-download.
      next = (task.downloadedBytes * 1.08).round();
    }

    if (next <= 0) {
      _ensureTotalCoversDownloaded(totalSegs: totalSegs);
      return;
    }

    // Smooth, but allow large upward corrections when estimate was way low.
    if (_totalBytesEstimated && task.totalBytes > 0) {
      final hugeUnderestimate =
          task.downloadedBytes > task.totalBytes * 1.1 ||
          next > task.totalBytes * 1.5;
      if (hugeUnderestimate) {
        // Jump quickly toward the better estimate (still slightly smooth).
        task.totalBytes = ((next * 0.75) + (task.totalBytes * 0.25)).round();
      } else {
        final blended = ((next * 0.55) + (task.totalBytes * 0.45)).round();
        final maxStep = math.max(
          (task.totalBytes * 1.2).round(),
          task.totalBytes + 8 * 1024 * 1024,
        );
        final minStep = math.min(
          (task.totalBytes * 0.8).round(),
          task.totalBytes - 8 * 1024 * 1024,
        );
        task.totalBytes = blended.clamp(
          math.min(minStep, next),
          math.max(maxStep, next),
        );
      }
    } else {
      task.totalBytes = next;
    }
    // Never show total smaller than bytes already on disk.
    if (task.totalBytes < task.downloadedBytes) {
      task.totalBytes = (task.downloadedBytes * 1.05).round();
    }
    _totalBytesEstimated = true;
    _totalBytesLocked = true;
  }

  /// If [task.downloadedBytes] already exceeds [task.totalBytes], raise the
  /// total (optionally via segment-fraction extrapolation).
  void _ensureTotalCoversDownloaded({int? totalSegs}) {
    if (_totalBytesExact) {
      if (task.totalBytes > 0 && task.downloadedBytes > task.totalBytes) {
        task.totalBytes = task.downloadedBytes;
      }
      return;
    }
    if (task.downloadedBytes <= 0) return;
    if (task.totalBytes > 0 && task.downloadedBytes <= task.totalBytes) {
      return;
    }

    final segs = totalSegs ?? _playlist?.segments.length ?? 0;
    var next = (task.downloadedBytes * 1.08).round();
    if (segs > 0 && _completedSegCount > 0) {
      final frac = (_completedSegCount / segs).clamp(0.02, 0.99);
      final extrapolated = (task.downloadedBytes / frac).round();
      if (extrapolated > next) next = extrapolated;
    }
    task.totalBytes = next;
    _totalBytesEstimated = true;
    _totalBytesLocked = true;
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
  /// Refreshes the task's token and resets state for a retry without directly calling start().
  Future<void> prepareRetryWithRefresh({bool forceReload = false}) async {
    if (task.onTokenExpired != null) {
      task.statusMessage = 'Refreshing link from the page.';
      task.errorMessage = null;
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
    task.statusMessage = null;
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
      if (!_totalBytesExact) _totalBytesEstimated = true;
    } else {
      task.totalBytes = -1;
      _totalBytesLocked = false;
      _totalBytesExact = false;
      _totalBytesEstimated = false;
    }
    _completedSegSizes.clear();
    _completedSegDurationSec = 0;
    _completedSegCount = 0;
    _initSegmentBytes = 0;
    _initialSizeEstimate = 0;
    _hostBlocked = false;
    _consecutiveSegmentFailures = 0;
    _needsRefresh = false;
    _staleSegmentIndexes.clear();
    _countedSegmentIndexes.clear();
    _taskUpdateController.add(task);
  }

  /// Refreshes token and immediately begins download (for direct/single retries).
  Future<void> retryWithRefresh({bool forceReload = false}) async {
    await prepareRetryWithRefresh(forceReload: forceReload);
    await start();
  }

  /// Account for a finished segment's size toward totalBytes (accumulate
  /// or progressively refine a sampled estimate).
  void _accountSegmentBytes({
    required int bytes,
    required int fileIndex,
    required int segmentIndex,
    required bool isInit,
  }) {
    if (isInit) {
      _refineSizeAfterSegment(bytes: bytes, segmentIndex: -1, isInit: true);
      return;
    }
    if (_countedSegmentIndexes.contains(fileIndex)) return;
    _countedSegmentIndexes.add(fileIndex);

    // Segment progress is the source of truth for % (Queue + notifications).
    final totalSegs = _playlist?.segments.length ?? task.totalParts;
    if (totalSegs > 0) {
      task.totalParts = totalSegs;
      task.completedParts = _countedSegmentIndexes.length.clamp(0, totalSegs);
    }

    if (_totalBytesExact) {
      _ensureTotalCoversDownloaded(totalSegs: totalSegs > 0 ? totalSegs : null);
      return;
    }

    if (!_totalBytesLocked) {
      // No pre-estimate yet: provisional total = sum of completed sizes
      // extrapolated once we have a few samples (handled in refine).
      if (task.totalBytes < 0) task.totalBytes = 0;
    }

    _refineSizeAfterSegment(
      bytes: bytes,
      segmentIndex: segmentIndex,
      isInit: false,
    );
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

  /// True when [body] looks like a real HLS playlist (not a CF/HTML block page).
  static bool _isUsablePlaylistBody(String? body) {
    if (body == null || body.isEmpty) return false;
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('#EXTM3U')) return true;
    final head = trimmed.length > 64 ? trimmed.substring(0, 64) : trimmed;
    return head.contains('#EXTM3U');
  }

  Future<HlsPlaylist> _fetchPlaylist(Uri uri) =>
      HlsPlaylistFetchLimiter.instance.run(() => _fetchPlaylistUnbounded(uri));

  Future<HlsPlaylist> _fetchPlaylistUnbounded(Uri uri) async {
    final urlStr = uri.toString();
    final details = <String>[];

    // 0th attempt: cached HLS playlist body from browser_guard.js capture.
    // When the browser page loaded, browser_guard.js intercepted the fetch/XHR
    // for this .m3u8 URL and cached the response body.  Using it here avoids
    // any network request — no Cloudflare WAF, no cookie mismatch, no 403.
    // Lookup is exact or host+path (sibling query / quality cache reuse).
    if (task.hlsPlaylistCache != null) {
      final cached = task.hlsPlaylistCache!(urlStr);
      if (_isUsablePlaylistBody(cached)) {
        debugPrint(
          'Using cached HLS playlist body for $uri (${cached!.length} chars)',
        );
        return HlsPlaylistParser.parse(cached, uri);
      }
      debugPrint(
        'Cache MISS for $urlStr (hlsPlaylistCache is set but returned null/unusable)',
      );
      details.add('Cache:miss');
    } else {
      debugPrint(
        'hlsPlaylistCache is null (task not created from browser tab)',
      );
      details.add('Cache:null');
    }

    var headers = _requestHeaders(uri);
    debugPrint('_fetchPlaylist uri=$uri headers_count=${headers.length}');

    // 1st attempt: WebView JS body fetch (same path as sniffer
    // fetchPlaylistBodyViaJavaScript). Runs in the browser context so it
    // sees Cloudflare clearance cookies + real Chrome TLS fingerprint.
    // Opening the .m3u8 in the address bar can show a CF block page while
    // this path still succeeds from the source-page tab.
    if (task.fetchViaWebView != null) {
      try {
        final jsBody = await task.fetchViaWebView!(urlStr, headers: headers)
            .timeout(const Duration(seconds: 20));
        if (_isUsablePlaylistBody(jsBody)) {
          debugPrint(
            'WebView JS fetch succeeded for $uri (${jsBody!.length} chars)',
          );
          return HlsPlaylistParser.parse(jsBody, uri);
        }
        details.add('WebView:null/empty');
        debugPrint('WebView JS fetch returned null/empty/non-playlist');
      } catch (e) {
        details.add('WebView:throw');
        debugPrint('WebView JS fetch threw: $e');
        _logError('WebView JS fetch threw', e);
      }
    } else {
      details.add('WebView:unset');
      debugPrint('fetchViaWebView is null (no WebView context)');
    }

    // 2nd attempt: headless WebView on the CDN origin (same-origin XHR).
    // Segments already use this path; playlists previously fell through to
    // Dart HTTP which Cloudflare TLS-fingerprint blocks (403).
    if (!_isPaused) {
      try {
        _headlessFetcher ??= HeadlessWebViewFetcher();
        final headlessBody = await _headlessFetcher!
            .fetchText(urlStr)
            .timeout(const Duration(seconds: 45));
        if (_isUsablePlaylistBody(headlessBody)) {
          debugPrint(
            'Headless WebView playlist fetch succeeded for $uri '
            '(${headlessBody!.length} chars)',
          );
          return HlsPlaylistParser.parse(headlessBody, uri);
        }
        details.add('Headless:null/empty');
        debugPrint(
          'Headless WebView playlist fetch returned null/empty for $uri',
        );
      } catch (e) {
        details.add('Headless:throw');
        debugPrint('Headless WebView playlist fetch threw: $e');
        _logError('Headless playlist fetch threw', e);
      }
    }

    // 3rd attempt: Dart HTTP client (works for non-WAF hosts; usually 403
    // on Cloudflare CDNs like surrit.com even with cookies).
    debugPrint('Trying Dart HTTP client for $uri');
    if (task.cookieProvider != null) {
      try {
        final cookieHeaders = await task.cookieProvider!(urlStr);
        if (cookieHeaders.isNotEmpty) {
          headers = {...headers, ...cookieHeaders};
        }
      } catch (_) {}
    }
    try {
      final response = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode >= 200 &&
          response.statusCode < 300 &&
          _isUsablePlaylistBody(response.body)) {
        return HlsPlaylistParser.parse(response.body, uri);
      }
      details.add('Dart:${response.statusCode}');
      debugPrint('Dart client returned ${response.statusCode}');
    } catch (e) {
      details.add('Dart:throw');
      _logError('Dart playlist fetch threw', e);
    }

    // 4th attempt: Android native HttpURLConnection.
    try {
      final nativeResult = await NetworkBindingService.fetchUrl(
        urlStr,
        headers: headers,
      );
      if (nativeResult != null) {
        final sc = nativeResult['statusCode'] as int? ?? 0;
        final body = nativeResult['body'] as String? ?? '';
        details.add('Native:$sc');
        if (sc >= 200 && sc < 300 && _isUsablePlaylistBody(body)) {
          debugPrint('Native HTTP fallback succeeded for $uri (status $sc)');
          return HlsPlaylistParser.parse(body, uri);
        }
      } else {
        details.add('Native:null');
      }
    } catch (e) {
      details.add('Native:throw');
      _logError('Native HTTP fallback threw', e);
    }

    final detailStr = details.join(' ');
    debugPrint('All fetch attempts failed for $uri. Detail: $detailStr');
    // Prefer reporting a real status from the chain (not a hardcoded 403).
    final statusMatch = RegExp(
      r'(?:Dart|Native):(\d{3})',
    ).firstMatch(detailStr);
    final statusHint = statusMatch?.group(1) ?? 'failed';
    throw HttpException(
      'HLS playlist request failed ($statusHint). Fallback results: $detailStr. '
      'If the page still plays in the browser, re-open the source page and retry '
      '(WebView/headless path must be used for Cloudflare CDNs).',
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
          debugPrint('WebView binary fetch key OK (16 bytes)');
          return Uint8List.fromList(data);
        }
      } catch (e) {
        debugPrint('WebView binary fetch key threw: $e');
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
      await _drainOrAbort(response);
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

    // Queue + notifications use parts (segments done / total), not byte
    // estimates — keep these in sync for the whole segment pass.
    task.totalParts = segments.length;
    task.completedParts = 0;

    // Reset downloadedBytes so the segment-skip logic below recomputes
    // from valid segments only (the initial value from the resume
    // detection was a quick sum without validity checking).
    if (_isRetry) {
      task.downloadedBytes = 0;
      // Force skip path to re-add sizes once (valid segments only).
      _resumeDiskBytesSeeded = false;
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
    // Prefer high concurrency for the native stream path (1DM-style).
    // Only cap hard when native is disabled and every segment must go
    // through the WebView base64 bridge (that path starves at 4–8×).
    final webViewOnly =
        _skipNativeSegment && task.fetchBinaryViaWebView != null;
    final effectiveConcurrency = webViewOnly
        ? math.min(maxConcurrentSegments, 2)
        : maxConcurrentSegments;
    final workerCount = math.max(
      1,
      math.min(effectiveConcurrency, segments.length),
    );
    debugPrint(
      'HLS segment workers=$workerCount '
      '(maxConcurrent=$maxConcurrentSegments nativeSkip=$_skipNativeSegment '
      'webViewOnly=$webViewOnly)',
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
            if (size > 0 && await _isSegmentValid(existing, ext, isInitSeg)) {
              files[fileIndex] = existing;
              // Resume already seeded downloadedBytes from disk — do not
              // double-count here. Fresh runs without seed still +=.
              if (!_resumeDiskBytesSeeded) {
                task.downloadedBytes += size;
              }
              _accountSegmentBytes(
                bytes: size,
                fileIndex: fileIndex,
                segmentIndex: segIndex,
                isInit: false,
              );
              debugPrint('Seg $segIndex skipped ($size bytes)');
              continue; // Valid segment — already downloaded and decrypted.
            }
            // Invalid (likely pre-fix encrypted) — delete and re-download.
            debugPrint('Seg $segIndex invalid — re-downloading');
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

    final staleConcurrency = task.fetchBinaryViaWebView != null
        ? math.min(maxConcurrentSegments, 2)
        : maxConcurrentSegments;
    final workerCount = math.max(1, math.min(staleConcurrency, sorted.length));
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
    final ext = isInit
        ? 'mp4'
        : (uri.path.toLowerCase().endsWith('.m4s') ? 'm4s' : 'ts');
    final finalPath =
        '${task.tempDir}/segment_${index.toString().padLeft(6, '0')}.$ext';
    final partPath = '$finalPath.part';

    // 0th attempt: Android native stream-to-file (CookieManager + media
    // headers). This is the 1DM-class path — multi‑MB/s without WebView
    // base64. Was implemented natively but never wired into HLS until now.
    if (!_skipNativeSegment && !_isPaused && !_hostBlocked) {
      try {
        final headers = Map<String, String>.from(_requestHeaders(uri));
        String? cookieHeader;
        if (task.cookieProvider != null) {
          try {
            final cookies = await task.cookieProvider!(uri.toString());
            cookieHeader = cookies['Cookie'] ?? cookies['cookie'];
            if (cookieHeader == null && cookies.isNotEmpty) {
              // Flatten map of name→value if provider returns that shape.
              cookieHeader = cookies.entries
                  .where((e) => e.key.toLowerCase() != 'cookie')
                  .map((e) => '${e.key}=${e.value}')
                  .join('; ');
              if (cookieHeader.isEmpty) cookieHeader = null;
            }
          } catch (_) {}
        }
        final partFile = File(partPath);
        await partFile.parent.create(recursive: true);
        final native = await NetworkBindingService.streamSegmentToFile(
          uri.toString(),
          partPath,
          headers: headers,
          cookieHeader: cookieHeader,
        ).timeout(const Duration(seconds: 130));
        final status = native?['statusCode'] as int? ?? 0;
        final written = (native?['bytesWritten'] as num?)?.toInt() ?? 0;
        if (status >= 200 &&
            status < 300 &&
            written > 0 &&
            await partFile.exists()) {
          final limiter = _speedLimiter;
          if (limiter != null && limiter.isActive) {
            while (!limiter.tryConsume(written)) {
              await limiter.onCapacityAvailable;
              if (_isPaused) break;
            }
          }
          final keyBytes = _encryptionKeyBytes;
          if (!isInit && keyBytes != null && segmentIndex >= 0) {
            final iv = _buildAesIv(
              _playlist?.encryptionKey,
              segmentIndex,
              _playlist?.mediaSequence ?? 0,
            );
            await HlsDecryptPool.instance.decryptInPlace(
              partFile,
              keyBytes,
              iv,
            );
          }
          await partFile.rename(finalPath);
          task.downloadedBytes += written;
          _accountSegmentBytes(
            bytes: written,
            fileIndex: index,
            segmentIndex: segmentIndex,
            isInit: isInit,
          );
          _taskUpdateController.add(task);
          _consecutiveSegmentFailures = 0;
          _nativeForbiddenStreak = 0;
          debugPrint(
            'Native stream segment $index OK ($written bytes, status $status)',
          );
          return File(finalPath);
        }
        if (status == 403 || status == 401) {
          _nativeForbiddenStreak++;
          if (_nativeForbiddenStreak >= 3) {
            _skipNativeSegment = true;
            debugPrint(
              'Native segment stream disabled after $_nativeForbiddenStreak '
              '× 403/401 — falling back to WebView/headless',
            );
          }
        }
        try {
          if (await partFile.exists()) await partFile.delete();
        } catch (_) {}
        debugPrint(
          'Native stream segment $index failed status=$status written=$written',
        );
      } catch (e) {
        debugPrint('Native stream segment $index threw: $e');
        try {
          final f = File(partPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }

    // 1st attempt: WebView binary fetch (bypasses Cloudflare WAF).
    if (task.fetchBinaryViaWebView != null) {
      try {
        final data = await task.fetchBinaryViaWebView!(uri.toString()).timeout(
          const Duration(seconds: 55),
        );
        if (data != null && data.isNotEmpty) {
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
            await HlsDecryptPool.instance.decryptInPlace(
              partFile,
              keyBytes,
              iv,
            );
          }
          // Rename .part to final only after successful write + decrypt.
          await partFile.rename(finalPath);
          final file = File(finalPath);
          task.downloadedBytes += data.length;
          _accountSegmentBytes(
            bytes: data.length,
            fileIndex: index,
            segmentIndex: segmentIndex,
            isInit: isInit,
          );
          _taskUpdateController.add(task);
          _consecutiveSegmentFailures = 0; // Circuit breaker reset
          debugPrint(
            'WebView binary fetch segment $index OK (${data.length} bytes)',
          );
          return file;
        }
      } catch (e) {
        debugPrint('WebView binary fetch segment $index threw: $e');
      }
    }

    // 2nd fallback: headless WebView (before Dart HTTP). The headless
    // WebView creates its own Chromium TLS session on the CDN's domain,
    // which bypasses Cloudflare TLS fingerprint detection that blocks
    // Dart's TLS stack even when valid cookies are sent.
    if (!_isPaused && !_hostBlocked) {
      try {
        _headlessFetcher ??= HeadlessWebViewFetcher();
        final data = await _headlessFetcher!
            .fetchBinary(uri.toString())
            .timeout(const Duration(seconds: 55));
        if (data != null && data.isNotEmpty) {
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
          task.downloadedBytes += data.length;
          _accountSegmentBytes(
            bytes: data.length,
            fileIndex: index,
            segmentIndex: segmentIndex,
            isInit: isInit,
          );
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
            await HlsDecryptPool.instance.decryptInPlace(
              partFile,
              keyBytes,
              iv,
            );
          }
          // Rename .part to final only after successful write + decrypt.
          await partFile.rename(finalPath);
          final hlFile = File(finalPath);
          debugPrint(
            'Headless WebView fetched segment $index OK (${data.length} bytes)',
          );
          return hlFile;
        }
      } catch (e) {
        debugPrint('Headless WebView fallback failed for segment $index: $e');
      }
    }

    // Circuit breaker: if host is already blocked, don't even try HTTP.
    if (_hostBlocked) {
      final file = File('${task.tempDir}/stub_$index');
      await file.writeAsString('');
      return file;
    }

    // After WebView + headless both failed, HTTP almost always 403s on
    // Cloudflare WAF hosts. Skip further HTTP attempts once we know that.
    if (_skipHttpFallback) {
      debugPrint(
        'HTTP fallback skipped for segment $index (WAF host; use WebView/headless only)',
      );
      // One more headless attempt before stubbing — often recovers after
      // the bridge is less congested.
      if (task.fetchBinaryViaWebView != null || _headlessFetcher != null) {
        try {
          _headlessFetcher ??= HeadlessWebViewFetcher();
          final retry = await _headlessFetcher!
              .fetchBinary(uri.toString())
              .timeout(const Duration(seconds: 55));
          if (retry != null && retry.isNotEmpty) {
            final partFile = File(partPath);
            await partFile.parent.create(recursive: true);
            await partFile.writeAsBytes(retry);
            final keyBytes = _encryptionKeyBytes;
            if (!isInit && keyBytes != null && segmentIndex >= 0) {
              final iv = _buildAesIv(
                _playlist?.encryptionKey,
                segmentIndex,
                _playlist?.mediaSequence ?? 0,
              );
              await HlsDecryptPool.instance.decryptInPlace(
                partFile,
                keyBytes,
                iv,
              );
            }
            await partFile.rename(finalPath);
            task.downloadedBytes += retry.length;
            _accountSegmentBytes(
              bytes: retry.length,
              fileIndex: index,
              segmentIndex: segmentIndex,
              isInit: isInit,
            );
            _consecutiveSegmentFailures = 0;
            _taskUpdateController.add(task);
            debugPrint(
              'Headless retry after skip-HTTP OK for segment $index (${retry.length} bytes)',
            );
            return File(finalPath);
          }
        } catch (_) {}
      }
      _needsRefresh = true;
      _staleSegmentIndexes.add(index);
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
            debugPrint('cookieProvider threw for segment $index: $e');
          }
        }
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
        debugPrint(
          'HTTP segment $index: status ${response.statusCode} (attempt $attempt)',
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Drain (not cancel) the error/response body so the connection
          // returns to the keep-alive pool before throwing.
          await _drainOrAbort(response);
          if (response.statusCode == 403 || response.statusCode == 401) {
            _httpForbiddenStreak++;
            // After 2 HTTP 403s, stop wasting attempts on Dart HTTP for
            // this host — WebView/headless are the only viable paths.
            if (_httpForbiddenStreak >= 2 &&
                (task.fetchBinaryViaWebView != null ||
                    _headlessFetcher != null)) {
              _skipHttpFallback = true;
              debugPrint(
                'Disabling HTTP segment fallback after $_httpForbiddenStreak '
                '× 403/401 — relying on WebView/headless only',
              );
            }

            // Circuit breaker: track consecutive 403/401 failures.
            // After too many in a row, abort to avoid triggering a
            // Cloudflare IP block from hammering the CDN.
            // When WebView paths exist, be more patient — 403 via HTTP
            // does not mean WebView is dead.
            final hasWebViewPath = task.fetchBinaryViaWebView != null;
            final failLimit = hasWebViewPath
                ? _maxConsecutiveFailures * 3
                : _maxConsecutiveFailures;
            _consecutiveSegmentFailures++;
            if (_consecutiveSegmentFailures >= failLimit && !_hostBlocked) {
              _hostBlocked = true;
              task.state = DownloadState.failed;
              task.failureReason = DownloadFailure.hlsCircuitBreaker;
              task.errorMessage =
                  'CDN blocked access after $_consecutiveSegmentFailures failed requests. '
                  'Aurora is stopping to avoid getting your IP blocked. '
                  'Wait a few minutes and re-sniff from the video page.';
              _taskUpdateController.add(task);
              debugPrint(
                'Circuit breaker tripped: $_consecutiveSegmentFailures consecutive 403/401 failures — aborting to prevent Cloudflare IP block',
              );
              final file = File('${task.tempDir}/stub_$index');
              await file.writeAsString('');
              return file;
            }

            _needsRefresh = true;
            _staleSegmentIndexes.add(index);
            task.state = DownloadState.downloading;
            task.errorMessage =
                'Access token expired. Aurora is fetching a fresh one.';
            _taskUpdateController.add(task);
            // Return a dummy file — the merge step will detect it as a
            // stub and refuse to produce a partial/corrupt file.
            final file = File('${task.tempDir}/stub_$index');
            await file.writeAsString('');
            return file;
          }
          // Response already drained/aborted by _drainOrAbort above (the
          // 403/401 branch returned earlier); just throw for other statuses.
          throw HttpException(
            'HLS segment request failed with status ${response.statusCode}',
            uri: uri,
          );
        }

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
            // Do NOT mutate task.downloadedBytes mid-stream — concurrent
            // segment workers share the same task, and an error rollback
            // (was `task.downloadedBytes -= …`) would subtract bytes that
            // another worker legitimately added. Commit the total once after
            // the stream succeeds instead.
          }
        } catch (e) {
          // Error rollback removed intentionally — see comment above.
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
        // Commit downloaded bytes atomically after stream + decrypt success,
        // so concurrent workers never see a negative or backward jump.
        task.downloadedBytes += bytesDownloadedInThisAttempt;
        _consecutiveSegmentFailures = 0; // Circuit breaker reset on success

        final keyBytes = _encryptionKeyBytes;
        if (!isInit && keyBytes != null && segmentIndex >= 0) {
          try {
            final iv = _buildAesIv(
              _playlist?.encryptionKey,
              segmentIndex,
              _playlist?.mediaSequence ?? 0,
            );
            await HlsDecryptPool.instance.decryptInPlace(
              partFile,
              keyBytes,
              iv,
            );
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
        // Account actual on-disk size (post-decrypt) for size estimate.
        try {
          final size = await file.length();
          if (size > 0) {
            _accountSegmentBytes(
              bytes: size,
              fileIndex: index,
              segmentIndex: segmentIndex,
              isInit: isInit,
            );
          }
        } catch (_) {}
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
        return bytes[0] == 0x47 && (bytes.length < 188 || bytes[188] == 0x47);
      }
      // fMP4 / init: check for a known ISO BMFF box type.
      final type = String.fromCharCodes(bytes.sublist(4, 8));
      return [
        'ftyp',
        'styp',
        'moof',
        'mdat',
        'free',
        'skip',
        'sidx',
        'moov',
        'mvhd',
        'trak',
        'mdia',
        'minf',
        'stbl',
        'dinf',
        'edts',
        'mvex',
        'trex',
        'emsg',
        'saiz',
        'saio',
        'tenc',
        'uuid',
        'pssh',
        'prft',
      ].contains(type);
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
    // Concatenate on a background isolate so a multi-GB merge doesn't
    // stream through the UI isolate's event loop (which previously could
    // jank the UI for seconds on large files).
    final totalMerged = await _concatFilesInIsolate(
      files.map((f) => f.path).toList(),
      segmentLengths,
      finalPath,
    );
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

/// Concatenates [paths] into [destPath] on a background isolate, returning
/// the number of bytes written. Off the UI isolate so multi-GB merges don't
/// jank the UI during the final segment-concat pass.
Future<int> _concatFilesInIsolate(
  List<String> paths,
  List<int> lengths,
  String destPath,
) {
  return Isolate.run(() async {
    try {
      final dest = File(destPath);
      final parent = dest.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      final sink = dest.openWrite();
      var total = 0;
      try {
        for (var i = 0; i < paths.length; i++) {
          final length = lengths[i];
          if (length == 0) continue;
          await sink.addStream(File(paths[i]).openRead());
          total += length;
        }
      } finally {
        await sink.close();
      }
      return total;
    } catch (e) {
      // Errors crossing an isolate boundary arrive as RemoteError; rethrow
      // as a plain Exception so the caller's classifier works on it.
      throw Exception('HLS segment merge failed: $e');
    }
  });
}

/// Result of a resume scan performed on a background isolate.
///
/// [segmentSizes] maps each matched segment file's path to its on-disk byte
/// size; [entryCount] is the total number of entries in tempDir (matches the
/// pre-isolate "other files" log count). Both fields are plain sendable types.
typedef _ResumeScanResult = ({Map<String, int> segmentSizes, int entryCount});

/// Scans [tempDir] for already-downloaded HLS segment files off the UI
/// isolate. Returns `null` when [tempDir] does not exist.
///
/// Only finished segments (`segment_*.ts` / `segment_*.m4s`, excluding
/// `.part` partials) are included in the returned `segmentSizes` map so the
/// caller can seed `downloadedBytes` exactly as before.
Future<_ResumeScanResult?> _scanResumeSegments(String tempDir) {
  return Isolate.run(() => _scanResumeSegmentsSync(tempDir));
}

_ResumeScanResult? _scanResumeSegmentsSync(String tempDirPath) {
  final tempDir = Directory(tempDirPath);
  if (!tempDir.existsSync()) return null;
  final entries = tempDir.listSync().toList();
  final segmentSizes = <String, int>{};
  for (final entity in entries) {
    if (entity is! File) continue;
    final name = p.basename(entity.path).toLowerCase();
    if (!name.startsWith('segment_')) continue;
    if (name.endsWith('.part')) continue;
    if (!name.endsWith('.ts') && !name.endsWith('.m4s')) continue;
    try {
      segmentSizes[entity.path] = entity.lengthSync();
    } catch (_) {
      // Unreadable file — treat as absent (mirrors the original per-file
      // try/catch around length()).
    }
  }
  return (segmentSizes: segmentSizes, entryCount: entries.length);
}
