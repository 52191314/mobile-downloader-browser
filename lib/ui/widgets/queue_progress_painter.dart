import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../downloader/downloader.dart';
import '../../theme/aurora_tokens.dart';

class QueueProgressPainter extends CustomPainter {
  final List<DownloadTask> tasks;
  final Color trackColor;
  final Color fillColor;

  const QueueProgressPainter(
    this.tasks, {
    required this.trackColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trackPaint = Paint()
      ..color = trackColor
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = fillColor
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    final rows = math.max(1, math.min(tasks.length, 6));
    final gap = rows == 1 ? 0.0 : size.height / rows;
    for (var i = 0; i < rows; i++) {
      final y = rows == 1 ? size.height / 2 : (gap * i) + 8;
      final start = Offset(4, y);
      final end = Offset(size.width - 4, y);
      canvas.drawLine(start, end, trackPaint);
      final value = tasks.isEmpty ? 0.18 : tasks[i].progress.clamp(0.02, 1.0);
      final fillEnd = Offset(4 + ((size.width - 8) * value), y);
      canvas.drawLine(start, fillEnd, fillPaint);
    }
  }

  @override
  bool shouldRepaint(covariant QueueProgressPainter oldDelegate) {
    return oldDelegate.tasks != tasks ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.fillColor != fillColor;
  }
}

/// Convenience factory that resolves the painter colors from a palette.
class QueueProgressPainterFactory {
  static QueueProgressPainter forPalette({
    required List<DownloadTask> tasks,
    required AColors palette,
  }) =>
      QueueProgressPainter(
        tasks,
        trackColor: palette.borderStrong,
        fillColor: palette.accentFrost,
      );
}
