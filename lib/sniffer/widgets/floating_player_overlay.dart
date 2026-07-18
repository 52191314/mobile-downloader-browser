import 'package:flutter/material.dart';

import '../models/sniffed_media.dart';
import '../playback_quality.dart';
import 'floating_video_button.dart';

/// Positions [FloatingVideoButton] on the largest video rect from JS, or
/// falls back to the lower-right of the WebView (above the bottom strip).
Widget buildFloatingPlayerOverlay({
  required double toolbarHeight,
  required SniffedMedia? media,
  required Rect? videoFloatRect,
  required VoidCallback onTap,
  required VoidCallback onDismiss,
}) {
  final button = FloatingVideoButton(
    onTap: onTap,
    onDismiss: onDismiss,
    subtitle: floatingPlayerSubtitle(media),
  );

  final rect = videoFloatRect;
  if (rect != null && rect.width >= 80 && rect.height >= 45) {
    // Park on the video's top-right corner (IDM-like), inset slightly.
    const size = 48.0;
    final left = (rect.right - size - 10).clamp(8.0, double.infinity);
    final top = (rect.top + 10).clamp(toolbarHeight + 4, double.infinity);
    return Positioned(
      left: left,
      top: top,
      child: button,
    );
  }

  // No video box yet — still show when we have sniffed media (blob/MSE
  // pages often hide real <video> geometry until play).
  return Positioned(
    right: 14,
    bottom: toolbarHeight + 18,
    child: button,
  );
}
