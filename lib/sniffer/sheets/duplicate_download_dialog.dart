import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

import '../../downloader/models.dart';

/// Prompt when a download URL / same-page filename already exists in the queue.
Future<DuplicateChoice> showDuplicateDownloadDialog({
  required BuildContext context,
  required String filename,
}) async {
  final result = await showDialog<DuplicateChoice>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: Text(AppLocalizations.of(context)!.dlgAlreadyInQueue),
        content: Text(
          'This download link has already been added to your queue.\n\n'
          'The URL may have changed (token refresh). Update the existing '
          'download with the new link, or create a separate one.\n\n'
          'File: $filename',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(DuplicateChoice.skip),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(DuplicateChoice.downloadAgain),
            child: Text(AppLocalizations.of(context)!.dlgCreateNew),
          ),
          TextButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(DuplicateChoice.updateExisting),
            child: Text(AppLocalizations.of(context)!.dlgUpdateExisting),
          ),
        ],
      );
    },
  );
  return result ?? DuplicateChoice.skip;
}
