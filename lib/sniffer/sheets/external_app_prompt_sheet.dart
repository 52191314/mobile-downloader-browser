import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../../ui/pages/settings_page.dart';
import '../external_scheme.dart';

/// Confirms opening an external app / deep link from the in-app browser.
///
/// Default: ask every time. Optional "Don't ask again for this app" applies
/// to whichever primary action the user picks (Open → always allow,
/// Don't open → always deny).
Future<ExternalAppPromptResult> showExternalAppPromptSheet({
  required BuildContext context,
  required String displayName,
  required Uri uri,
  String? pageHost,
  VoidCallback? onOpenSettings,
}) async {
  final ac = AuroraPalette.of(context);
  var remember = false;

  void openSettingsPage(BuildContext ctx) {
    Navigator.pop(ctx, ExternalAppPromptResult.denyOnce);
    if (onOpenSettings != null) {
      onOpenSettings();
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const ExternalAppsPrefsPage(),
        ),
      );
    }
  }

  final result = await showModalBottomSheet<ExternalAppPromptResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ac.surfaceElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setModalState) {
            final linkPreview = uri.toString();
            final shortLink = linkPreview.length > 120
                ? '${linkPreview.substring(0, 117)}…'
                : linkPreview;

            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ac.textSecondary.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: ac.accentFrost.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.open_in_new_rounded,
                          color: ac.accentFrost,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Open in $displayName?',
                              style: TextStyle(
                                color: ac.textPrimary,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (pageHost != null && pageHost.isNotEmpty)
                              Text(
                                'Requested by $pageHost',
                                style: TextStyle(
                                  color: ac.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'External app settings',
                        icon: Icon(
                          Icons.settings_outlined,
                          color: ac.textSecondary,
                        ),
                        onPressed: () => openSettingsPage(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ac.surfaceElevated.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: ac.textSecondary.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Text(
                      shortLink,
                      style: TextStyle(
                        color: ac.textSecondary,
                        fontSize: 12,
                        fontFamily: 'JetBrains Mono',
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: remember,
                    onChanged: (v) {
                      setModalState(() => remember = v ?? false);
                    },
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: ac.accentFrost,
                    title: Text(
                      "Don't ask again for $displayName",
                      style: TextStyle(
                        color: ac.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            remember
                                ? 'Applies to Open and Don\'t open'
                                : 'You can change this later in Settings',
                            style: TextStyle(
                              color: ac.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => openSettingsPage(ctx),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              'Manage apps',
                              style: TextStyle(
                                color: ac.accentFrost,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.pop(
                              ctx,
                              remember
                                  ? ExternalAppPromptResult.alwaysDeny
                                  : ExternalAppPromptResult.denyOnce,
                            );
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: ac.textPrimary,
                            side: BorderSide(
                              color: ac.textSecondary.withValues(alpha: 0.35),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text("Don't open"),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () {
                            Navigator.pop(
                              ctx,
                              remember
                                  ? ExternalAppPromptResult.alwaysOpen
                                  : ExternalAppPromptResult.openOnce,
                            );
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: ac.accentFrost,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Open'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );

  return result ?? ExternalAppPromptResult.denyOnce;
}
