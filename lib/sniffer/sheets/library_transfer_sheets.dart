import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// User selections from the export bottom sheet.
class LibraryExportOptions {
  final bool favorites;
  final bool history;
  final bool savedPages;
  final bool queue;
  final bool settings;
  final bool tabs;

  const LibraryExportOptions({
    this.favorites = true,
    this.history = true,
    this.savedPages = true,
    this.queue = true,
    this.settings = true,
    this.tabs = true,
  });

  bool get anySelected =>
      favorites || history || savedPages || queue || settings || tabs;
}

/// User selections from the import bottom sheet.
class LibraryImportOptions {
  final bool favorites;
  final bool history;
  final bool savedPages;
  final bool queue;
  final bool settings;
  final bool tabs;

  const LibraryImportOptions({
    this.favorites = false,
    this.history = false,
    this.savedPages = false,
    this.queue = false,
    this.settings = false,
    this.tabs = false,
  });

  bool get anySelected =>
      favorites || history || savedPages || queue || settings || tabs;
}

/// Shows the export category picker. Returns null if cancelled.
Future<LibraryExportOptions?> showLibraryExportOptionsSheet({
  required BuildContext context,
  required int favoritesCount,
  required int foldersCount,
  required int historyCount,
  required int savedPagesCount,
  required int queueTaskCount,
  required int openTabsCount,
}) {
  var options = const LibraryExportOptions();
  return showModalBottomSheet<LibraryExportOptions>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.file_upload_outlined,
                        color: context.ac.accentFrost,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Export your data',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: context.ac.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _switchTile(
                    context,
                    title: 'Favorites',
                    subtitle:
                        '$favoritesCount favorites, $foldersCount folders',
                    value: options.favorites,
                    onChanged: (val) => setModalState(
                      () => options = LibraryExportOptions(
                        favorites: val,
                        history: options.history,
                        savedPages: options.savedPages,
                        queue: options.queue,
                        settings: options.settings,
                        tabs: options.tabs,
                      ),
                    ),
                  ),
                  _switchTile(
                    context,
                    title: 'Web History',
                    subtitle: '$historyCount history entries',
                    value: options.history,
                    onChanged: (val) => setModalState(
                      () => options = LibraryExportOptions(
                        favorites: options.favorites,
                        history: val,
                        savedPages: options.savedPages,
                        queue: options.queue,
                        settings: options.settings,
                        tabs: options.tabs,
                      ),
                    ),
                  ),
                  _switchTile(
                    context,
                    title: 'Saved Pages',
                    subtitle: '$savedPagesCount offline pages',
                    value: options.savedPages,
                    onChanged: (val) => setModalState(
                      () => options = LibraryExportOptions(
                        favorites: options.favorites,
                        history: options.history,
                        savedPages: val,
                        queue: options.queue,
                        settings: options.settings,
                        tabs: options.tabs,
                      ),
                    ),
                  ),
                  _switchTile(
                    context,
                    title: 'Download History',
                    subtitle: '$queueTaskCount tasks',
                    value: options.queue,
                    onChanged: (val) => setModalState(
                      () => options = LibraryExportOptions(
                        favorites: options.favorites,
                        history: options.history,
                        savedPages: options.savedPages,
                        queue: val,
                        settings: options.settings,
                        tabs: options.tabs,
                      ),
                    ),
                  ),
                  _switchTile(
                    context,
                    title: 'App Settings',
                    subtitle:
                        'Toggles, concurrent limits, search engine defaults',
                    value: options.settings,
                    onChanged: (val) => setModalState(
                      () => options = LibraryExportOptions(
                        favorites: options.favorites,
                        history: options.history,
                        savedPages: options.savedPages,
                        queue: options.queue,
                        settings: val,
                        tabs: options.tabs,
                      ),
                    ),
                  ),
                  _switchTile(
                    context,
                    title: 'Open Tabs',
                    subtitle: '$openTabsCount open tab(s)',
                    value: options.tabs,
                    onChanged: (val) => setModalState(
                      () => options = LibraryExportOptions(
                        favorites: options.favorites,
                        history: options.history,
                        savedPages: options.savedPages,
                        queue: options.queue,
                        settings: options.settings,
                        tabs: val,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          'Cancel',
                          style: TextStyle(color: context.ac.textSecondary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        key: const Key('confirm_export_button'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.ac.accentFrost,
                          foregroundColor: context.ac.surfaceField,
                        ),
                        onPressed: !options.anySelected
                            ? null
                            : () => Navigator.pop(ctx, options),
                        child: const Text('Export'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Shows the import category picker. Returns null if cancelled.
Future<LibraryImportOptions?> showLibraryImportOptionsSheet({
  required BuildContext context,
  required bool hasFavorites,
  required bool hasHistory,
  required bool hasSavedPages,
  required bool hasQueue,
  required bool hasSettings,
  bool hasTabs = false,
  required bool isLegacy,
}) {
  var options = LibraryImportOptions(
    favorites: hasFavorites || isLegacy,
    history: hasHistory || isLegacy,
    savedPages: hasSavedPages || isLegacy,
    queue: hasQueue,
    settings: hasSettings,
    tabs: hasTabs,
  );
  if (!hasFavorites && !isLegacy) {
    options = LibraryImportOptions(
      favorites: false,
      history: options.history,
      savedPages: options.savedPages,
      queue: options.queue,
      settings: options.settings,
      tabs: options.tabs,
    );
  }
  if (!hasHistory && !isLegacy) {
    options = LibraryImportOptions(
      favorites: options.favorites,
      history: false,
      savedPages: options.savedPages,
      queue: options.queue,
      settings: options.settings,
      tabs: options.tabs,
    );
  }
  if (!hasSavedPages && !isLegacy) {
    options = LibraryImportOptions(
      favorites: options.favorites,
      history: options.history,
      savedPages: false,
      queue: options.queue,
      settings: options.settings,
      tabs: options.tabs,
    );
  }

  return showModalBottomSheet<LibraryImportOptions>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.file_download_outlined,
                        color: context.ac.accentFrost,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Import your data',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: context.ac.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _switchTile(
                    context,
                    title: 'Favorites / Bookmarks',
                    value: options.favorites,
                    onChanged: (hasFavorites || isLegacy)
                        ? (val) => setModalState(
                              () => options = LibraryImportOptions(
                                favorites: val,
                                history: options.history,
                                savedPages: options.savedPages,
                                queue: options.queue,
                                settings: options.settings,
                                tabs: options.tabs,
                              ),
                            )
                        : null,
                  ),
                  _switchTile(
                    context,
                    title: 'Web History',
                    value: options.history,
                    onChanged: (hasHistory || isLegacy)
                        ? (val) => setModalState(
                              () => options = LibraryImportOptions(
                                favorites: options.favorites,
                                history: val,
                                savedPages: options.savedPages,
                                queue: options.queue,
                                settings: options.settings,
                                tabs: options.tabs,
                              ),
                            )
                        : null,
                  ),
                  _switchTile(
                    context,
                    title: 'Saved Pages',
                    value: options.savedPages,
                    onChanged: (hasSavedPages || isLegacy)
                        ? (val) => setModalState(
                              () => options = LibraryImportOptions(
                                favorites: options.favorites,
                                history: options.history,
                                savedPages: val,
                                queue: options.queue,
                                settings: options.settings,
                                tabs: options.tabs,
                              ),
                            )
                        : null,
                  ),
                  _switchTile(
                    context,
                    title: 'Download History (Queue)',
                    value: options.queue,
                    onChanged: hasQueue
                        ? (val) => setModalState(
                              () => options = LibraryImportOptions(
                                favorites: options.favorites,
                                history: options.history,
                                savedPages: options.savedPages,
                                queue: val,
                                settings: options.settings,
                                tabs: options.tabs,
                              ),
                            )
                        : null,
                  ),
                  _switchTile(
                    context,
                    title: 'App Settings',
                    value: options.settings,
                    onChanged: hasSettings
                        ? (val) => setModalState(
                              () => options = LibraryImportOptions(
                                favorites: options.favorites,
                                history: options.history,
                                savedPages: options.savedPages,
                                queue: options.queue,
                                settings: val,
                                tabs: options.tabs,
                              ),
                            )
                        : null,
                  ),
                  if (hasTabs)
                    _switchTile(
                      context,
                      title: 'Open Tabs',
                      value: options.tabs,
                      onChanged: (val) => setModalState(
                        () => options = LibraryImportOptions(
                          favorites: options.favorites,
                          history: options.history,
                          savedPages: options.savedPages,
                          queue: options.queue,
                          settings: options.settings,
                          tabs: val,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          'Cancel',
                          style: TextStyle(color: context.ac.textSecondary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.ac.accentFrost,
                          foregroundColor: context.ac.surfaceField,
                        ),
                        onPressed: !options.anySelected
                            ? null
                            : () => Navigator.pop(ctx, options),
                        child: const Text('Import'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

Widget _switchTile(
  BuildContext context, {
  required String title,
  String? subtitle,
  required bool value,
  required ValueChanged<bool>? onChanged,
}) {
  return SwitchListTile(
    activeThumbColor: context.ac.accentFrost,
    title: Text(title, style: TextStyle(color: context.ac.textPrimary)),
    subtitle: subtitle == null
        ? null
        : Text(subtitle, style: TextStyle(color: context.ac.textSecondary)),
    value: value,
    onChanged: onChanged,
  );
}
