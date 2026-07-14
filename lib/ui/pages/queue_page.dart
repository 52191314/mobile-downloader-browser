import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../downloader/downloader.dart';
import '../../platform/public_downloads_service.dart';
import '../../theme/aurora_colors.dart';
import '../notifications/aurora_snackbar.dart';
import '../widgets/edge_swipe_card.dart';
import '../widgets/empty_queue.dart';
import '../widgets/download_task_row.dart';
import '../widgets/settings_formatters.dart';

/// Describes a state-filter chip option in the queue page.
/// [states] is `null` to show all tasks; otherwise only tasks whose
/// [DownloadState] is in the set are shown.
final class _StateFilterOption {
  final Set<DownloadState>? states;
  final String label;
  final IconData icon;
  const _StateFilterOption(this.states, this.label, this.icon);
}

/// Holds closure-typed callbacks from a [DownloadTask] that are lost during
/// JSON serialization/deserialization.  Used by the undo-delete flow to
/// faithfully restore a cancelled task.
final class _TaskCallbacks {
  final Future<String?> Function(String url, {Map<String, String>? headers})?
      fetchViaWebView;
  final Future<List<int>?> Function(String url)? fetchBinaryViaWebView;
  final String? Function(String url)? hlsPlaylistCache;
  final Future<Map<String, String>> Function(String url)? cookieProvider;
  final Future<String?> Function({bool forceReload})? onTokenExpired;

  _TaskCallbacks._(DownloadTask task)
      : fetchViaWebView = task.fetchViaWebView,
        fetchBinaryViaWebView = task.fetchBinaryViaWebView,
        hlsPlaylistCache = task.hlsPlaylistCache,
        cookieProvider = task.cookieProvider,
        onTokenExpired = task.onTokenExpired;
}

class QueuePage extends StatefulWidget {
  final DownloadQueue queue;
  final TextEditingController urlController;
  final Future<void> Function() onAddDownload;
  final Future<void> Function(DownloadTask task) onOpenDownload;
  final Future<void> Function(DownloadTask task)? onRetryTask;
  final VoidCallback? Function(DownloadTask task)? onPauseTask;
  final VoidCallback? Function(DownloadTask task)? onResumeTask;
  final VoidCallback? Function(DownloadTask task)? onCancelTask;
  final Future<bool> Function(DownloadTask task)? onForceMergeTask;
  final double speedLimitKbps;
  final void Function(String url)? onOpenUrlInBrowser;
  final Future<void> Function(DownloadTask task)? onResniffAuto;
  final Future<void> Function(DownloadTask task)? onResniffManual;

  const QueuePage({
    super.key,
    required this.queue,
    required this.urlController,
    required this.onAddDownload,
    required this.onOpenDownload,
    this.onRetryTask,
    this.onPauseTask,
    this.onResumeTask,
    this.onCancelTask,
    this.onForceMergeTask,
    required this.speedLimitKbps,
    this.onOpenUrlInBrowser,
    this.onResniffAuto,
    this.onResniffManual,
  });

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  StreamSubscription<DownloadTask>? _sub;
  StreamSubscription<String>? _removedSub;
  Timer? _rebuildTimer;
  String _selectedFolderFilter = 'All';
  bool _viewMode = false; // false = list, true = grid
  final FocusNode _urlFocusNode = FocusNode();
  bool _hasUrlText = false;

  // -- Search/sort/filter state --
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounceTimer;
  TaskSortField _sortBy = TaskSortField.date;
  bool _sortDescending = true;
  Set<DownloadState>? _stateFilter; // null = all states

  @override
  void initState() {
    super.initState();
    _hasUrlText = widget.urlController.text.isNotEmpty;
    widget.urlController.addListener(_onUrlTextChanged);
    _searchController.addListener(_onSearchChanged);
    // Wire the resniff duplicate callback so the queue can ask the user
    // when a duplicate URL is detected during manual resniff.
    widget.queue.onResniffDuplicate = _handleResniffDuplicate;
    _sub = widget.queue.onTaskUpdated.listen((task) {
      if (_rebuildTimer == null || !_rebuildTimer!.isActive) {
        _rebuildTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) setState(() {});
        });
      }
      // Check for partial download (server closed connection near completion)
      if (task.state == DownloadState.failed &&
          task.errorMessage != null &&
          task.errorMessage!.startsWith('[PARTIAL:')) {
        _showPartialMergeDialog(task);
      }
    });
    _removedSub = widget.queue.onTaskRemoved.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _onUrlTextChanged() {
    final hasText = widget.urlController.text.isNotEmpty;
    if (hasText != _hasUrlText) {
      if (mounted) setState(() => _hasUrlText = hasText);
    }
  }

  void _onSearchChanged() {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final text = _searchController.text;
      if (text != _searchQuery) {
        setState(() => _searchQuery = text);
      }
    });
  }

  @override
  void dispose() {
    widget.urlController.removeListener(_onUrlTextChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchDebounceTimer?.cancel();
    widget.queue.onResniffDuplicate = null;
    _urlFocusNode.dispose();
    _rebuildTimer?.cancel();
    _sub?.cancel();
    _removedSub?.cancel();
    super.dispose();
  }

  String? _getTaskFolder(DownloadTask task) {
    try {
      final normalized = task.savePath.replaceAll('\\', '/');
      final pathParts = normalized.split('/');
      final completedIndex = pathParts.lastIndexOf('completed');
      if (completedIndex != -1 && completedIndex < pathParts.length - 2) {
        return pathParts[completedIndex + 1];
      }
      final filesIndex = pathParts.lastIndexOf('files');
      if (filesIndex != -1 && filesIndex < pathParts.length - 2) {
        final nextSegment = pathParts[filesIndex + 1];
        if (nextSegment != 'completed') return nextSegment;
      }
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tasks = widget.queue.allTasks;
    final completed = widget.queue.completedTasks;
    final failed = widget.queue.failedTasks;

    return Scaffold(
        appBar: AppBar(
          title: const Text('Downloads'),
          actions: [
            Icon(Icons.cloud_done,
                color: Theme.of(context).colorScheme.primary),
            if (tasks.isNotEmpty)
              IconButton(
                icon: Icon(
                    _viewMode ? Icons.list_rounded : Icons.grid_view_rounded),
                tooltip: _viewMode ? 'List view' : 'Grid view',
                onPressed: () => setState(() => _viewMode = !_viewMode),
              ),
          ],
        ),
        body: SafeArea(
          child: _buildQueueTab(context, tasks, completed, failed),
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // Queue tab
  // ---------------------------------------------------------------------------

  Widget _buildQueueTab(
    BuildContext context,
    List<DownloadTask> tasks,
    List<DownloadTask> completed,
    List<DownloadTask> failed,
  ) {
    final folders = <String>{};
    for (final task in tasks) {
      final f = _getTaskFolder(task);
      if (f != null) folders.add(f);
    }

    if (_selectedFolderFilter != 'All' &&
        _selectedFolderFilter != 'Default' &&
        !folders.contains(_selectedFolderFilter)) {
      _selectedFolderFilter = 'All';
    }

    // Use the new queryTasks API with all search/sort/filter params.
    final queriedTasks = widget.queue.queryTasks(
      states: _stateFilter,
      query: _searchQuery.isNotEmpty ? _searchQuery : null,
      sortBy: _sortBy,
      sortDescending: _sortDescending,
    );

    // Apply folder filter as a post-step (not part of the core API).
    final filteredTasks = queriedTasks.where((task) {
      if (_selectedFolderFilter == 'All') return true;
      final folder = _getTaskFolder(task);
      if (_selectedFolderFilter == 'Default') return folder == null;
      return folder == _selectedFolderFilter;
    }).toList();

    final filteredCompleted =
        filteredTasks.where((t) => t.state == DownloadState.completed).length;
    final filteredFailed =
        filteredTasks.where((t) => t.state == DownloadState.failed).length;
    final activeCount = filteredTasks
        .where((t) => widget.queue.activeTasks.any((a) => a.id == t.id))
        .length;
    final queuedCount = filteredTasks
        .where((t) => widget.queue.queuedTasks.any((q) => q.id == t.id))
        .length;

    final totalSpeed = filteredTasks
        .where((t) => t.state == DownloadState.downloading)
        .fold<double>(0.0, (sum, t) => sum + t.speed);

    final folderTabs = ['All'];
    if (folders.isNotEmpty) {
      if (tasks.any((t) => _getTaskFolder(t) == null)) folderTabs.add('Default');
      folderTabs.addAll(folders.toList()..sort());
    }

    final headerSlivers = <Widget>[
      _buildAggregateHeader(
        context,
        activeCount: activeCount,
        queuedCount: queuedCount,
        completedCount: filteredCompleted,
        failedCount: filteredFailed,
        totalSpeed: totalSpeed,
      ),
      const SizedBox(height: 16),
      _buildUrlInputBar(context),
      const SizedBox(height: 10),
      _buildSearchBar(context),
      const SizedBox(height: 10),
      _buildSortAndFilterRow(context),
      const SizedBox(height: 8),
      if (folders.isNotEmpty) ...[
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: folderTabs.map((folder) {
              final isSelected = _selectedFolderFilter == folder;
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: ChoiceChip(
                  key: Key('folder_tab_$folder'),
                  label: Text(folder),
                  selected: isSelected,
                  selectedColor: AuroraColors.accent.withValues(alpha: 0.2),
                  labelStyle: TextStyle(
                    color: isSelected
                        ? AuroraColors.accent
                        : AuroraColors.mutedText,
                    fontWeight:
                        isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                  onSelected: (selected) {
                    if (selected) {
                      setState(() => _selectedFolderFilter = folder);
                    }
                  },
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
      ],
      if (filteredTasks.isNotEmpty && !_viewMode) ...[
        _buildBulkActions(filteredTasks, filteredFailed),
        const SizedBox(height: 8),
      ],
    ];

    return RefreshIndicator(
      onRefresh: () async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      },
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverList(
              delegate: SliverChildListDelegate(headerSlivers),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: _buildTaskSliver(filteredTasks),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskSliver(List<DownloadTask> filteredTasks) {
    if (filteredTasks.isEmpty) {
      return SliverToBoxAdapter(child: _buildEmptyHint(context));
    }

    if (_viewMode) {
      final completed = filteredTasks
          .where((t) => t.state == DownloadState.completed)
          .toList(growable: false);

      if (completed.isEmpty) {
        return const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text(
                'No completed downloads yet',
                style: TextStyle(color: AuroraColors.mutedText),
              ),
            ),
          ),
        );
      }

      return SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.2,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildGridTile(completed[index]),
          childCount: completed.length,
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => _buildTaskRow(context, filteredTasks[index]),
        childCount: filteredTasks.length,
      ),
    );
  }

  Widget _buildEmptyHint(BuildContext context) {
    if (_searchQuery.isNotEmpty || _stateFilter != null) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              EmptyQueue(
                icon: Icons.search_off,
                message: _searchQuery.isNotEmpty
                    ? 'No results for "$_searchQuery"'
                    : 'No tasks match the current filter',
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                icon: const Icon(Icons.clear_all, size: 16),
                label: const Text('Clear filters'),
                onPressed: () {
                  setState(() {
                    _searchQuery = '';
                    _searchController.clear();
                    _stateFilter = null;
                    _sortBy = TaskSortField.date;
                    _sortDescending = true;
                  });
                },
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(height: 280, child: const EmptyQueue());
  }

  // ---------------------------------------------------------------------------
  // URL input bar (extracted from inline build)
  // ---------------------------------------------------------------------------

  Widget _buildUrlInputBar(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _urlFocusNode.requestFocus(),
      child: Card(
        color: AuroraColors.glassSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: AuroraColors.glassBorder),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, top: 4, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.urlController,
                  focusNode: _urlFocusNode,
                  decoration: InputDecoration(
                    hintText: 'Paste a URL to download…',
                    hintStyle: TextStyle(
                      color: AuroraColors.mutedDeep,
                      fontSize: 13,
                    ),
                    prefixIcon: Icon(Icons.link,
                        color: AuroraColors.accent, size: 18),
                    suffixIcon: _hasUrlText
                        ? IconButton(
                            icon: Icon(Icons.clear,
                                size: 18,
                                color: AuroraColors.mutedText),
                            onPressed: () {
                              widget.urlController.clear();
                              _urlFocusNode.requestFocus();
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                            splashRadius: 14,
                          )
                        : null,
                    filled: true,
                    fillColor: AuroraColors.surface,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(
                        color: AuroraColors.accent.withValues(alpha: 0.5),
                        width: 1,
                      ),
                    ),
                  ),
                  style: const TextStyle(
                      fontSize: 13, color: AuroraColors.text),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => widget.onAddDownload(),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                height: 40,
                child: IconButton.filled(
                  tooltip: 'Add download',
                  onPressed: widget.onAddDownload,
                  icon: const Icon(Icons.add, size: 20),
                  style: IconButton.styleFrom(
                    backgroundColor: AuroraColors.accent,
                    foregroundColor: AuroraColors.background,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    minimumSize: const Size(40, 40),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Search bar
  // ---------------------------------------------------------------------------

  Widget _buildSearchBar(BuildContext context) {
    return Card(
      color: AuroraColors.glassSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: AuroraColors.glassBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 4, top: 2, bottom: 2),
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search URL or filename…',
            hintStyle: TextStyle(
              color: AuroraColors.mutedDeep,
              fontSize: 13,
            ),
            prefixIcon: Icon(Icons.search,
                color: AuroraColors.accent, size: 18),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear,
                        size: 18,
                        color: AuroraColors.mutedText),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                    splashRadius: 14,
                  )
                : null,
            filled: true,
            fillColor: AuroraColors.surface,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(
                color: AuroraColors.accent.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
          ),
          style: const TextStyle(
              fontSize: 13, color: AuroraColors.text),
          textInputAction: TextInputAction.search,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sort & state filter row
  // ---------------------------------------------------------------------------

  static const _stateFilterOptions = <_StateFilterOption>{
    _StateFilterOption(null, 'All', Icons.all_inclusive),
    _StateFilterOption({DownloadState.downloading, DownloadState.idle, DownloadState.merging}, 'Active', Icons.bolt),
    _StateFilterOption({DownloadState.paused}, 'Paused', Icons.pause_circle_outline),
    _StateFilterOption({DownloadState.completed}, 'Done', Icons.done_all),
    _StateFilterOption({DownloadState.failed}, 'Failed', Icons.error_outline),
  };

  Widget _buildSortAndFilterRow(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          // Sort chip
          _buildSortChip(context),
          const SizedBox(width: 8),

          // State filter chips
          for (final option in _stateFilterOptions)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _buildStateChip(option),
            ),
        ],
      ),
    );
  }

  Widget _buildSortChip(BuildContext context) {
    final sortLabel = _sortLabel(_sortBy);
    final arrowIcon = _sortDescending
        ? Icons.arrow_downward_rounded
        : Icons.arrow_upward_rounded;
    return ActionChip(
      avatar: Icon(arrowIcon, size: 14, color: AuroraColors.accent),
      label: Text(sortLabel, style: const TextStyle(fontSize: 11)),
      backgroundColor: AuroraColors.glassSurface,
      side: BorderSide(color: AuroraColors.glassBorder),
      onPressed: () => _showSortPicker(context),
    );
  }

  Widget _buildStateChip(_StateFilterOption option) {
    final isSelected = _stateFilter == option.states;
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(option.icon, size: 13,
              color: isSelected ? AuroraColors.accent : AuroraColors.mutedText),
          const SizedBox(width: 4),
          Text(option.label, style: const TextStyle(fontSize: 11)),
        ],
      ),
      selected: isSelected,
      selectedColor: AuroraColors.accent.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        color: isSelected ? AuroraColors.accent : AuroraColors.mutedText,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
      onSelected: (_) {
        setState(() {
          _stateFilter = isSelected ? null : option.states;
        });
      },
    );
  }

  void _showSortPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: AuroraColors.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Sort by',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AuroraColors.text,
                    )),
                const SizedBox(height: 12),
                const Divider(height: 1),
                for (final field in TaskSortField.values)
                  InkWell(
                    onTap: () {
                      final sameField = _sortBy == field;
                      setState(() {
                        if (sameField) {
                          _sortDescending = !_sortDescending;
                        } else {
                          _sortBy = field;
                          _sortDescending = true;
                        }
                      });
                      Navigator.pop(ctx);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _sortLabel(field),
                              style: TextStyle(
                                fontSize: 13,
                                color: _sortBy == field
                                    ? AuroraColors.accent
                                    : AuroraColors.text,
                                fontWeight: _sortBy == field
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (_sortBy == field)
                            Icon(
                              _sortDescending
                                  ? Icons.arrow_downward_rounded
                                  : Icons.arrow_upward_rounded,
                              size: 16,
                              color: AuroraColors.accent,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _sortLabel(TaskSortField field) {
    switch (field) {
      case TaskSortField.date:
        return 'Date';
      case TaskSortField.name:
        return 'Name';
      case TaskSortField.size:
        return 'Size';
      case TaskSortField.priority:
        return 'Priority';
      case TaskSortField.state:
        return 'State';
      case TaskSortField.speed:
        return 'Speed';
    }
  }

  // ---------------------------------------------------------------------------
  // Bulk action buttons
  // ---------------------------------------------------------------------------

  Widget _buildBulkActions(List<DownloadTask> filteredTasks, int filteredFailed) {
    final hasActive = filteredTasks
        .any((t) => t.state == DownloadState.downloading || t.state == DownloadState.idle);
    final hasPaused = filteredTasks.any((t) => t.state == DownloadState.paused);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (hasActive && widget.onPauseTask != null)
            _actionChip(Icons.pause_rounded, 'Pause All', () {
              for (final task in filteredTasks) {
                if (task.state == DownloadState.downloading || task.state == DownloadState.idle) {
                  widget.onPauseTask!(task)?.call();
                }
              }
            }),
          if (hasPaused && widget.onResumeTask != null)
            _actionChip(Icons.play_arrow_rounded, 'Resume All', () {
              for (final task in filteredTasks) {
                if (task.state == DownloadState.paused) {
                  widget.onResumeTask!(task)?.call();
                }
              }
            }),
          if (filteredFailed > 0 && widget.onRetryTask != null)
            _actionChip(Icons.refresh_rounded, 'Retry All', () {
              for (final task in filteredTasks) {
                if (task.state == DownloadState.failed) {
                  widget.onRetryTask!(task);
                }
              }
            }),
          if (widget.onCancelTask != null)
            _actionChip(Icons.cancel_outlined, 'Cancel Active', () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Cancel active downloads?'),
                  content: const Text(
                    'Remove all active and queued downloads?\nTemporary files will be deleted.',
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove All')),
                  ],
                ),
              );
              if (confirm == true) {
                for (final task in filteredTasks) {
                  if (task.state != DownloadState.completed) {
                    widget.onCancelTask!(task)?.call();
                  }
                }
              }
            }),
        ],
      ),
    );
  }

  Widget _actionChip(IconData icon, String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(icon, size: 16, color: AuroraColors.accent),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        backgroundColor: AuroraColors.glassSurface,
        side: BorderSide(color: AuroraColors.glassBorder),
        onPressed: onPressed,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Aggregate header
  // ---------------------------------------------------------------------------

  Widget _buildAggregateHeader(
    BuildContext context, {
    required int activeCount,
    required int queuedCount,
    required int completedCount,
    required int failedCount,
    required double totalSpeed,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AuroraColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AuroraColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Count badges
          Row(
            children: [
              _statBadge(Icons.bolt, '$activeCount', 'Active',
                  AuroraColors.accent),
              const SizedBox(width: 8),
              _statBadge(Icons.pending_actions, '$queuedCount', 'Queued',
                  AuroraColors.accentPurple),
              const SizedBox(width: 8),
              _statBadge(Icons.done_all, '$completedCount', 'Done',
                  AuroraColors.nordGreen),
              const SizedBox(width: 8),
              _statBadge(Icons.error_outline, '$failedCount', 'Failed',
                  AuroraColors.nordRed),
            ],
          ),
          if (activeCount > 0 || queuedCount > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.speed, size: 14, color: AuroraColors.mutedText),
                const SizedBox(width: 4),
                Text(
                  formatSpeed(totalSpeed),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AuroraColors.accent,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                if (widget.speedLimitKbps > 0)
                  Text(
                    'limit ${widget.speedLimitKbps.round()} KB/s',
                    style: TextStyle(
                      fontSize: 11,
                      color: AuroraColors.mutedDeep,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _statBadge(IconData icon, String count, String label, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(height: 2),
            Text(
              count,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: AuroraColors.text,
              ),
            ),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: AuroraColors.mutedText),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Task row (list view)
  // ---------------------------------------------------------------------------

  Color _statusColor(DownloadState state) {
    switch (state) {
      case DownloadState.downloading:
      case DownloadState.idle:
        return AuroraColors.accent; // Teal, pulsing
      case DownloadState.paused:
        return AuroraColors.accentAmber; // Amber
      case DownloadState.completed:
        return AuroraColors.nordGreen; // Green (Nord)
      case DownloadState.failed:
        return AuroraColors.nordRed; // Red (Nord)
      case DownloadState.merging:
        return Colors.orange;
    }
  }

  /// Called when the user left-swipes a task — immediately removes the task
  /// from the queue and shows an Undo snackbar.  If the user taps Undo
  /// within 5 seconds the task is restored (with callbacks reattached).
  Future<void> _deleteTaskWithUndo(DownloadTask task) async {
    // Snapshot the task data (toJson loses closure-typed fields).
    final taskJson = task.toJson();
    final callbacks = _TaskCallbacks._(task);

    // Await the actual cancellation (file cleanup, removal from queue).
    await widget.queue.cancelTaskAsync(task.id);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed "${_taskDisplayName(task)}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            final restored = DownloadTask.fromJson(taskJson);
            // Reattach closure-typed callbacks that toJson/fromJson loses.
            restored.fetchViaWebView = callbacks.fetchViaWebView;
            restored.fetchBinaryViaWebView = callbacks.fetchBinaryViaWebView;
            restored.hlsPlaylistCache = callbacks.hlsPlaylistCache;
            restored.cookieProvider = callbacks.cookieProvider;
            restored.onTokenExpired = callbacks.onTokenExpired;
            // Non-completed tasks are set to paused so they don't auto-start.
            if (restored.state != DownloadState.completed) {
              restored.state = DownloadState.paused;
              restored.downloadedBytes = 0;
            }
            widget.queue.addTask(restored, force: true);
          },
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Widget _buildTaskRow(BuildContext context, DownloadTask task) {
    final color = _statusColor(task.state);
    // null = unknown total → indeterminate bar animates instead of showing 0%
    final progress = task.totalBytes > 0
        ? (task.downloadedBytes / task.totalBytes).clamp(0.0, 1.0)
        : null;

    // ── Swipe backgrounds ──────────────────────────────────────────────
    //
    // HoldSwipeCard conventions:
    //   * leftBackground  — revealed when swiping RIGHT (offset > 0)
    //   * rightBackground — revealed when swiping LEFT  (offset < 0)
    //   * onRightSwipe    — fired after a RIGHT swipe completes
    //   * onLeftSwipe     — fired after a LEFT  swipe completes
    //
    // User decision:  Right = pause/resume/retry/open  ·  Left = delete

    final isMerging = task.state == DownloadState.merging;

    // Right-swipe background  (teal, adaptive icon)
    Widget? _rightSwipeBackground() {
      Widget icon;
      switch (task.state) {
        case DownloadState.idle:
        case DownloadState.downloading:
          icon = const Icon(Icons.pause, color: AuroraColors.accent);
        case DownloadState.paused:
          icon = const Icon(Icons.play_arrow, color: AuroraColors.accent);
        case DownloadState.failed:
          icon = const Icon(Icons.refresh, color: AuroraColors.accent);
        case DownloadState.completed:
          icon = const Icon(Icons.open_in_new, color: AuroraColors.accent);
        case DownloadState.merging:
          return null; // not swipeable
      }
      return Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AuroraColors.accent.withValues(alpha: 0.2),
        child: icon,
      );
    }

    // Left-swipe background  (red, delete icon)
    Widget? _leftSwipeBackground() {
      if (isMerging) return null;
      return Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        color: AuroraColors.nordRed.withValues(alpha: 0.2),
        child: const Icon(Icons.delete_outline, color: AuroraColors.nordRed),
      );
    }

    // Right-swipe action  (state-aware)
    VoidCallback? _onRightSwipe() {
      if (isMerging) return null;
      switch (task.state) {
        case DownloadState.idle:
        case DownloadState.downloading:
          return () => widget.onPauseTask?.call(task)?.call();
        case DownloadState.paused:
          return () => widget.onResumeTask?.call(task)?.call();
        case DownloadState.failed:
          return () => widget.onRetryTask?.call(task);
        case DownloadState.completed:
          return () => widget.onOpenDownload?.call(task);
        case DownloadState.merging:
          return null;
      }
    }

    // Left-swipe action  (delete with undo)
    VoidCallback? _onLeftSwipe() {
      if (isMerging) return null;
      return () => unawaited(_deleteTaskWithUndo(task));
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: HoldSwipeCard(
        leftBackground: _rightSwipeBackground(),   // revealed on RIGHT swipe
        rightBackground: _leftSwipeBackground(),    // revealed on LEFT  swipe
        onLeftSwipe: _onLeftSwipe(),                // LEFT  swipe → delete
        onRightSwipe: _onRightSwipe(),              // RIGHT swipe → adaptive
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          decoration: BoxDecoration(
            color: AuroraColors.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AuroraColors.glassBorder),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                // Left edge status indicator
                Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(12)),
                  ),
                ),
                const SizedBox(width: 12),
                // Text block
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildNameWidget(
                        task,
                        const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AuroraColors.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // Micro progress bar
                      // When totalBytes is unknown (null progress), shows an
                      // indeterminate animated bar so the user can see the
                      // download is actively receiving data.
                      if (task.state == DownloadState.downloading ||
                          task.state == DownloadState.idle)
                        RepaintBoundary(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(1),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 2,
                              backgroundColor:
                                  AuroraColors.surfaceVariant,
                              valueColor: AlwaysStoppedAnimation<Color>(color),
                            ),
                          ),
                        ),
                      if (task.state == DownloadState.completed ||
                          task.state == DownloadState.failed ||
                          task.state == DownloadState.paused)
                        const SizedBox(height: 2),
                      // Metadata line
                      Text(
                        _metadataLabel(task),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 8.5,
                          fontFamily: 'monospace',
                          color: AuroraColors.mutedDeep,
                        ),
                      ),
                    ],
                  ),
                ),
                // Action buttons
                _buildTaskActions(task, color),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _compactButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 26,
      height: 26,
      child: IconButton(
        icon: Icon(icon, size: 14),
        color: color,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        splashRadius: 14,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildTaskActions(DownloadTask task, Color color) {
    // ── Primary action icon (visible outside popup) ──────────────
    Widget? primaryAction;

    if (task.state == DownloadState.downloading ||
        task.state == DownloadState.idle) {
      primaryAction = _compactButton(
        icon: Icons.pause_rounded,
        color: AuroraColors.accent,
        tooltip: 'Pause',
        onPressed: () => widget.onPauseTask?.call(task)?.call(),
      );
    } else if (task.state == DownloadState.paused) {
      primaryAction = _compactButton(
        icon: Icons.play_arrow_rounded,
        color: AuroraColors.accent,
        tooltip: 'Resume',
        onPressed: () => widget.onResumeTask?.call(task)?.call(),
      );
    } else if (task.state == DownloadState.merging) {
      primaryAction = const SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: EdgeInsets.all(6),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AuroraColors.accent),
          ),
        ),
      );
    } else if (task.state == DownloadState.failed) {
      primaryAction = _compactButton(
        icon: Icons.refresh_rounded,
        color: AuroraColors.nordRed,
        tooltip: 'Retry',
        onPressed: () => widget.onRetryTask?.call(task),
      );
    } else if (task.state == DownloadState.completed) {
      // No primary action needed — file is already in public Downloads.
    }

    // ── Overflow popup menu with all secondary actions ──────────
    final popupItems = <PopupMenuEntry<String>>[];

    // Force merge (non-completed, non-active/downloading, non-merging tasks)
    if (task.state != DownloadState.completed &&
        task.state != DownloadState.downloading &&
        task.state != DownloadState.merging &&
        widget.onForceMergeTask != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'force_merge',
          child: _popupRow(Icons.merge_type, Colors.orange, 'Force Merge'),
        ),
      );
    }

    // Resniff (Auto) — probe the URL for a fresher variant
    if (widget.onResniffAuto != null &&
        !task.url.startsWith('magnet:') &&
        !task.url.startsWith('blob:')) {
      popupItems.add(
        PopupMenuItem(
          value: 'resniff_auto',
          child: _popupRow(
              Icons.find_replace_rounded, AuroraColors.accent, 'Resniff (Auto)'),
        ),
      );
    }

    // Resniff (Manual) — open source page so user can re-sniff
    if (widget.onResniffManual != null &&
        (task.sourcePageUrl != null || !task.url.startsWith('magnet:'))) {
      popupItems.add(
        PopupMenuItem(
          value: 'resniff_manual',
          child: _popupRow(Icons.open_in_browser_rounded,
              AuroraColors.accentPurple, 'Resniff (Manual)'),
        ),
      );
    }

    // Open source page
    if (task.sourcePageUrl != null && widget.onOpenUrlInBrowser != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'open_source',
          child:
              _popupRow(Icons.open_in_new, AuroraColors.accentPurple, 'Open Source Page'),
        ),
      );
    }

    // Delete / Cancel
    final isCompleted = task.state == DownloadState.completed;
    popupItems.add(
      PopupMenuItem(
        value: 'delete',
        child: _popupRow(Icons.delete_outline, AuroraColors.nordRed,
            isCompleted ? 'Remove' : 'Cancel'),
      ),
    );

    // Properties
    popupItems.add(
      PopupMenuItem(
        value: 'properties',
        child: _popupRow(Icons.info_outline, AuroraColors.mutedText, 'Properties'),
      ),
    );

    final hasPrimary = primaryAction != null;
    final hasOverflow = popupItems.isNotEmpty;

    if (!hasPrimary && !hasOverflow) return const SizedBox.shrink();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) {},
      onLongPressMoveUpdate: (_) {},
      onLongPressEnd: (_) {},
      onLongPressCancel: () {},
      child: Padding(
        padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (primaryAction != null) ...[
              primaryAction,
              const SizedBox(width: 4),
            ],
            if (hasOverflow)
              SizedBox(
                width: 26,
                height: 26,
                child: PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, size: 14,
                      color: AuroraColors.mutedText),
                  padding: EdgeInsets.zero,
                  splashRadius: 14,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  color: AuroraColors.surfaceCard,
                  elevation: 4,
                  onSelected: (value) async {
                    switch (value) {
                      case 'force_merge':
                        unawaited(widget.onForceMergeTask!(task));
                      case 'open_source':
                        widget.onOpenUrlInBrowser!(task.sourcePageUrl!);
                      case 'resniff_auto':
                        unawaited(widget.onResniffAuto?.call(task));
                      case 'resniff_manual':
                        unawaited(widget.onResniffManual?.call(task));
                      case 'delete':
                        unawaited(_deleteTaskWithUndo(task));
                      case 'properties':
                        showDialog(
                          context: context,
                          builder: (context) => DownloadPropertiesDialog(
                            task: task,
                            onOpenDownload: widget.onOpenDownload,
                            onOpenUrlInBrowser: widget.onOpenUrlInBrowser,
                            onTaskUpdated: (t) => widget.queue.emitTask(t),
                          ),
                        ).then((_) {
                          if (mounted) setState(() {});
                        });
                    }
                  },
                  itemBuilder: (_) => popupItems,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _popupRow(IconData icon, Color color, String label) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }

  String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  String _taskDisplayName(DownloadTask task) {
    final filename = _fileName(task.savePath);
    final dotIdx = filename.lastIndexOf('.');
    if (dotIdx != -1 && dotIdx > 0 && filename.length - dotIdx <= 6) {
      return filename;
    }

    String? ext;
    if (task.contentType != null && task.contentType!.isNotEmpty) {
      final cleanMime = task.contentType!.split(';').first.trim().toLowerCase();
      if (cleanMime == 'application/vnd.apple.mpegurl' || cleanMime == 'application/x-mpegurl') {
        ext = '.mp4';
      } else if (cleanMime == 'application/dash+xml') {
        ext = '.mp4';
      } else {
        ext = PublicDownloadsService.extensionForMime(cleanMime);
      }
    }

    if (ext == null || ext.isEmpty) {
      final parsedUri = Uri.tryParse(task.url);
      if (parsedUri != null && parsedUri.pathSegments.isNotEmpty) {
        final lastSeg = parsedUri.pathSegments.last;
        final lastDot = lastSeg.lastIndexOf('.');
        if (lastDot != -1 && lastDot > 0 && lastSeg.length - lastDot <= 6) {
          final urlExt = lastSeg.substring(lastDot).toLowerCase();
          if (urlExt == '.m3u8' || urlExt == '.mpd') {
            ext = '.mp4';
          } else {
            ext = urlExt;
          }
        }
      }
    }

    if (ext == null || ext.isEmpty) {
      if (task.url.toLowerCase().contains('.m3u8')) {
        ext = '.mp4';
      } else if (task.url.toLowerCase().contains('.mpd')) {
        ext = '.mp4';
      } else if (task.url.startsWith('magnet:')) {
        ext = '.torrent';
      }
    }

    if (ext != null && ext.isNotEmpty) {
      return '$filename$ext';
    }
    return filename;
  }

  /// Renders the task filename with middle-ellipsis: the base name
  /// is end-ellipsized inside an Expanded (or Flexible when centered),
  /// while the file extension sits in a separate non-shrinking Text
  /// so it is always visible. For filenames without a recognizable
  /// extension, falls back to a plain Text with end-ellipsis.
  Widget _buildNameWidget(DownloadTask task, TextStyle style, {bool centered = false}) {
    final name = _taskDisplayName(task);
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx > 0 && name.length - dotIdx <= 6) {
      final base = name.substring(0, dotIdx);
      final ext = name.substring(dotIdx); // includes the dot
      if (centered) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(base, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            ),
            Text(ext, maxLines: 1, style: style),
          ],
        );
      }
      return Row(
        children: [
          Expanded(
            child: Text(base, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
          Text(ext, maxLines: 1, style: style),
        ],
      );
    }
    return Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
  }

  String _metadataLabel(DownloadTask task) {
    final parts = <String>[];
    if (task.state == DownloadState.downloading ||
        task.state == DownloadState.idle) {
      if (task.totalBytes > 0) {
        parts.add('${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}');
      } else if (task.downloadedBytes > 0) {
        parts.add('${formatBytes(task.downloadedBytes)} downloaded');
      }
      parts.add(formatSpeed(task.speed));
      final elapsed = DateTime.now().difference(task.createdAt);
      final m = elapsed.inMinutes;
      final s = elapsed.inSeconds % 60;
      parts.add('${m}m ${s}s');
    } else if (task.state == DownloadState.completed && task.totalBytes > 0) {
      parts.add(formatBytes(task.totalBytes));
    } else if (task.state == DownloadState.completed && task.downloadedBytes > 0) {
      parts.add('${formatBytes(task.downloadedBytes)} downloaded');
    } else if (task.state == DownloadState.failed && task.errorMessage != null) {
      parts.add(task.errorMessage!.length > 40
          ? '${task.errorMessage!.substring(0, 40)}…'
          : task.errorMessage!);
    } else if (task.state == DownloadState.paused) {
      if (task.totalBytes > 0) {
        parts.add('${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}');
      } else if (task.downloadedBytes > 0) {
        parts.add('${formatBytes(task.downloadedBytes)} downloaded');
      }
      parts.add('Paused');
    } else if (task.state == DownloadState.merging) {
      if (task.totalBytes > 0 && task.downloadedBytes > 0) {
        parts.add('Merging chunk ${task.downloadedBytes} of ${task.totalBytes}');
      } else {
        parts.add('Merging…');
      }
    }
    return parts.join(' · ');
  }

  // ---------------------------------------------------------------------------
  // Grid view (completed only)
  // ---------------------------------------------------------------------------



  Widget _buildGridTile(DownloadTask task) {
    return GestureDetector(
      onTap: () => widget.onOpenDownload(task),
      onLongPress: () => widget.onOpenDownload(task),
      child: Container(
        decoration: BoxDecoration(
          color: AuroraColors.surfaceCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AuroraColors.glassBorder),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 32,
              color: AuroraColors.nordGreen,
            ),
            const SizedBox(height: 8),
            _buildNameWidget(
              task,
              const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AuroraColors.text,
              ),
              centered: true,
            ),
            if (task.totalBytes > 0) ...[
              const SizedBox(height: 4),
              Text(
                formatBytes(task.totalBytes),
                style: TextStyle(
                  fontSize: 10,
                  color: AuroraColors.mutedDeep,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showPartialMergeDialog(DownloadTask task) {
    if (!mounted) return;
    final match = RegExp(r'\[PARTIAL:([\d.]+)\]').firstMatch(task.errorMessage ?? '');
    final pct = match?.group(1) ?? '?';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Partial download detected'),
        content: Text(
          'The server closed the connection at $pct% completion.\n\n'
          'You can merge the partial file to keep what was downloaded, '
          'or retry to attempt downloading the remaining data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Dismiss'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.onRetryTask?.call(task);
            },
            child: const Text('Retry'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              if (widget.onForceMergeTask != null) {
                final ok = await widget.onForceMergeTask!(task);
                if (mounted) {
                  AuroraSnackbar.show(
                    context,
                    ok
                        ? 'Partial file merged successfully.'
                        : 'Failed to merge partial file.',
                  );
                }
              }
            },
            child: const Text('Merge & Save'),
          ),
        ],
      ),
    );
  }

  /// Called by [DownloadQueue.onResniffDuplicate] when a duplicate URL is
  /// detected while the queue is in manual-resniff mode.  Shows a dialog
  /// asking whether to update the existing download or create a new one.
  void _handleResniffDuplicate(String existingTaskId, String newUrl, String? contentType) {
    if (!mounted) return;
    widget.queue.resniffPendingTaskId = null; // exit resniff mode
    _showResniffDuplicateDialog(existingTaskId, newUrl, contentType);
  }

  void _showResniffDuplicateDialog(String existingTaskId, String newUrl, String? contentType) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Duplicate Link Detected'),
        content: Text(
          'This media URL is already in your download queue.\n\n'
          'The link may have changed (e.g. token refresh). Would you '
          'like to update the existing download with the new link, '
          'or create a separate new download?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Create new download alongside existing one
              final existing = widget.queue.getTask(existingTaskId);
              if (existing != null) {
                final newTask = DownloadTask(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  url: newUrl,
                  headers: existing.headers,
                  savePath: existing.savePath.replaceAll(
                    _fileName(existing.savePath),
                    '${_fileName(existing.savePath).replaceAll(RegExp(r'\.[^.]+$'), '')}_${DateTime.now().millisecondsSinceEpoch}${RegExp(r'\.[^.]+$').firstMatch(existing.savePath)?.group(0) ?? ''}',
                  ),
                  tempDir: '${existing.tempDir}_${DateTime.now().millisecondsSinceEpoch}',
                  contentType: contentType ?? existing.contentType,
                  sourcePageUrl: existing.sourcePageUrl,
                );
                widget.queue.addTask(newTask, force: true);
                if (mounted) {
                  AuroraSnackbar.show(context, 'New download added for refreshed link.');
                }
              }
            },
            child: const Text('Create New'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              // Update existing task with the freshly sniffed URL and make it
              // retryable. A changed URL means the previously downloaded bytes
              // no longer match, so progress is reset before resuming.
              final existing = widget.queue.getTask(existingTaskId);
              if (existing != null) {
                final urlChanged = existing.url != newUrl;
                existing.url = newUrl;
                if (urlChanged) {
                  existing.downloadedBytes = 0;
                  existing.totalBytes = 0;
                }
                if (existing.state == DownloadState.failed ||
                    existing.state == DownloadState.paused) {
                  existing.state = DownloadState.idle;
                }
                existing.failureReason = null;
                existing.errorMessage = null;
                await widget.queue.resumeTaskAsync(existingTaskId);
                if (mounted) {
                  AuroraSnackbar.show(
                    context,
                    'Download link updated. The download will retry.',
                  );
                  setState(() {});
                }
              }
            },
            child: const Text('Update Existing'),
          ),
        ],
      ),
    );
  }
}
