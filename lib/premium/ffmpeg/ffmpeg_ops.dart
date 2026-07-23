/// FFmpeg command builders — produce the CLI argument list for each
/// [FfmpegOp] so the service layer doesn't need to know about command syntax.
///
/// All paths are single-quoted to handle spaces safely.
library;

import 'ffmpeg_job.dart';

/// Builds the FFmpeg command string for [job].
/// Returns null if the job configuration is invalid.
String? buildFfmpegCommand(FfmpegJob job) {
  switch (job.operation) {
    case FfmpegOp.compress:
      return _buildCompress(job);
    case FfmpegOp.trim:
      return _buildTrim(job);
    case FfmpegOp.audioExtract:
      return _buildAudioExtract(job);
    case FfmpegOp.remux:
      return _buildRemux(job);
    case FfmpegOp.gif:
      return _buildGif(job);
  }
}

String _quote(String path) => "'$path'";

String _buildCompress(FfmpegJob job) {
  final p = job.compressParams ?? const FfmpegCompressParams();
  final args = <String>[
    '-y', // overwrite output without asking
    '-i', _quote(job.inputPath),
    '-c:v', 'libx264',
    '-crf', p.crf.toString(),
    '-preset', p.preset,
    '-c:a', 'aac',
    '-b:a', '64k',
    '-movflags', '+faststart',
    _quote(job.outputPath),
  ];
  return args.join(' ');
}

String _buildTrim(FfmpegJob job) {
  final p = job.trimParams ?? const FfmpegTrimParams(startSeconds: 0);
  final args = <String>[
    '-y',
    '-ss', p.startSeconds.toString(),
    '-i', _quote(job.inputPath),
  ];
  if (p.endSeconds != null) {
    args.addAll(['-to', p.endSeconds.toString()]);
  }
  args.addAll(['-c', 'copy', _quote(job.outputPath)]);
  return args.join(' ');
}

String _buildAudioExtract(FfmpegJob job) {
  final ext = job.outputPath.split('.').last.toLowerCase();
  final codec = ext == 'mp3' ? 'libmp3lame' : 'aac';
  final args = <String>[
    '-y',
    '-i', _quote(job.inputPath),
    '-vn', // no video
    '-acodec', codec,
    '-b:a', codec == 'mp3' ? '192k' : '128k',
    _quote(job.outputPath),
  ];
  return args.join(' ');
}

String _buildRemux(FfmpegJob job) {
  final args = <String>[
    '-y',
    '-i', _quote(job.inputPath),
    '-c', 'copy',
    '-movflags', '+faststart',
    _quote(job.outputPath),
  ];
  return args.join(' ');
}

String _buildGif(FfmpegJob job) {
  final p = job.gifParams ?? const FfmpegGifParams();
  final filters = <String>[];
  if (p.startSeconds != null) {
    // handle start offset via -ss before -i for faster seeking
  }
  filters.add('fps=${p.fps}');
  filters.add('scale=${p.width}:-1:flags=lanczos');
  filters.add('split[s0][s1]');
  filters.add('[s0]palettegen[p]');
  filters.add('[s1][p]paletteuse');

  final args = <String>['-y'];
  if (p.startSeconds != null) {
    args.addAll(['-ss', p.startSeconds.toString()]);
  }
  args.addAll([
    '-t', p.durationSeconds.toString(),
    '-i', _quote(job.inputPath),
    '-vf', filters.join(','),
    '-c:v', 'gif',
    _quote(job.outputPath),
  ]);
  return args.join(' ');
}
