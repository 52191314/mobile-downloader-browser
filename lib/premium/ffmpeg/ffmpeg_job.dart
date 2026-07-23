/// FFmpeg job model — represents a single media operation.
///
/// Jobs are created by the UI and consumed by [FfmpegService].
/// Gate: [ProFeature.ffmpegSuite] (Ultra tier).
library;

/// The type of FFmpeg operation to perform.
enum FfmpegOp {
  /// Compress a video file (CRF / x264).
  compress,

  /// Trim a video to a time range.
  trim,

  /// Extract audio from a video (m4a / mp3).
  audioExtract,

  /// Remux a container (e.g. TS → MP4).
  remux,

  /// Generate a GIF from a video segment.
  gif,
}

/// Parameters for a compress operation.
class FfmpegCompressParams {
  final int crf; // 18–51, lower = better quality
  final String preset; // e.g. 'fast', 'medium', 'slow'

  const FfmpegCompressParams({this.crf = 28, this.preset = 'fast'});
}

/// Parameters for a trim operation.
class FfmpegTrimParams {
  final double startSeconds;
  final double? endSeconds; // null = to end

  const FfmpegTrimParams({required this.startSeconds, this.endSeconds});
}

/// Parameters for a GIF generation.
class FfmpegGifParams {
  final int fps; // 5–15
  final int width; // 160–640
  final double? startSeconds;
  final double durationSeconds; // max 30

  const FfmpegGifParams({
    this.fps = 10,
    this.width = 320,
    this.startSeconds,
    this.durationSeconds = 5,
  });
}

/// Current state of an FFmpeg job.
enum FfmpegJobState {
  /// Not yet started.
  pending,

  /// FFmpeg process is running.
  running,

  /// Completed successfully.
  completed,

  /// Failed with an error.
  failed,

  /// Cancelled by user or system.
  cancelled,
}

/// A single FFmpeg media operation job.
class FfmpegJob {
  final String id;
  final String inputPath;
  final String outputPath;
  final FfmpegOp operation;

  // Operation-specific parameters (only one is non-null per job).
  final FfmpegCompressParams? compressParams;
  final FfmpegTrimParams? trimParams;
  final FfmpegGifParams? gifParams;

  // Runtime state.
  FfmpegJobState state;
  double progress; // 0.0 – 1.0
  DateTime? startedAt;
  DateTime? completedAt;
  String? errorMessage;

  // FFmpeg session handle for cancellation.
  Object? _sessionHandle;

  FfmpegJob({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    required this.operation,
    this.compressParams,
    this.trimParams,
    this.gifParams,
    this.state = FfmpegJobState.pending,
    this.progress = 0,
    this.startedAt,
    this.completedAt,
    this.errorMessage,
  });

  /// Duration of the job in seconds, or null if not started.
  double? get elapsedSeconds {
    if (startedAt == null) return null;
    final end = completedAt ?? DateTime.now();
    return end.difference(startedAt!).inMilliseconds / 1000.0;
  }

  /// Whether this job is in a terminal state.
  bool get isTerminal =>
      state == FfmpegJobState.completed ||
      state == FfmpegJobState.failed ||
      state == FfmpegJobState.cancelled;

  /// Internal setter for the native session handle.
  void setSessionHandle(Object handle) => _sessionHandle = handle;

  /// Internal getter for the native session handle.
  Object? get sessionHandle => _sessionHandle;
}
