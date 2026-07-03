import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../downloader/downloader.dart';
import '../../theme/aurora_colors.dart';

class QueueProgressPainter extends CustomPainter {
  final List<DownloadTask> tasks;

  QueueProgressPainter(this.tasks);

  @override
  void paint(Canvas canvas, Size size) {
    final trackPaint = Paint()
      ..color = AuroraColors.border
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = AuroraColors.accent
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
    return oldDelegate.tasks != tasks;
  }
}
