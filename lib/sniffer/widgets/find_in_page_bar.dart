import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

import '../../theme/aurora_palette.dart';

/// Compact find-in-page toolbar for the browser strip.
class FindInPageBar extends StatelessWidget {
  final TextEditingController controller;
  final int matchCount;
  final int currentMatch;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onFindNext;
  final VoidCallback onFindPrevious;
  final VoidCallback onClose;

  const FindInPageBar({
    super.key,
    required this.controller,
    required this.matchCount,
    required this.currentMatch,
    required this.onQueryChanged,
    required this.onFindNext,
    required this.onFindPrevious,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54.0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.ac.overlaySurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.ac.borderStrong),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: AppLocalizations.of(context)!.btnFindInPage,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixText: matchCount > 0
                          ? '${currentMatch + 1}/$matchCount'
                          : null,
                    ),
                    onChanged: onQueryChanged,
                    onSubmitted: (_) => onFindNext(),
                  ),
                ),
                IconButton(
                  tooltip: 'Previous',
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: onFindPrevious,
                ),
                IconButton(
                  tooltip: 'Next',
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: onFindNext,
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
