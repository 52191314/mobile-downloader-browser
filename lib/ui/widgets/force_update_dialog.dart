import 'package:flutter/material.dart';
import '../../platform/app_update_service.dart';
import '../../theme/aurora_palette.dart';

/// A Nordic-themed modal dialog prompting the user to update the app.
///
/// If [isMandatory] is true (Supercell-style force update):
/// - The dialog cannot be dismissed via back button or clicking outside.
/// - The user must tap "Update on Google Play" to proceed.
class ForceUpdateDialog extends StatelessWidget {
  final AppUpdateInfo? updateInfo;
  final bool isMandatory;
  final VoidCallback? onUpdateTap;

  const ForceUpdateDialog({
    super.key,
    this.updateInfo,
    this.isMandatory = false,
    this.onUpdateTap,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final accentColor = isMandatory ? const Color(0xFFBF616A) : ac.accentFrost;

    return PopScope(
      canPop: !isMandatory,
      child: AlertDialog(
        backgroundColor: ac.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isMandatory
                ? const Color(0xFFBF616A).withValues(alpha: 0.5)
                : ac.borderHairline,
          ),
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isMandatory
                    ? Icons.security_update_warning_rounded
                    : Icons.system_update_rounded,
                color: accentColor,
                size: 28,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMandatory ? 'Update Required' : 'Update Available',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: ac.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    updateInfo != null && updateInfo!.availableVersionCode > 0
                        ? 'Google Play Build ${updateInfo!.availableVersionCode}'
                        : 'Google Play Release',
                    style: TextStyle(
                      fontSize: 12,
                      color: ac.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isMandatory
                  ? 'A newer version of Aurora Download Manager is required to continue. Please update via Google Play to ensure compatibility with streaming and media detection services.'
                  : 'A new version of Aurora Download Manager is available on Google Play with new enhancements, performance improvements, and bug fixes.',
              style: TextStyle(
                fontSize: 13,
                color: ac.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: ac.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ac.borderHairline),
              ),
              child: Row(
                children: [
                  Icon(Icons.verified_user_outlined, size: 16, color: accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isMandatory
                          ? 'Critical updates and fixes included'
                          : 'Official Google Play update',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: ac.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (!isMandatory)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Later',
                style: TextStyle(color: ac.textSecondary),
              ),
            ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: accentColor,
              foregroundColor: isMandatory ? Colors.white : Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () {
              if (onUpdateTap != null) {
                onUpdateTap!();
              } else {
                AppUpdateService.instance.openPlayStore();
              }
            },
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text(
              'Update Now',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
