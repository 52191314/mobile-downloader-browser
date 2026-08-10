import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../downloader/models.dart';

/// Result of the duplicate download dialog.
class DuplicateDialogResult {
  final DuplicateChoice choice;
  final bool applyToAll;
  const DuplicateDialogResult({required this.choice, this.applyToAll = false});
}

/// Prompt when a download URL / same-page filename already exists in the queue.
///
/// Returns [DuplicateDialogResult] with the user's choice and whether to
/// apply that choice to all remaining duplicates in a batch.
///
/// When [showApplyToAll] is true, an "Apply to all duplicates" checkbox
/// is shown (batch download flows).
Future<DuplicateDialogResult> showDuplicateDownloadDialog({
  required BuildContext context,
  required String filename,
  bool showApplyToAll = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  var applyToAll = false;

  final result = await showDialog<DuplicateChoice>(
    context: context,
    builder: (BuildContext dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(l10n.dlgAlreadyInQueue),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.dlgDuplicateContent(filename)),
                if (showApplyToAll) ...[
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () => setDialogState(() => applyToAll = !applyToAll),
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: applyToAll,
                          onChanged: (v) => setDialogState(() => applyToAll = v ?? false),
                        ),
                        Flexible(child: Text(l10n.dlgApplyToAll)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(DuplicateChoice.skip),
                child: Text(l10n.dlgSkip),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(DuplicateChoice.replace),
                child: Text(l10n.dlgReplace),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(DuplicateChoice.createNew),
                child: Text(l10n.dlgCreateNew),
              ),
            ],
          );
        },
      );
    },
  );
  return DuplicateDialogResult(
    choice: result ?? DuplicateChoice.skip,
    applyToAll: applyToAll,
  );
}
