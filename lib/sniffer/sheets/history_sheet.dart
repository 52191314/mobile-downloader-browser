import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

import '../../premium/pro_entitlement.dart';
import '../../premium/pro_upsell_sheet.dart';
import '../browser_library.dart';
import '../models/browser_tab.dart';
import '../video_library.dart';
import 'video_library_views.dart';

/// Shows the browser-history bottom sheet with multi-select, range-select,
/// and "open all selected" support.
///
/// **Selection modes:**
/// - **Swipe-down gesture** on a row → toggles that single item's selection
///   (quick downward flick; scrolls pass through normally).
/// - **Long press** first row → enters selection mode + sets range anchor.
/// - **Long press** another row → selects range from anchor to that row.
/// - **Tap** when in selection mode → toggles that item's selection.
/// - **Tap** when NOT in selection mode → opens the URL (existing behaviour).
void showHistorySheet(
  BuildContext context, {
  required BrowserTab activeTab,
  required BrowserLibrary library,
  required Future<void> Function(BrowserLibrary) onSaveLibrary,
  required Future<void> Function(String url) onLoadUrl,
  /// Called when the user wants to open multiple URLs, each in its own
  /// new tab.  The list is already deduplicated (unique URLs only).
  required Future<void> Function(List<String> urls) onOpenUrlsInNewTabs,
  /// Replays a watched video. Null falls back to loading its URL as a page.
  Future<void> Function(BrowserHistoryEntry entry)? onPlayVideo,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _HistorySheetContent(
      library: library,
      onSaveLibrary: onSaveLibrary,
      onLoadUrl: onLoadUrl,
      onOpenUrlsInNewTabs: onOpenUrlsInNewTabs,
      onPlayVideo: onPlayVideo,
    ),
  );
}

class _HistorySheetContent extends StatefulWidget {
  final BrowserLibrary library;
  final Future<void> Function(BrowserLibrary) onSaveLibrary;
  final Future<void> Function(String url) onLoadUrl;
  final Future<void> Function(List<String> urls) onOpenUrlsInNewTabs;
  final Future<void> Function(BrowserHistoryEntry entry)? onPlayVideo;

  const _HistorySheetContent({
    required this.library,
    required this.onSaveLibrary,
    required this.onLoadUrl,
    required this.onOpenUrlsInNewTabs,
    this.onPlayVideo,
  });

  @override
  State<_HistorySheetContent> createState() => _HistorySheetContentState();
}

class _HistorySheetContentState extends State<_HistorySheetContent> {
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // ---------------------------------------------------------------------------
  // Selection state
  // ---------------------------------------------------------------------------
  bool _selectionMode = false;
  final Set<String> _selectedUrls = {};
  int? _rangeAnchorIndex;

  LibrarySection _section = LibrarySection.sites;

  BrowserLibrary get _library => widget.library;

  /// Page visits only. Selection, range-select and search all operate on this
  /// list, so scoping it here keeps the whole existing interaction correct
  /// without touching any of it.
  List<BrowserHistoryEntry> get _items => _library.siteHistory;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  List<BrowserHistoryEntry> get _filteredItems {
    if (_searchQuery.isEmpty) return _items;
    final q = _searchQuery.toLowerCase();
    return _items.where((e) {
      return e.title.toLowerCase().contains(q) ||
          e.url.toLowerCase().contains(q);
    }).toList();
  }

  void _enterSelectionMode(BrowserHistoryEntry item, int index) {
    setState(() {
      _selectionMode = true;
      _selectedUrls.add(item.url);
      _rangeAnchorIndex = index;
    });
  }

  void _toggleSelection(BrowserHistoryEntry item) {
    setState(() {
      if (_selectedUrls.contains(item.url)) {
        _selectedUrls.remove(item.url);
        if (_selectedUrls.isEmpty) {
          _selectionMode = false;
          _rangeAnchorIndex = null;
        }
      } else {
        _selectedUrls.add(item.url);
      }
    });
  }

  /// Called on long press / range-select gesture.
  void _handleLongPress(BrowserHistoryEntry item, int index) {
    if (!_selectionMode) {
      // First long press → enter selection mode
      _enterSelectionMode(item, index);
      return;
    }

    // Already in selection mode
    if (_rangeAnchorIndex == null) {
      // Set anchor
      setState(() {
        _rangeAnchorIndex = index;
        if (!_selectedUrls.contains(item.url)) {
          _selectedUrls.add(item.url);
        }
      });
      return;
    }

    // Range selection: select everything between anchor and this index
    final start = _rangeAnchorIndex! < index ? _rangeAnchorIndex! : index;
    final end = _rangeAnchorIndex! < index ? index : _rangeAnchorIndex!;
    setState(() {
      for (var i = start; i <= end; i++) {
        if (i >= 0 && i < _filteredItems.length) {
          _selectedUrls.add(_filteredItems[i].url);
        }
      }
      // Clear anchor after range selection so the next long press sets a
      // fresh anchor.
      _rangeAnchorIndex = null;
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedUrls.clear();
      _rangeAnchorIndex = null;
    });
  }

  void _openAllSelected() {
    if (_selectedUrls.isEmpty) return;
    // Deduplicate — a Set already guarantees uniqueness, so just drain it.
    final urls = _selectedUrls.toList(growable: false);
    _exitSelectionMode();
    Navigator.pop(context);
    unawaited(widget.onOpenUrlsInNewTabs(urls));
  }

  void _openItem(BrowserHistoryEntry item) {
    Navigator.pop(context);
    unawaited(widget.onLoadUrl(item.url));
  }

  void _deleteItem(BrowserHistoryEntry item) {
    Navigator.pop(context);
    unawaited(
      widget.onSaveLibrary(
        _library.copyWith(
          // Match on kind too: a page and a video can share a URL, and
          // deleting a site row must not silently take the video with it.
          history: _library.history
              .where((e) => !(e.url == item.url && e.kind == item.kind))
              .toList(growable: false),
        ),
      ),
    );
  }

  void _deleteAllSelected() {
    // Selection only ever contains site rows — leave video history alone.
    final remaining = _library.history
        .where((e) =>
            e.kind != LibraryEntryKind.site || !_selectedUrls.contains(e.url))
        .toList(growable: false);
    _exitSelectionMode();
    unawaited(
      widget.onSaveLibrary(_library.copyWith(history: remaining)),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredItems;

    return SafeArea(
      child: Column(
        children: [
          // ---- Header ----
          _buildHeader(filtered.length),

          LibrarySectionBar(
            current: _section,
            videoCount: _library.videoHistory.length,
            onChanged: (s) => setState(() {
              _section = s;
              // Selection is a sites-list concept; carrying it across would
              // leave an action bar acting on rows that are not visible.
              _selectionMode = false;
              _selectedUrls.clear();
              _rangeAnchorIndex = null;
            }),
          ),

          const Divider(height: 1),

          if (_section == LibrarySection.videos)
            Expanded(child: _buildVideosSection())
          else ...[
            // ---- Selection action bar ----
            if (_selectionMode && _selectedUrls.isNotEmpty)
              _buildSelectionBar(),

            // ---- List ----
            Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Text(
                        _searchQuery.isEmpty
                            ? 'No history yet. Browsed pages appear here automatically.'
                            : 'No items match your search.',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : ListView.builder(
                    key: ValueKey('history_list_${_selectionMode}'),
                    itemCount: filtered.length,
                    itemBuilder: (_, index) {
                      final item = filtered[index];
                      final isSelected = _selectedUrls.contains(item.url);
                      return _HistoryRow(
                        item: item,
                        index: index,
                        isSelected: isSelected,
                        selectionMode: _selectionMode,
                        onTap: () {
                          if (_selectionMode) {
                            _toggleSelection(item);
                          } else {
                            _openItem(item);
                          }
                        },
                        onLongPress: () => _handleLongPress(item, index),
                        onSwipeSelect: () => _toggleSelection(item),
                        onDelete: () => _deleteItem(item),
                      );
                    },
                  ),
            ),
          ],
        ],
      ),
    );
  }

  /// Watch history. No selection mode — the multi-select flow exists to open
  /// many pages in tabs, which does not translate to replaying videos.
  Widget _buildVideosSection() {
    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    final limit = VideoLibrary.freeLimitFor(tier);
    final videos = _library.videoHistory;

    return Column(
      children: [
        if (limit != null)
          VideoGateBanner(
            used: videos.length,
            limit: limit,
            tier: tier,
            message: 'Pro keeps your full watch history',
          ),
        Expanded(
          child: VideoHistoryList(
            items: videos,
            onOpen: (entry) async {
              Navigator.pop(context);
              final play = widget.onPlayVideo;
              if (play != null) {
                await play(entry);
              } else {
                await widget.onLoadUrl(entry.url);
              }
            },
            onOpenSourcePage: (entry) {
              Navigator.pop(context);
              unawaited(widget.onLoadUrl(entry.sourcePageUrl!));
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(int totalCount) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Row(
        children: [
          Expanded(
            child: _isSearching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: AppLocalizations.of(context)!.historySearch,
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
                      setState(() => _searchQuery = val);
                    },
                  )
                : Text(
                    'History',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
          if (_selectionMode && _selectedUrls.isNotEmpty) ...[
            Text(
              '${_selectedUrls.length} selected',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.grey,
              ),
            ),
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
    );
  }

  Widget _buildSelectionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
        border: const Border(
          bottom: BorderSide(color: Colors.black12),
        ),
      ),
      child: Row(
        children: [
          // Select all
          TextButton.icon(
            icon: const Icon(Icons.select_all, size: 18),
            label: const Text('Select all'),
            onPressed: () {
              setState(() {
                _selectedUrls
                    .addAll(_filteredItems.map((e) => e.url));
              });
            },
          ),
          const Spacer(),
          // Open all selected
          TextButton.icon(
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text('Open all (${_selectedUrls.length})'),
            onPressed: _openAllSelected,
          ),
          const SizedBox(width: 4),
          // Delete selected
          if (_selectedUrls.isNotEmpty)
            IconButton(
              tooltip: 'Delete selected',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: _deleteAllSelected,
            ),
          // Exit selection mode
          IconButton(
            tooltip: 'Cancel selection',
            icon: const Icon(Icons.close, size: 20),
            onPressed: _exitSelectionMode,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _HistoryRow — a single history entry with swipe-down detection
// =============================================================================

class _HistoryRow extends StatefulWidget {
  final BrowserHistoryEntry item;
  final int index;
  final bool isSelected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onSwipeSelect;
  final VoidCallback onDelete;

  const _HistoryRow({
    required this.item,
    required this.index,
    required this.isSelected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onSwipeSelect,
    required this.onDelete,
  });

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  // For swipe-down detection via raw pointer events
  double? _swipeStartY;
  int? _swipeStartMs;
  bool _absorbTap = false;

  void _onPointerDown(PointerDownEvent event) {
    _swipeStartY = event.position.dy;
    _swipeStartMs = DateTime.now().millisecondsSinceEpoch;
    _absorbTap = false;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_swipeStartY != null && _swipeStartMs != null) {
      final dy = event.position.dy - _swipeStartY!;
      final dt = DateTime.now().millisecondsSinceEpoch - _swipeStartMs!;
      // Quick downward flick (> 30 px, < 400 ms)
      if (dy > 30 && dt < 400) {
        _absorbTap = true;
        widget.onSwipeSelect();
        // Reset after a frame so the next tap event can check the flag
        Future.microtask(() {
          if (mounted) setState(() => _absorbTap = false);
        });
      }
    }
    _swipeStartY = null;
    _swipeStartMs = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      child: GestureDetector(
        onTap: () {
          if (_absorbTap) return;
          widget.onTap();
        },
        onLongPress: widget.onLongPress,
        child: ListTile(
          leading: Icon(
            widget.isSelected ? Icons.check_circle : Icons.history,
            color: widget.isSelected ? theme.colorScheme.primary : null,
          ),
          title: Text(
            widget.item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                _formatDate(widget.item.visitedAt),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
          // Highlight selected rows
          selected: widget.isSelected,
          selectedTileColor:
              theme.colorScheme.primaryContainer.withOpacity(0.15),
          onTap: () {
            if (_absorbTap) return;
            widget.onTap();
          },
          // Trailing: only show delete in non-selection mode
          trailing: widget.selectionMode
              ? null
              : IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: widget.onDelete,
                ),
        ),
      ),
    );
  }
}

String _formatDate(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  if (dt.year == now.year) {
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}';
  }
  return '${dt.month}/${dt.day}/${dt.year}';
}
