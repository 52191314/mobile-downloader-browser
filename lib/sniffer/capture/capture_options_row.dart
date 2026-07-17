import 'package:flutter/material.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Capture Options zone: show-all toggle + sort + display-mode dropdowns.
///
/// Persists via [onSettingsChanged] into existing [DownloadSettings] fields
/// (`captureShowAllMedia`, `sniffedMediaSort`, `sniffedMediaDisplayMode`).
/// Show-all copy is fixed (Key Decision 26).
class CaptureOptionsRow extends StatelessWidget {
  const CaptureOptionsRow({
    super.key,
    required this.settings,
    required this.showAll,
    required this.onShowAllChanged,
    required this.onSettingsChanged,
  });

  final DownloadSettings settings;
  final bool showAll;
  final ValueChanged<bool> onShowAllChanged;
  final ValueChanged<DownloadSettings>? onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            key: const Key('capture_show_all_switch'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeTrackColor: ac.accentFrost,
            secondary: Icon(
              Icons.tune,
              size: 20,
              color: ac.textSecondary,
            ),
            title: Text(
              'Show all captured media',
              style: TextStyle(
                fontSize: 13,
                color: ac.textPrimary,
              ),
            ),
            subtitle: Text(
              showAll
                  ? 'Show every detected URL, including non-media assets'
                  : 'Show only URLs that look like playable media',
              style: TextStyle(
                fontSize: 11,
                color: ac.textSecondary,
              ),
            ),
            value: showAll,
            onChanged: onShowAllChanged,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _TokenDropdown<SniffedMediaSort>(
                  key: const Key('capture_sort_dropdown'),
                  label: 'Sort by',
                  value: settings.sniffedMediaSort,
                  items: SniffedMediaSort.values,
                  itemLabel: (sort) => sort.name,
                  onChanged: onSettingsChanged == null
                      ? null
                      : (value) {
                          onSettingsChanged!(
                            settings.copyWith(sniffedMediaSort: value),
                          );
                        },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TokenDropdown<SniffedMediaDisplayMode>(
                  key: const Key('capture_display_mode_dropdown'),
                  label: 'Show type',
                  value: settings.sniffedMediaDisplayMode,
                  items: SniffedMediaDisplayMode.values,
                  itemLabel: (mode) => mode.name,
                  onChanged: onSettingsChanged == null
                      ? null
                      : (value) {
                          onSettingsChanged!(
                            settings.copyWith(sniffedMediaDisplayMode: value),
                          );
                        },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Controlled dense dropdown with Aurora field tokens (avoids FormField
/// initialValue deprecation while remaining fully controlled).
class _TokenDropdown<T> extends StatelessWidget {
  const _TokenDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final radius = BorderRadius.circular(8);

    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: ac.surfaceField,
        labelStyle: TextStyle(
          fontSize: 12,
          color: ac.textSecondary,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: ac.borderHairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: ac.accentFrost),
        ),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: ac.borderHairline),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: ac.surfacePanel,
          style: TextStyle(
            fontSize: 13,
            color: ac.textPrimary,
          ),
          iconEnabledColor: ac.textSecondary,
          items: items
              .map(
                (item) => DropdownMenuItem<T>(
                  value: item,
                  child: Text(itemLabel(item)),
                ),
              )
              .toList(),
          onChanged: onChanged == null
              ? null
              : (next) {
                  if (next == null) return;
                  onChanged!(next);
                },
        ),
      ),
    );
  }
}

