import 'package:flutter/material.dart';

import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Sticky multi-select action bar for the Capture sheet.
///
/// Shown only when [selectedCount] > 0 (orchestrator gates visibility).
class CaptureBatchBar extends StatelessWidget {
  const CaptureBatchBar({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    required this.onToggleSelectAll,
    required this.onDownloadSelected,
  });

  final int selectedCount;
  final int totalCount;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onDownloadSelected;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isLight = context.isLight;
    final allSelected = totalCount > 0 && selectedCount == totalCount;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: isLight ? ac.surfacePanel : ac.surfaceElevated,
        border: Border(
          top: BorderSide(color: ac.borderHairline),
        ),
        boxShadow: isLight
            ? [
                BoxShadow(
                  color: ac.textPrimary.withValues(alpha: 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomInset),
        child: Row(
          children: [
            TextButton.icon(
              key: const Key('capture_select_all_button'),
              icon: Icon(
                allSelected ? Icons.check_box : Icons.select_all,
                color: ac.accentFrost,
              ),
              label: Text(
                allSelected ? 'Clear' : 'Select all',
                style: TextStyle(color: ac.accentFrost),
              ),
              onPressed: onToggleSelectAll,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$selectedCount selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: ac.textSecondary,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [ac.accentFrost, ac.mediaVideo],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: ac.accentFrost.withValues(alpha: 0.28),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ElevatedButton.icon(
                key: const Key('batch_download_btn'),
                icon: Icon(
                  Icons.download,
                  color: context.auroraColorScheme.onPrimary,
                ),
                label: Text(
                  'Download $selectedCount',
                  style: TextStyle(
                    color: context.auroraColorScheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: onDownloadSelected,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
