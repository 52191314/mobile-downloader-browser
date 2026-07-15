import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../browser_library.dart';
import '../models/browser_tab.dart';
import 'library_sheet.dart';

/// Shows the saved-pages bottom sheet for the given [activeTab] and
/// [library]. Standalone library — all state-mutating side effects are
/// delegated via callbacks so this function can be unit-tested in
/// isolation.
///
/// [onLoadUrl] is part of the signature for symmetry with
/// `showHistorySheet` but is unused here because saved pages are opened
/// via `loadFile` (a local file) rather than an HTTP URL.
void showSavedPagesSheet(
  BuildContext context, {
  required BrowserTab activeTab,
  required BrowserLibrary library,
  required Future<void> Function(BrowserLibrary) onSaveLibrary,
  required Future<void> Function(String url) onLoadUrl,
  required Future<void> Function() onSaveCurrentPage,
  required void Function() onReopen,
}) {
  showLibrarySheet<SavedPage>(
    context,
    title: 'Saved Pages',
    emptyText: 'No saved pages yet. Save a page to read offline.',
    items: library.savedPages,
    titleFor: (item) => item.title,
    subtitleFor: (item) => item.sourceUrl,
    iconFor: (_) => Icons.offline_pin,
    onOpen: (item) => activeTab.controller.loadFile(item.localPath),
    onDelete: (item) async {
      await onSaveLibrary(
        library.copyWith(
          savedPages: library.savedPages
              .where((page) => page.id != item.id)
              .toList(growable: false),
        ),
      );
      final file = File(item.localPath);
      if (await file.exists()) await file.delete();
      onReopen();
    },
    action: TextButton.icon(
      icon: const Icon(Icons.download_done),
      label: const Text('Save Page'),
      onPressed: () async {
        Navigator.pop(context);
        await onSaveCurrentPage();
        onReopen();
      },
    ),
  );
}
