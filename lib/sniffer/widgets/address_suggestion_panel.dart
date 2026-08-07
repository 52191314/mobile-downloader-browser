import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../models/address_suggestion.dart';

/// Address-bar typeahead suggestion panel rendered as an overlay above
/// the bottom chrome.  Shows search suggestions, history entries, and
/// bookmarked URLs.
///
/// Extracted from `_SnifferScreenState._buildSuggestionPanel`.
class AddressSuggestionPanel extends StatelessWidget {
  final List<AddressSuggestion> suggestions;
  final void Function(AddressSuggestion) onAccept;
  final String searchEngineName;
  final bool allowScroll;

  /// Fixed height for each suggestion row (compact).
  static const double rowHeight = 44.0;

  const AddressSuggestionPanel({
    super.key,
    required this.suggestions,
    required this.onAccept,
    required this.searchEngineName,
    this.allowScroll = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const Key('address_suggestion_panel'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: suggestions.length,
      physics: allowScroll
          ? const ClampingScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      itemBuilder: (context, i) {
        final suggestion = suggestions[i];
        final icon = switch (suggestion.kind) {
          AddressSuggestionKind.favorite => Icons.star_rounded,
          AddressSuggestionKind.history => Icons.history_rounded,
          AddressSuggestionKind.search => Icons.search_rounded,
        };
        final subtitle = switch (suggestion.kind) {
          AddressSuggestionKind.search => searchEngineName,
          AddressSuggestionKind.favorite ||
          AddressSuggestionKind.history =>
            () {
              final host = Uri.tryParse(suggestion.url)?.host;
              return (host != null && host.isNotEmpty) ? host : suggestion.url;
            }(),
        };
        return InkWell(
          onTap: () => onAccept(suggestion),
          child: Container(
            height: rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.ac.surfaceElevated,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: context.ac.accentFrost),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        suggestion.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: context.ac.textPrimary,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: context.ac.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
