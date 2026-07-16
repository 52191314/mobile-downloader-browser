import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../downloader/downloader.dart';
import '../../platform/public_downloads_service.dart';
import '../../theme/aurora_palette.dart';
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
  final Future<void> Function(DownloadTask task) onShareDownload;
  final Future<void> Function(DownloadTask task)? onExportDownload;

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
    required this.onShareDownload,
    this.onExportDownload,
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
          title: const Text('Queue'),
          actions: [
            Icon(Icons.cloud_done,
                color: Theme.of(context).colorScheme.primary),
            if (tasks.isNotEmpty)
              IconButton(
                icon: Icon(
                    _viewMode ? Icons.list_rounded : Icons.grid_view_rounded),
                tooltip: _viewMode ? 'Show as list' : 'Show as grid',
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
    final ac = context.ac;
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
    final scheduledCount = filteredTasks
        .where((t) => t.state == DownloadState.scheduled)
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
        scheduledCount: scheduledCount,
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
                  selectedColor: ac.accentFrost.withValues(alpha: 0.2),
                  labelStyle: TextStyle(
                    fontFamily: 'Inter',
                    color: isSelected
                        ? ac.accentFrost
                        : ac.textSecondary,
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
    final ac = context.ac;
    if (filteredTasks.isEmpty) {
      return SliverToBoxAdapter(child: _buildEmptyHint(context));
    }

    if (_viewMode) {
      final completed = filteredTasks
          .where((t) => t.state == DownloadState.completed)
          .toList(growable: false);

      if (completed.isEmpty) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(
              child: Text(
                'No completed downloads yet',
                style: TextStyle(fontFamily: 'Inter', color: ac.textSecondary),
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
                    ? 'Nothing matches "$_searchQuery"'
                    : 'No downloads match this filter',
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                icon: const Icon(Icons.clear_all, size: 16),
                label: const Text('Reset filters'),
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
    final ac = context.ac;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _urlFocusNode.requestFocus(),
      child: Card(
        color: ac.glassSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: ac.glassBorder),
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
                    hintText: 'Paste a link to download…',
                    hintStyle: TextStyle(
                      fontFamily: 'Inter',
                      color: ac.textTertiary,
                      fontSize: 13,
                    ),
                    prefixIcon: Icon(Icons.link,
                        color: ac.accentFrost, size: 18),
                    suffixIcon: _hasUrlText
                        ? IconButton(
                            icon: Icon(Icons.clear,
                                size: 18,
                                color: ac.textSecondary),
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
                    fillColor: ac.surfacePanel,
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
                        color: ac.accentFrost.withValues(alpha: 0.5),
                        width: 1,
                      ),
                    ),
                  ),
                  style: TextStyle(
                      fontSize: 13, color: ac.textPrimary),
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
                    backgroundColor: ac.accentFrost,
                    foregroundColor: ac.surfaceField,
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
    final ac = context.ac;
    return Card(
      color: ac.glassSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: ac.glassBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 4, top: 2, bottom: 2),
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search by URL or name…',
            hintStyle: TextStyle(
              fontFamily: 'Inter',
              color: ac.textTertiary,
              fontSize: 13,
            ),
            prefixIcon: Icon(Icons.search,
                color: ac.accentFrost, size: 18),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear,
                        size: 18,
                        color: ac.textSecondary),
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
            fillColor: ac.surfacePanel,
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
                color: ac.accentFrost.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
          ),
          style: TextStyle(
              fontSize: 13, color: ac.textPrimary),
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
    _StateFilterOption({DownloadState.scheduled}, 'Scheduled', Icons.schedule),
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
    final ac = context.ac;
    final sortLabel = _sortLabel(_sortBy);
    final arrowIcon = _sortDescending
        ? Icons.arrow_downward_rounded
        : Icons.arrow_upward_rounded;
    return ActionChip(
      avatar: Icon(arrowIcon, size: 14, color: ac.accentFrost),
      label: Text(sortLabel, style: TextStyle(fontFamily: 'Inter', fontSize: 11)),
      backgroundColor: ac.glassSurface,
      side: BorderSide(color: ac.glassBorder),
      onPressed: () => _showSortPicker(context),
    );
  }

  Widget _buildStateChip(_StateFilterOption option) {
    final ac = context.ac;
    final isSelected = _stateFilter == option.states;
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(option.icon, size: 13,
              color: isSelected ? ac.accentFrost : ac.textSecondary),
          const SizedBox(width: 4),
          Text(option.label, style: TextStyle(fontFamily: 'Inter', fontSize: 11)),
        ],
      ),
      selected: isSelected,
      selectedColor: ac.accentFrost.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        fontFamily: 'Inter',
        color: isSelected ? ac.accentFrost : ac.textSecondary,
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
    final ac = context.ac;
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: ac.surfaceCard,
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
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: ac.textPrimary,
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
                                fontFamily: 'Inter',
                                fontSize: 13,
                                color: _sortBy == field
                                    ? ac.accentFrost
                                    : ac.textPrimary,
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
                              color: ac.accentFrost,
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
    final hasScheduled = filteredTasks.any((t) => t.state == DownloadState.scheduled);

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
          if (hasScheduled && widget.onCancelTask != null)
            _actionChip(Icons.event_busy_rounded, 'Cancel Scheduled', () {
              for (final task in filteredTasks) {
                if (task.state == DownloadState.scheduled) {
                  widget.onCancelTask!(task)?.call();
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
                    'This removes all active and queued downloads.\nTemporary files will be deleted.',
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove all')),
                  ],
                ),
              );
              if (confirm == true) {
                for (final task in filteredTasks) {
                  if (task.state != DownloadState.completed &&
                      task.state != DownloadState.scheduled) {
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
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(icon, size: 16, color: ac.accentFrost),
        label: Text(label, style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
        backgroundColor: ac.glassSurface,
        side: BorderSide(color: ac.glassBorder),
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
    required int scheduledCount,
    required int completedCount,
    required int failedCount,
    required double totalSpeed,
  }) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ac.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ac.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Count badges
          Row(
            children: [
              _statBadge(Icons.bolt, '$activeCount', 'Active',
                  ac.accentFrost),
              const SizedBox(width: 8),
              _statBadge(Icons.pending_actions, '$queuedCount', 'Queued',
                  ac.accentPurple),
              const SizedBox(width: 8),
              if (scheduledCount > 0) ...[
                _statBadge(Icons.schedule, '$scheduledCount', 'Scheduled',
                    ac.accentPurple),
                const SizedBox(width: 8),
              ],
              _statBadge(Icons.done_all, '$completedCount', 'Done',
                  ac.statusSuccess),
              const SizedBox(width: 8),
              _statBadge(Icons.error_outline, '$failedCount', 'Failed',
                  ac.statusError),
            ],
          ),
          if (activeCount > 0 || queuedCount > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.speed, size: 14, color: ac.textSecondary),
                const SizedBox(width: 4),
                Text(
                  formatSpeed(totalSpeed),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ac.accentFrost,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
                const Spacer(),
                if (widget.speedLimitKbps > 0)
                  Text(
                    'limit ${widget.speedLimitKbps.round()} KB/s',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      color: ac.textTertiary,
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
    final ac = context.ac;
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
                fontFamily: 'Inter',
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: ac.textPrimary,
              ),
            ),
            Text(
              label,
              style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: ac.textSecondary),
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
    final ac = context.ac;
    switch (state) {
      case DownloadState.downloading:
      case DownloadState.idle:
        return ac.accentFrost; // Teal, pulsing
      case DownloadState.scheduled:
        return ac.accentPurple; // Purple for scheduled
      case DownloadState.paused:
        return ac.accentAmber; // Amber
      case DownloadState.completed:
        return ac.statusSuccess; // Green (Nord)
      case DownloadState.failed:
        return ac.statusError; // Red (Nord)
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

    final undoAction = () {
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
    };

    AuroraSnackbar.show(
      context,
      'Done — Removed "${_taskDisplayName(task)}".',
      actionLabel: 'Undo',
      onAction: undoAction,
    );
  }

  Widget _buildTaskRow(BuildContext context, DownloadTask task) {
    final ac = context.ac;
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
        case DownloadState.scheduled:
          icon = Icon(Icons.cancel_outlined, color: ac.statusError);
        case DownloadState.idle:
        case DownloadState.downloading:
          icon = Icon(Icons.pause, color: ac.accentFrost);
        case DownloadState.paused:
          icon = Icon(Icons.play_arrow, color: ac.accentFrost);
        case DownloadState.failed:
          icon = Icon(Icons.refresh, color: ac.accentFrost);
        case DownloadState.completed:
          icon = Icon(Icons.open_in_new, color: ac.accentFrost);
        case DownloadState.merging:
          return null; // not swipeable
      }
      return Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: task.state == DownloadState.scheduled
            ? ac.statusError.withValues(alpha: 0.2)
            : ac.accentFrost.withValues(alpha: 0.2),
        child: icon,
      );
    }

    // Left-swipe background  (red, delete icon)
    Widget? _leftSwipeBackground() {
      if (isMerging) return null;
      return Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        color: ac.statusError.withValues(alpha: 0.2),
        child: Icon(Icons.delete_outline, color: ac.statusError),
      );
    }

    // Right-swipe action  (state-aware)
    VoidCallback? _onRightSwipe() {
      if (isMerging) return null;
      switch (task.state) {
        case DownloadState.scheduled:
          return () => widget.onCancelTask?.call(task)?.call();
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
            color: ac.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ac.glassBorder),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                // Text block — grows vertically for full failed-error text
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: task.state == DownloadState.failed ? 10 : 0,
                    ),
                    child: Column(
                      mainAxisAlignment: task.state == DownloadState.failed
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildNameWidget(
                          task,
                          TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: ac.textPrimary,
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
                                backgroundColor: ac.surfaceElevated,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(color),
                              ),
                            ),
                          ),
                        if (task.state == DownloadState.completed ||
                            task.state == DownloadState.failed ||
                            task.state == DownloadState.paused)
                          const SizedBox(height: 2),
                        // Metadata line (no truncated error — full text below)
                        Text(
                          _metadataLabel(task),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 8.5,
                            fontFamily: 'JetBrainsMono',
                            color: ac.textTertiary,
                          ),
                        ),
                        // Transient status (converting, refreshing, resuming…)
                        if (task.statusMessage != null &&
                            task.statusMessage!.isNotEmpty &&
                            task.state != DownloadState.completed &&
                            task.state != DownloadState.failed)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              task.statusMessage!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9,
                                fontFamily: 'Inter',
                                color: ac.accentFrost,
                              ),
                            ),
                          ),
                        // Failed-task error: full message, card expands
                        if (task.state == DownloadState.failed &&
                            task.errorMessage != null &&
                            task.errorMessage!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6, right: 4),
                            child: SelectableText(
                              _displayErrorMessage(task.errorMessage!),
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.35,
                                fontFamily: 'Inter',
                                color: ac.statusError,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // Action buttons — top-aligned so tall error cards stay tidy
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: task.state == DownloadState.failed ? 8 : 0,
                    ),
                    child: _buildTaskActions(task, color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Strips internal markers (e.g. `[PARTIAL:0.42]`) for on-card display.
  String _displayErrorMessage(String raw) {
    return raw
        .replaceAll(RegExp(r'\[PARTIAL:[\d.]+\]\s*'), '')
        .trim();
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
    final ac = context.ac;
    // ── Primary action icon (visible outside popup) ──────────────
    Widget? primaryAction;

    if (task.state == DownloadState.scheduled) {
      primaryAction = _compactButton(
        icon: Icons.cancel_outlined,
        color: ac.statusError,
        tooltip: 'Cancel scheduled',
        onPressed: () => widget.onCancelTask?.call(task)?.call(),
      );
    } else if (task.state == DownloadState.downloading ||
        task.state == DownloadState.idle) {
      primaryAction = _compactButton(
        icon: Icons.pause_rounded,
        color: ac.accentFrost,
        tooltip: 'Pause',
        onPressed: () => widget.onPauseTask?.call(task)?.call(),
      );
    } else if (task.state == DownloadState.paused) {
      primaryAction = _compactButton(
        icon: Icons.play_arrow_rounded,
        color: ac.accentFrost,
        tooltip: 'Resume',
        onPressed: () => widget.onResumeTask?.call(task)?.call(),
      );
    } else if (task.state == DownloadState.merging) {
      primaryAction = SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(ac.accentFrost),
          ),
        ),
      );
    } else if (task.state == DownloadState.failed) {
      primaryAction = _compactButton(
        icon: Icons.refresh_rounded,
        color: ac.statusError,
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
          child: _popupRow(Icons.merge_type, Colors.orange, 'Force merge'),
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
              Icons.find_replace_rounded, ac.accentFrost, 'Refresh link'),
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
              ac.accentPurple, 'Scan in browser'),
        ),
      );
    }

    // Open source page
    if (task.sourcePageUrl != null && widget.onOpenUrlInBrowser != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'open_source',
          child:
              _popupRow(Icons.open_in_new, ac.accentPurple, 'View source page'),
        ),
      );
    }

    // Delete / Cancel
    final isCompleted = task.state == DownloadState.completed;
    popupItems.add(
      PopupMenuItem(
        value: 'delete',
        child: _popupRow(Icons.delete_outline, ac.statusError,
            isCompleted ? 'Remove' : 'Cancel'),
      ),
    );

    // Properties
    popupItems.add(
      PopupMenuItem(
        value: 'properties',
        child: _popupRow(Icons.info_outline, ac.textSecondary, 'Properties'),
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
                      color: ac.textSecondary),
                  padding: EdgeInsets.zero,
                  splashRadius: 14,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  color: ac.surfaceCard,
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
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
        ),
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
    if (task.state == DownloadState.scheduled) {
      if (task.scheduledStartAt != null) {
        final diff = task.scheduledStartAt!.difference(DateTime.now());
        if (diff.isNegative) {
          parts.add('Starting…');
        } else {
          String pad(int n) => n.toString().padLeft(2, '0');
          if (diff.inDays > 1) {
            parts.add('Scheduled ${pad(task.scheduledStartAt!.hour)}:${pad(task.scheduledStartAt!.minute)} '
                '${task.scheduledStartAt!.month}/${task.scheduledStartAt!.day}');
          } else {
            parts.add('Scheduled ${pad(task.scheduledStartAt!.hour)}:${pad(task.scheduledStartAt!.minute)}');
          }
          if (diff.inMinutes < 60) {
            parts.add('${diff.inMinutes}m left');
          } else if (diff.inHours < 24) {
            parts.add('${diff.inHours}h ${diff.inMinutes % 60}m left');
          }
        }
      } else {
        parts.add('Scheduled');
      }
    } else if (task.state == DownloadState.downloading ||
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
    } else if (task.state == DownloadState.failed) {
      // Full error is shown on its own wrapping lines below — keep the
      // mono metadata row short so the card layout stays scannable.
      if (task.downloadedBytes > 0) {
        parts.add('${formatBytes(task.downloadedBytes)} saved');
      }
      parts.add('Failed');
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
    final ac = context.ac;
    return GestureDetector(
      onTap: () => widget.onOpenDownload(task),
      onLongPress: () => widget.onOpenDownload(task),
      child: Container(
        decoration: BoxDecoration(
          color: ac.surfaceCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ac.glassBorder),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 32,
              color: ac.statusSuccess,
            ),
            const SizedBox(height: 8),
            _buildNameWidget(
              task,
              TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: ac.textPrimary,
              ),
              centered: true,
            ),
            if (task.totalBytes > 0) ...[
              const SizedBox(height: 4),
              Text(
                formatBytes(task.totalBytes),
                style: TextStyle(
                  fontSize: 10,
                  color: ac.textTertiary,
                  fontFamily: 'JetBrainsMono',
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
        title: const Text('Save partial file?'),
        content: Text(
          'The server closed the connection at $pct% completion.\n\n'
          'Merge the partial file to keep what finished, '
          'or retry to download the rest.',
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
                        ? 'Done — Partial file saved.'
                        : "Couldn't merge. The file may be incomplete. Try retrying the download.",
                  );
                }
              }
            },
            child: const Text('Merge and save'),
          ),
        ],
      ),
    );
  }

  /// Called by [DownloadQueue.onResniffDuplicate] when a duplicate URL is
  /// detected while the queue is in manual-resniff mode.  Shows a dialog
  /// asking whether to update the existing download or create a new one.
  void _handleResniffDuplicate(String existingTaskId, DownloadTask newTask) {
    if (!mounted) return;
    widget.queue.resniffPendingTaskId = null; // exit resniff mode
    _showResniffDuplicateDialog(existingTaskId, newTask);
  }

  void _showResniffDuplicateDialog(String existingTaskId, DownloadTask newTask) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Link already queued'),
        content: const Text(
          'This link is already in your download queue.\n\n'
          'The URL may have changed (token refresh). Update the existing '
          'download with the new link, or create a separate one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Create new download alongside existing one — keep the
              // freshly sniffed headers + browser bridges from [newTask].
              final existing = widget.queue.getTask(existingTaskId);
              if (existing != null) {
                final created = DownloadTask(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  url: newTask.url,
                  headers: newTask.headers ?? existing.headers,
                  savePath: existing.savePath.replaceAll(
                    _fileName(existing.savePath),
                    '${_fileName(existing.savePath).replaceAll(RegExp(r'\.[^.]+$'), '')}_${DateTime.now().millisecondsSinceEpoch}${RegExp(r'\.[^.]+$').firstMatch(existing.savePath)?.group(0) ?? ''}',
                  ),
                  tempDir: '${existing.tempDir}_${DateTime.now().millisecondsSinceEpoch}',
                  contentType: newTask.contentType ?? existing.contentType,
                  sourcePageUrl: newTask.sourcePageUrl ?? existing.sourcePageUrl,
                );
                created.copyBrowserBridgesFrom(newTask);
                widget.queue.addTask(created, force: true);
                if (mounted) {
                  AuroraSnackbar.show(context, 'Done — New download created with refreshed link.');
                }
              }
            },
            child: const Text('Create new'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              // Copy URL + headers + WebView bridges from the fresh sniff,
              // wipe stale temp segments, and restart. (Old path only updated
              // the URL, so post-restart "Update link" still 403'd.)
              await widget.queue.updateTaskFromDonor(existingTaskId, newTask);
              if (mounted) {
                AuroraSnackbar.show(
                  context,
                  'Done — Link updated. Download will retry.',
                );
                setState(() {});
              }
            },
            child: const Text('Update existing'),
          ),
        ],
      ),
    );
  }
}
