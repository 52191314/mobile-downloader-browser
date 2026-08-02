/// FFmpeg service — orchestrates media operations using ffmpeg-kit.
///
/// Gate: [ProFeature.ffmpegSuite] (Ultra tier only).
///
/// Architecture:
/// - Jobs are queued and executed sequentially (max 1 concurrent).
/// - Progress is reported as a stream of [FfmpegJob] updates.
/// - Cancellation kills the underlying FFmpeg process.
/// - Timeout: 30 minutes per job (configurable).
///
/// Hard rules:
/// - Never blocks the UI thread (ffmpeg-kit runs on its own native thread).
/// - Kill process on background / timeout.
/// - Single-process limit prevents resource starvation.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ffmpeg_job.dart';
import 'ffmpeg_module_loader.dart';
import 'ffmpeg_ops.dart';
import 'ffmpeg_runtime.dart' as ffmpeg_runtime;

/// Maximum execution time per FFmpeg job (seconds).
const kFfmpegMaxExecutionSeconds = 1800; // 30 minutes

/// Maximum concurrent FFmpeg processes.
const kFfmpegMaxConcurrent = 1;

/// Result of a version probe.
class FfmpegVersion {
  final String rawOutput;
  final bool available;

  const FfmpegVersion({required this.rawOutput, required this.available});

  bool get isAvailable => available;
}

/// Manages FFmpeg jobs: enqueue, execute, cancel, progress.
class FfmpegService extends ChangeNotifier {
  final List<FfmpegJob> _queue = [];
  FfmpegJob? _current;
  Timer? _timeoutTimer;

  /// Read-only view of the current job, or null if idle.
  FfmpegJob? get current => _current;

  /// Read-only view of pending jobs.
  List<FfmpegJob> get pending =>
      _queue.where((j) => j.state == FfmpegJobState.pending).toList();

  /// Whether any job is running.
  bool get isRunning => _current != null;

  /// Whether FFmpeg is available on this device.
  bool _available = false;
  bool get available => _available;

  // ---------------------------------------------------------------------------
  // Version probe
  // ---------------------------------------------------------------------------

  /// Probes whether ffmpeg-kit is available on this device.
  /// Returns null if the probe fails (e.g. library not loaded).
  Future<FfmpegVersion?> probeVersion() async {
    try {
      // Dynamic import to avoid compile-time dependency when ffmpeg-kit
      // is not included in the build.
      final result = await _ffprobeVersion();
      _available = result.available;
      return result;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FfmpegService] probeVersion failed: $e');
      }
      _available = false;
      return null;
    }
  }

  Future<FfmpegVersion> _ffprobeVersion() async {
    final installed =
        await FeatureModuleLoader.instance.ensureInstalled('ffmpeg');
    if (!installed) {
      return const FfmpegVersion(rawOutput: '', available: false);
    }
    final probe = await ffmpeg_runtime.FfmpegRuntime.probeVersion();
    return FfmpegVersion(
      rawOutput: probe?.rawOutput ?? '',
      available: probe?.available ?? false,
    );
  }

  // ---------------------------------------------------------------------------
  // Job management
  // ---------------------------------------------------------------------------

  /// Enqueue a [job] for execution. Returns immediately; the job will be
  /// processed when the current job finishes.
  void enqueue(FfmpegJob job) {
    _queue.add(job);
    notifyListeners();
    _processQueue();
  }

  /// Cancel the currently running job. No-op if idle.
  void cancelCurrent() {
    if (_current == null) return;
    _cancelJob(_current!);
    notifyListeners();
  }

  /// Cancel a specific pending job (not currently running).
  void cancelPending(String jobId) {
    final idx = _queue.indexWhere((j) => j.id == jobId);
    if (idx >= 0) {
      _queue[idx].state = FfmpegJobState.cancelled;
      _queue.removeAt(idx);
      notifyListeners();
    }
  }

  /// Remove all cancelled/completed/failed jobs from the queue.
  void clearTerminal() {
    _queue.removeWhere((j) => j.isTerminal);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Internal execution loop
  // ---------------------------------------------------------------------------

  bool _processing = false;

  Future<void> _processQueue() async {
    if (_processing || _current != null) return;
    _processing = true;

    while (_queue.isNotEmpty) {
      final job = _queue.firstWhere(
        (j) => j.state == FfmpegJobState.pending,
        orElse: () => _queue.first,
      );
      if (job.state != FfmpegJobState.pending) {
        _queue.remove(job);
        continue;
      }

      _current = job;
      job.state = FfmpegJobState.running;
      job.startedAt = DateTime.now();
      notifyListeners();

      await _executeJob(job);

      _queue.remove(job);
      _current = null;
      notifyListeners();
    }

    _processing = false;
  }

  Future<void> _executeJob(FfmpegJob job) async {
    _startTimeout(job);

    try {
      final cmd = buildFfmpegCommand(job);
      if (cmd == null) {
        job.state = FfmpegJobState.failed;
        job.errorMessage = 'Invalid job configuration';
        job.completedAt = DateTime.now();
        return;
      }

      final installed =
          await FeatureModuleLoader.instance.ensureInstalled('ffmpeg');
      if (!installed) {
        job.state = FfmpegJobState.failed;
        job.errorMessage = 'FFmpeg module dynamic feature not installed';
        job.completedAt = DateTime.now();
        return;
      }

      final session = await ffmpeg_runtime.FfmpegRuntime.execute(cmd);
      final returnCode = await session.getReturnCode();
      if (ffmpeg_runtime.ReturnCode.isSuccess(returnCode)) {
        job.state = FfmpegJobState.completed;
        job.progress = 1.0;
      } else if (ffmpeg_runtime.ReturnCode.isCancel(returnCode)) {
        job.state = FfmpegJobState.cancelled;
      } else {
        job.state = FfmpegJobState.failed;
        final allLogs = await session.getAllLogsAsString();
        job.errorMessage = allLogs ?? 'FFmpeg execution failed';
      }
      job.completedAt = DateTime.now();
    } catch (e) {
      job.state = FfmpegJobState.failed;
      job.errorMessage = e.toString();
      job.completedAt = DateTime.now();
    } finally {
      _cancelTimeout();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Timeout / cancellation
  // ---------------------------------------------------------------------------

  void _startTimeout(FfmpegJob job) {
    _cancelTimeout();
    _timeoutTimer = Timer(
      const Duration(seconds: kFfmpegMaxExecutionSeconds),
      () {
        if (job.state == FfmpegJobState.running) {
          _cancelJob(job);
          job.errorMessage = 'Job timed out after $kFfmpegMaxExecutionSeconds seconds';
          notifyListeners();
        }
      },
    );
  }

  void _cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void _cancelJob(FfmpegJob job) {
    job.state = FfmpegJobState.cancelled;
    job.completedAt = DateTime.now();

    if (job.sessionHandle != null) {
      ffmpeg_runtime.FfmpegRuntime.cancel(job.sessionHandle as int);
    }
  }

  @override
  void dispose() {
    _cancelTimeout();
    cancelCurrent();
    super.dispose();
  }
}
