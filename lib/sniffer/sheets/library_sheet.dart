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
  Widget? action,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      return _LibrarySheetContent<T>(
        title: title,
        emptyText: emptyText,
        items: items,
        titleFor: titleFor,
        subtitleFor: subtitleFor,
        iconFor: iconFor,
        onOpen: onOpen,
        onDelete: onDelete,
        action: action,
      );
    },
  );
}

class _LibrarySheetContent<T> extends StatefulWidget {
  final String title;
  final String emptyText;
  final List<T> items;
  final String Function(T item) titleFor;
  final String Function(T item) subtitleFor;
  final IconData Function(T item) iconFor;
  final FutureOr<void> Function(T item) onOpen;
  final FutureOr<void> Function(T item) onDelete;
  final Widget? action;

  const _LibrarySheetContent({
    required this.title,
    required this.emptyText,
    required this.items,
    required this.titleFor,
    required this.subtitleFor,
    required this.iconFor,
    required this.onOpen,
    required this.onDelete,
    this.action,
  });

  @override
  State<_LibrarySheetContent<T>> createState() => _LibrarySheetContentState<T>();
}

class _LibrarySheetContentState<T> extends State<_LibrarySheetContent<T>> {
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredItems = widget.items.where((item) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      final titleMatch = widget.titleFor(item).toLowerCase().contains(q);
      final subtitleMatch = widget.subtitleFor(item).toLowerCase().contains(q);
      return titleMatch || subtitleMatch;
    }).toList();

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: Row(
              children: [
                Expanded(
                  child: _isSearching
                      ? TextField(
                          controller: _searchController,
                          autofocus: true,
                          decoration: InputDecoration(
                            hintText: 'Search ${widget.title.toLowerCase()}...',
                            border: InputBorder.none,
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() {
                                  _searchController.clear();
                                  _searchQuery = '';
                                });
                              },
                            ),
                          ),
                          onChanged: (val) {
                            setState(() {
                              _searchQuery = val;
                            });
                          },
                        )
                      : Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
                if (widget.action != null && !_isSearching) ...[
                  widget.action!,
                  const SizedBox(width: 8),
                ],
                IconButton(
                  tooltip: _isSearching ? 'Close search' : 'Search',
                  icon: Icon(_isSearching ? Icons.close : Icons.search),
                  onPressed: () {
                    setState(() {
                      _isSearching = !_isSearching;
                      if (!_isSearching) {
                        _searchController.clear();
                        _searchQuery = '';
                      }
                    });
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filteredItems.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Text(
                        _searchQuery.isEmpty
                            ? widget.emptyText
                            : 'No items match your search.',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: filteredItems.length,
                    itemBuilder: (listContext, index) {
                      final item = filteredItems[index];
                      return ListTile(
                        leading: Icon(widget.iconFor(item)),
                        title: Text(
                          widget.titleFor(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          widget.subtitleFor(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          Navigator.pop(listContext);
                          unawaited(Future<void>.value(widget.onOpen(item)));
                        },
                        trailing: IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            Navigator.pop(listContext);
                            unawaited(Future<void>.value(widget.onDelete(item)));
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
