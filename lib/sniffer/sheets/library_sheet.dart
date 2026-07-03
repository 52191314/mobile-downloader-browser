import 'dart:async';

import 'package:flutter/material.dart';

/// Generic bottom sheet used to list library entries of any type
/// (e.g. saved pages, history) with open / delete actions.
///
/// This is a standalone library (NOT `part of sniffer_screen.dart`) so it
/// can be unit-tested and reused. All dependencies are passed explicitly.
void showLibrarySheet<T>(
  BuildContext context, {
  required String title,
  required String emptyText,
  required List<T> items,
  required String Function(T item) titleFor,
  required String Function(T item) subtitleFor,
  required IconData Function(T item) iconFor,
  required FutureOr<void> Function(T item) onOpen,
  required FutureOr<void> Function(T item) onDelete,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          children: [
            ListTile(title: Text(title)),
            Expanded(
              child: items.isEmpty
                  ? Center(child: Text(emptyText))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (listContext, index) {
                        final item = items[index];
                        return ListTile(
                          leading: Icon(iconFor(item)),
                          title: Text(
                            titleFor(item),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            subtitleFor(item),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            Navigator.pop(listContext);
                            unawaited(Future<void>.value(onOpen(item)));
                          },
                          trailing: IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              Navigator.pop(listContext);
                              unawaited(Future<void>.value(onDelete(item)));
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}
