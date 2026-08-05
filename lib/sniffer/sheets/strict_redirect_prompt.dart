import 'package:flutter/material.dart';

/// User choice from the blocked-redirect confirmation dialog.
enum RedirectPromptAction {
  foreground,
  background,
  currentTab,
  ignore,

  /// Persist a per-source-site block so future redirects from this source
  /// host to the target are cancelled silently (no prompt).
  alwaysBlock,
}

/// Queued redirect prompt for a background browser tab.
///
/// Shown only when that tab becomes active again (tab-aware UX).
class PendingStrictRedirectPrompt {
  final Uri uri;
  final String title;
  final String method;
  final String? sourcePageUrl;
  final String promptKey;

  const PendingStrictRedirectPrompt({
    required this.uri,
    required this.title,
    required this.method,
    required this.promptKey,
    this.sourcePageUrl,
  });
}

/// Compact blocked-redirect / popup prompt.
///
/// Returns the chosen [RedirectPromptAction], or `null` if dismissed.
///
/// Shown only while the *source* tab is active ("This tab" = that tab).
Future<RedirectPromptAction?> showStrictRedirectPromptDialog({
  required BuildContext context,
  required String title,
  required String targetHost,
  String? sourceHost,
}) {
  final isPopup = title.toLowerCase().contains('popup');
  final shortTitle = isPopup ? 'Popup blocked' : 'Redirect blocked';
  final subtitle = (sourceHost != null &&
          sourceHost.isNotEmpty &&
          sourceHost != targetHost)
      ? '$targetHost · from $sourceHost'
      : targetHost;

  return showDialog<RedirectPromptAction>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        buttonPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Text(shortTitle, style: theme.textTheme.titleMedium),
        content: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(RedirectPromptAction.alwaysBlock),
            child: Text(
              'Always block on this site',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(RedirectPromptAction.ignore),
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
            child: const Text('Here'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(RedirectPromptAction.foreground),
            child: const Text('New tab'),
          ),
        ],
      );
    },
  );
}
