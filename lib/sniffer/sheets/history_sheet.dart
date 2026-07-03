import 'dart:async';

import 'package:flutter/material.dart';

import '../browser_library.dart';
import '../models/browser_tab.dart';
import 'library_sheet.dart';

/// Shows the browser-history bottom sheet for the given [activeTab] and
/// [library]. Standalone library — all state-mutating side effects are
/// delegated via callbacks so this function can be unit-tested in
/// isolation.
void showHistorySheet(
  BuildContext context, {
  required BrowserTab activeTab,
  required BrowserLibrary library,
  required Future<void> Function(BrowserLibrary) onSaveLibrary,
  required Future<void> Function(String url) onLoadUrl,
}) {
  showLibrarySheet<BrowserHistoryEntry>(
    context,
    title: 'History',
    emptyText: 'No history yet.',
    items: library.history,
    titleFor: (item) => item.title,
    subtitleFor: (item) => item.url,
    iconFor: (_) => Icons.history,
    onOpen: (item) =>
        unawaited(onLoadUrl(item.url)),
    onDelete: (item) => onSaveLibrary(
      library.copyWith(
        history: library.history
            .where((entry) => entry.url != item.url)
            .toList(growable: false),
      ),
    ),
  );
}
