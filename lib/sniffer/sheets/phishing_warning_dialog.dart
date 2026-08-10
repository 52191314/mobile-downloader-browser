import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

import '../../theme/aurora_palette.dart';
import '../safe_browsing_service.dart';

/// Returns `true` if the user chooses to continue anyway.
Future<bool?> showPhishingWarningDialog({
  required BuildContext context,
  required Uri uri,
  required SafeBrowsingResult result,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber, color: Colors.redAccent),
          SizedBox(width: 8),
          Text('Phishing suspected'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(uri.toString()),
          const SizedBox(height: 8),
          Text(
            result.reason ??
                'This site is flagged as unsafe. Only open it if you are sure it is legitimate.',
            style: const TextStyle(fontSize: 12),
          ),
          if (result.source != null)
            Text(
              'Source: ${result.source}',
              style: TextStyle(fontSize: 11, color: ctx.ac.textSecondary),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Stay safe'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(AppLocalizations.of(context)!.dlgContinueAnyway),
        ),
      ],
    ),
  );
}
