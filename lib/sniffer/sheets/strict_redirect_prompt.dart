import 'package:flutter/material.dart';

/// User choice from the blocked-redirect confirmation dialog.
enum RedirectPromptAction { foreground, background, currentTab, ignore }

/// Shows the strict / invisible-redirect prompt.
///
/// Returns the chosen [RedirectPromptAction], or `null` if dismissed.
Future<RedirectPromptAction?> showStrictRedirectPromptDialog({
  required BuildContext context,
  required String title,
  required String targetHost,
  required String method,
  String? sourceHost,
}) {
  return showDialog<RedirectPromptAction>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.block, color: Colors.redAccent),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            targetHost,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (sourceHost != null && sourceHost.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'From $sourceHost',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            method,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(RedirectPromptAction.ignore),
          child: const Text('Ignore'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(ctx).pop(RedirectPromptAction.background),
          child: const Text('Background'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(ctx).pop(RedirectPromptAction.currentTab),
          child: const Text('Current tab'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(ctx).pop(RedirectPromptAction.foreground),
          child: const Text('New page'),
        ),
      ],
    ),
  );
}
