import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.propDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.propDialogFileName, style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              _currentName,
              style: TextStyle(fontSize: 12, color: ac.textSecondary),
            ),
            const SizedBox(height: 16),
            Text(l10n.propDialogLocation, style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              widget.task.publicPathLabel ?? widget.task.savePath,
              style: TextStyle(fontSize: 12, color: ac.textSecondary),
            ),
            const SizedBox(height: 16),
            Text(l10n.propDialogDownloadLink, style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              widget.task.url,
              style: TextStyle(fontSize: 12, color: ac.textSecondary),
            ),
            const SizedBox(height: 16),
            if (widget.task.sourcePageUrl != null) ...[
              Text(l10n.propDialogSourcePage, style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
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
          child: Text(l10n.propDialogClose),
        ),
      ],
    );
  }
}
