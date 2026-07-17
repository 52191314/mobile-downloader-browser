import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../../downloader/downloader.dart';

class DownloadPropertiesDialog extends StatefulWidget {
  final DownloadTask task;

  const DownloadPropertiesDialog({
    required this.task,
  });

  @override
  State<DownloadPropertiesDialog> createState() => DownloadPropertiesDialogState();
}

class DownloadPropertiesDialogState extends State<DownloadPropertiesDialog> {
  String get _currentName {
    final normalizedPath = widget.task.savePath.replaceAll('\\', '/');
    final lastSlash = normalizedPath.lastIndexOf('/');
    return lastSlash >= 0
        ? normalizedPath.substring(lastSlash + 1)
        : widget.task.savePath;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    return AlertDialog(
      title: const Text('File details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('File name', style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              _currentName,
              style: TextStyle(fontSize: 12, color: ac.textSecondary),
            ),
            const SizedBox(height: 16),
            Text('Location', style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              widget.task.publicPathLabel ?? widget.task.savePath,
              style: TextStyle(fontSize: 12, color: ac.textSecondary),
            ),
            const SizedBox(height: 16),
            Text('Download link', style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              widget.task.url,
              style: TextStyle(fontSize: 12, color: ac.textSecondary),
            ),
            const SizedBox(height: 16),
            if (widget.task.sourcePageUrl != null) ...[
              Text('Source page', style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(
                widget.task.sourcePageUrl!,
                style: TextStyle(fontSize: 12, color: ac.textSecondary),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
