import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../downloader/downloader.dart';
import '../../theme/aurora_palette.dart';
import '../../theme/aurora_tokens.dart';
import '../notifications/aurora_snackbar.dart';
import '../widgets/download_card.dart';
import '../widgets/empty_queue.dart';
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

/// Describes a section in the sectioned queue layout.
final class _TaskSection {
  final String title;
  final List<DownloadTask> tasks;
  final Color accentColor;
  const _TaskSection(this.title, this.tasks, this.accentColor);
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
  final VoidCallback? onOpenBrowser;

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
    this.onOpenBrowser,
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
  bool _flatList = false;
  bool _searchExpanded = false;
  final Set<String> _collapsedSections = {};
  bool _sectionsInitialized = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

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
    if (_searchQuery.isNotEmpty) {
      _searchExpanded = true;
    }
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
    final filteredTasks = _computeFilteredTasks();
    final _selectedTasks =
        filteredTasks.where((t) => _selectedIds.contains(t.id)).toList();

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              ),
              title: Text('${_selectedIds.length} selected'),
              actions: _buildSelectionActions(_selectedTasks),
            )
          : AppBar(
              title: const Text('Queue'),
              actions: [
                IconButton(
                  icon: Icon(
                      _searchExpanded ? Icons.search_off : Icons.search),
                  tooltip: _searchExpanded ? 'Close search' : 'Search',
                  onPressed: () => setState(() {
                    _searchExpanded = !_searchExpanded;
                    if (!_searchExpanded) {
                      _searchController.clear();
                      _searchQuery = '';
                    }
                  }),
                ),
                if (filteredTasks.isNotEmpty) ...[
                  IconButton(
                    icon: const Icon(Icons.checklist),
                    tooltip: 'Select',
                    onPressed: _enterSelectionMode,
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'Bulk actions',
                    itemBuilder: (ctx) =>
                        _buildBulkOverflowMenu(filteredTasks),
                    onSelected: (value) =>
                        _handleBulkAction(value, filteredTasks),
                  ),
                  IconButton(
                    icon: Icon(_viewMode
                        ? Icons.list_rounded
                        : Icons.grid_view_rounded),
                    tooltip: _viewMode ? 'Show as list' : 'Completed history grid',
                    onPressed: () =>
                        setState(() => _viewMode = !_viewMode),
                  ),
                ],
              ],
            ),
      body: SafeArea(
        child: _buildQueueTab(context, tasks, filteredTasks),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Queue tab
  // ---------------------------------------------------------------------------

  List<DownloadTask> _computeFilteredTasks() {
    final queriedTasks = widget.queue.queryTasks(
      states: _stateFilter,
      query: _searchQuery.isNotEmpty ? _searchQuery : null,
      sortBy: _flatList ? _sortBy : null,
      sortDescending: _flatList ? _sortDescending : true,
    );
    return queriedTasks.where((task) {
      if (_selectedFolderFilter == 'All') return true;
      final folder = _getTaskFolder(task);
      if (_selectedFolderFilter == 'Default') return folder == null;
      return folder == _selectedFolderFilter;
    }).toList();
  }

  Widget _buildQueueTab(
    BuildContext context,
    List<DownloadTask> tasks,
    List<DownloadTask> filteredTasks,
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

    // Initialize section collapse state once per session (cold-start).
    if (!_sectionsInitialized) {
      _sectionsInitialized = true;
      if (!_flatList) {
        final hasWork = filteredTasks.any((t) =>
            t.state == DownloadState.downloading ||
            t.state == DownloadState.idle ||
            t.state == DownloadState.merging ||
            t.state == DownloadState.paused);
        final completedCount =
            filteredTasks.where((t) => t.state == DownloadState.completed).length;
        if (hasWork && completedCount > 8) {
          _collapsedSections.add('Completed');
        }
      }
    }

    final folderTabs = ['All'];
    if (folders.isNotEmpty) {
      if (tasks.any((t) => _getTaskFolder(t) == null)) folderTabs.add('Default');
      folderTabs.addAll(folders.toList()..sort());
    }

    final headerSlivers = <Widget>[
      if (_searchExpanded) ...[
        _buildSearchBar(context),
        const SizedBox(height: 10),
      ],
      _buildStatusLine(),
      const SizedBox(height: 8),
      _buildUrlInputBar(context),
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
    ];

    return CustomScrollView(
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
    );
  }

  /// Compares two tasks using the current global sort settings.
  int _compareTasks(DownloadTask a, DownloadTask b) {
    int cmp;
    switch (_sortBy) {
      case TaskSortField.date:
        cmp = a.createdAt.compareTo(b.createdAt);
        break;
      case TaskSortField.name:
        cmp = taskDisplayName(a).compareTo(taskDisplayName(b));
        break;
      case TaskSortField.size:
        cmp = a.totalBytes.compareTo(b.totalBytes);
        break;
      case TaskSortField.priority:
        cmp = a.priority.compareTo(b.priority);
        break;
      case TaskSortField.state:
        cmp = a.state.index.compareTo(b.state.index);
        break;
      case TaskSortField.speed:
        cmp = a.speed.compareTo(b.speed);
        break;
    }
    return _sortDescending ? -cmp : cmp;
  }

  /// Partitions [tasks] into 4 ordered sections, sorting each section
  /// according to the section-specific rules (or global sort when
  /// non-default is active).
  List<_TaskSection> _partitionIntoSections(
      List<DownloadTask> tasks, AColors ac) {
    final work = <DownloadTask>[];
    final needsAttention = <DownloadTask>[];
    final scheduled = <DownloadTask>[];
    final completed = <DownloadTask>[];

    for (final task in tasks) {
      switch (task.state) {
        case DownloadState.downloading:
        case DownloadState.idle:
        case DownloadState.merging:
        case DownloadState.paused:
          work.add(task);
        case DownloadState.failed:
          needsAttention.add(task);
        case DownloadState.scheduled:
          scheduled.add(task);
        case DownloadState.completed:
          completed.add(task);
      }
    }

    // Work: state sub-order, then user sort within each state.
    const statePriority = {
      DownloadState.downloading: 0,
      DownloadState.merging: 1,
      DownloadState.paused: 2,
      DownloadState.idle: 3,
    };
    work.sort((a, b) {
      final scmp =
          statePriority[a.state]!.compareTo(statePriority[b.state]!);
      if (scmp != 0) return scmp;
      return _compareTasks(a, b);
    });

    // Needs attention: default date sort → newest first; else user sort.
    if (_sortBy == TaskSortField.date && _sortDescending) {
      needsAttention.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else {
      needsAttention.sort(_compareTasks);
    }

    // Scheduled: default date sort → scheduledStartAt asc; else user sort.
    if (_sortBy == TaskSortField.date && _sortDescending) {
      scheduled.sort((a, b) {
        final aStart = a.scheduledStartAt ?? a.createdAt;
        final bStart = b.scheduledStartAt ?? b.createdAt;
        return aStart.compareTo(bStart);
      });
    } else {
      scheduled.sort(_compareTasks);
    }

    // Completed: always user sort.
    completed.sort(_compareTasks);

    final result = <_TaskSection>[];
    if (work.isNotEmpty) {
      result.add(_TaskSection('Work', work, ac.accentFrost));
    }
    if (needsAttention.isNotEmpty) {
      result.add(
          _TaskSection('Needs attention', needsAttention, ac.statusError));
    }
    if (scheduled.isNotEmpty) {
      result.add(
          _TaskSection('Scheduled', scheduled, ac.accentPurple));
    }
    if (completed.isNotEmpty) {
      result.add(
          _TaskSection('Completed', completed, ac.statusSuccess));
    }
    return result;
  }

  /// Builds a collapsible section header with a left accent bar, name,
  /// count badge, and rotating chevron.
  Widget _buildSectionHeader(_TaskSection section, bool isCollapsed) {
    final ac = context.ac;
    return InkWell(
      onTap: () {
        setState(() {
          if (isCollapsed) {
            _collapsedSections.remove(section.title);
          } else {
            _collapsedSections.add(section.title);
          }
        });
      },
      child: SizedBox(
        height: 32,
        child: Padding(
          padding: const EdgeInsets.only(left: 4, right: 4),
          child: Row(
            children: [
              // Colored left accent bar (3px × 16px)
              Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  color: section.accentColor,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              const SizedBox(width: 8),
              // Section name
              Text(
                section.title,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ac.textPrimary,
                ),
              ),
              const SizedBox(width: 6),
              // Count badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: section.accentColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${section.tasks.length}',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: section.accentColor,
                  ),
                ),
              ),
              const Spacer(),
              // Rotating chevron
              AnimatedRotation(
                turns: isCollapsed ? -0.25 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.expand_more,
                  size: 18,
                  color: ac.textSecondary,
                ),
              ),
            ],
          ),
        ),
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
                'No finished downloads yet. Completed files will appear here.',
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

    if (_flatList) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildTaskRow(context, filteredTasks[index]),
          childCount: filteredTasks.length,
        ),
      );
    }

    // Sectioned mode
    final sections = _partitionIntoSections(filteredTasks, ac);

    final items = <Widget>[];
    for (int i = 0; i < sections.length; i++) {
      final section = sections[i];
      final isCollapsed = _collapsedSections.contains(section.title);

      // Small gap between sections
      if (i > 0) {
        items.add(const SizedBox(height: 6));
      }

      items.add(_buildSectionHeader(section, isCollapsed));

      if (!isCollapsed) {
        for (final task in section.tasks) {
          items.add(_buildTaskRow(context, task));
        }
      }
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => items[index],
        childCount: items.length,
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
    return SizedBox(
      height: 280,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const EmptyQueue(),
          if (widget.onOpenBrowser != null) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              icon: const Icon(Icons.travel_explore, size: 18),
              label: const Text('Open Browser'),
              onPressed: widget.onOpenBrowser,
            ),
          ],
        ],
      ),
    );
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
                const SizedBox(height: 8),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Flat list (no sections)',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            color: ac.textPrimary,
                          ),
                        ),
                      ),
                      Switch(
                        value: _flatList,
                        activeColor: ac.accentFrost,
                        onChanged: (v) {
                          setState(() => _flatList = v);
                          Navigator.pop(ctx);
                        },
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
  // Bulk action overflow menu (AppBar)
  // ---------------------------------------------------------------------------

  List<PopupMenuEntry<String>> _buildBulkOverflowMenu(
      List<DownloadTask> filteredTasks) {
    final hasActive = filteredTasks
        .any((t) => t.state == DownloadState.downloading || t.state == DownloadState.idle);
    final hasPaused = filteredTasks.any((t) => t.state == DownloadState.paused);
    final hasFailed = filteredTasks.any((t) => t.state == DownloadState.failed);
    final hasScheduled = filteredTasks.any((t) => t.state == DownloadState.scheduled);

    final items = <PopupMenuEntry<String>>[];
    if (hasActive) {
      items.add(const PopupMenuItem(
        value: 'pause_all',
        child: ListTile(
          leading: Icon(Icons.pause_rounded, size: 20),
          title: Text('Pause all active'),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ));
    }
    if (hasPaused) {
      items.add(const PopupMenuItem(
        value: 'resume_all',
        child: ListTile(
          leading: Icon(Icons.play_arrow_rounded, size: 20),
          title: Text('Resume all paused'),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ));
    }
    if (hasFailed) {
      items.add(const PopupMenuItem(
        value: 'retry_all',
        child: ListTile(
          leading: Icon(Icons.refresh_rounded, size: 20),
          title: Text('Retry all failed'),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ));
    }
    if (hasScheduled) {
      items.add(const PopupMenuItem(
        value: 'cancel_scheduled',
        child: ListTile(
          leading: Icon(Icons.event_busy_rounded, size: 20),
          title: Text('Cancel scheduled'),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ));
    }
    items.add(const PopupMenuItem(
      value: 'cancel_active',
      child: ListTile(
        leading: Icon(Icons.cancel_outlined, size: 20),
        title: Text('Cancel active'),
        dense: true,
        contentPadding: EdgeInsets.zero,
      ),
    ));
    return items;
  }

  Future<void> _handleBulkAction(
      String value, List<DownloadTask> filteredTasks) async {
    switch (value) {
      case 'pause_all':
        for (final task in filteredTasks) {
          if ((task.state == DownloadState.downloading ||
                  task.state == DownloadState.idle) &&
              widget.onPauseTask != null) {
            widget.onPauseTask!(task)?.call();
          }
        }
        break;
      case 'resume_all':
        for (final task in filteredTasks) {
          if (task.state == DownloadState.paused &&
              widget.onResumeTask != null) {
            widget.onResumeTask!(task)?.call();
          }
        }
        break;
      case 'retry_all':
        for (final task in filteredTasks) {
          if (task.state == DownloadState.failed &&
              widget.onRetryTask != null) {
            widget.onRetryTask!(task);
          }
        }
        break;
      case 'cancel_scheduled':
        if (widget.onCancelTask == null) break;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cancel scheduled downloads?'),
            content: const Text(
              'All scheduled downloads will be removed.',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Keep')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Remove all')),
            ],
          ),
        );
        if (confirm == true) {
          for (final task in filteredTasks) {
            if (task.state == DownloadState.scheduled) {
              widget.onCancelTask!(task)?.call();
            }
          }
        }
        break;
      case 'cancel_active':
        if (widget.onCancelTask == null) break;
        final confirmActive = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cancel active downloads?'),
            content: const Text(
              'This removes all active and queued downloads.\n'
              'Temporary files will be deleted.',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Keep')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Remove all')),
            ],
          ),
        );
        if (confirmActive == true) {
          for (final task in filteredTasks) {
            if (task.state != DownloadState.completed &&
                task.state != DownloadState.scheduled) {
              widget.onCancelTask!(task)?.call();
            }
          }
        }
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Selection mode helpers
  // ---------------------------------------------------------------------------

  void _enterSelectionMode() =>
      setState(() { _selectionMode = true; _selectedIds.clear(); });

  void _exitSelectionMode() =>
      setState(() { _selectionMode = false; _selectedIds.clear(); });

  List<Widget> _buildSelectionActions(List<DownloadTask> selectedTasks) {
    final hasActive = selectedTasks.any(
        (t) => t.state == DownloadState.downloading || t.state == DownloadState.idle);
    final hasPaused = selectedTasks.any((t) => t.state == DownloadState.paused);
    final hasFailed = selectedTasks.any((t) => t.state == DownloadState.failed);
    final hasScheduled = selectedTasks.any((t) => t.state == DownloadState.scheduled);

    return [
      if (hasActive)
        IconButton(
          icon: const Icon(Icons.pause),
          tooltip: 'Pause selected',
          onPressed: () => unawaited(
              _applyBulkActionToSelected(selectedTasks, 'pause')),
        ),
      if (hasPaused)
        IconButton(
          icon: const Icon(Icons.play_arrow),
          tooltip: 'Resume selected',
          onPressed: () => unawaited(
              _applyBulkActionToSelected(selectedTasks, 'resume')),
        ),
      if (hasFailed)
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Retry selected',
          onPressed: () => unawaited(
              _applyBulkActionToSelected(selectedTasks, 'retry')),
        ),
      if (hasScheduled)
        IconButton(
          icon: const Icon(Icons.event_busy),
          tooltip: 'Cancel scheduled',
          onPressed: () => unawaited(
              _applyBulkActionToSelected(selectedTasks, 'cancel_scheduled')),
        ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove selected',
        onPressed: () =>
            unawaited(_applyBulkActionToSelected(selectedTasks, 'remove')),
      ),
    ];
  }

  Future<void> _applyBulkActionToSelected(
      List<DownloadTask> selectedTasks, String action) async {
    switch (action) {
      case 'pause':
        for (final task in selectedTasks) {
          if ((task.state == DownloadState.downloading ||
                  task.state == DownloadState.idle) &&
              widget.onPauseTask != null) {
            widget.onPauseTask!(task)?.call();
          }
        }
        break;
      case 'resume':
        for (final task in selectedTasks) {
          if (task.state == DownloadState.paused &&
              widget.onResumeTask != null) {
            widget.onResumeTask!(task)?.call();
          }
        }
        break;
      case 'retry':
        for (final task in selectedTasks) {
          if (task.state == DownloadState.failed &&
              widget.onRetryTask != null) {
            widget.onRetryTask!(task);
          }
        }
        break;
      case 'cancel_scheduled':
        if (widget.onCancelTask == null) break;
        for (final task in selectedTasks) {
          if (task.state == DownloadState.scheduled) {
            widget.onCancelTask!(task)?.call();
          }
        }
        break;
      case 'remove':
        if (widget.onCancelTask == null) break;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Remove selected downloads?'),
            content: const Text(
              'Selected downloads will be removed.\n'
              'Temporary files will be deleted.',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Keep')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Remove all')),
            ],
          ),
        );
        if (confirm == true) {
          for (final task in selectedTasks) {
            if (task.state != DownloadState.completed) {
              widget.onCancelTask!(task)?.call();
            } else {
              await widget.queue.cancelTaskAsync(task.id);
            }
          }
        }
        break;
    }
    _exitSelectionMode();
  }

  // ---------------------------------------------------------------------------
  // Status line (single row, unfiltered counts)
  // ---------------------------------------------------------------------------

  Widget _buildStatusLine() {
    final ac = context.ac;
    final running = widget.queue.activeTasks.length;
    final waiting = widget.queue.queuedTasks.length;
    final paused =
        widget.queue.allTasks.where((t) => t.state == DownloadState.paused).length;
    final failed =
        widget.queue.allTasks.where((t) => t.state == DownloadState.failed).length;
    final totalSpeed = widget.queue.allTasks
        .where((t) => t.state == DownloadState.downloading)
        .fold<double>(0.0, (sum, t) => sum + t.speed);

    if (running == 0 && waiting == 0 && paused == 0 && failed == 0) {
      return const SizedBox.shrink();
    }

    final children = <Widget>[];

    void addSegment(Widget child) {
      if (children.isNotEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('·',
              style: TextStyle(
                  color: ac.textTertiary,
                  fontSize: 11,
                  fontFamily: 'JetBrainsMono')),
        ));
      }
      children.add(child);
    }

    final activeFilter = () => setState(() => _stateFilter = {
          DownloadState.downloading,
          DownloadState.idle,
          DownloadState.merging,
        });
    final pausedFilter =
        () => setState(() => _stateFilter = {DownloadState.paused});
    final failedFilter =
        () => setState(() => _stateFilter = {DownloadState.failed});

    // Work section: running + waiting
    if (running > 0 || waiting > 0) {
      if (running > 0) {
        addSegment(_statusSegment(
          Icons.play_circle_filled,
          ac.accentFrost,
          '$running running',
          activeFilter,
        ));
      } else {
        addSegment(_statusSegment(
          Icons.play_circle_filled,
          ac.textTertiary,
          '0 running',
          activeFilter,
        ));
      }
      if (waiting > 0) {
        addSegment(_statusSegment(
          Icons.pending_actions,
          ac.accentPurple,
          '$waiting waiting',
          activeFilter,
        ));
      }
    }

    // Paused
    if (paused > 0) {
      addSegment(_statusSegment(
        Icons.pause_circle_outline,
        ac.accentAmber,
        '$paused paused',
        pausedFilter,
      ));
    }

    // Failed
    if (failed > 0) {
      addSegment(_statusSegment(
        Icons.error_outline,
        ac.statusError,
        '$failed failed',
        failedFilter,
      ));
    }

    // Speed (non-interactive)
    if (totalSpeed > 0) {
      addSegment(_statusSegment(
        Icons.speed,
        ac.accentFrost,
        formatSpeed(totalSpeed),
        null,
      ));
    }

    // Speed limit (non-interactive)
    if (widget.speedLimitKbps > 0) {
      addSegment(_statusSegment(
        Icons.tune,
        ac.textTertiary,
        'limit ${widget.speedLimitKbps.round()} KB/s',
        null,
      ));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
  }

  Widget _statusSegment(
      IconData icon, Color iconColor, String text, VoidCallback? onTap) {
    final ac = context.ac;
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: iconColor),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'JetBrainsMono',
              color: onTap != null ? ac.accentFrost : ac.textSecondary,
              fontWeight: onTap != null ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Task row (list view) — delegates to DownloadCard
  // ---------------------------------------------------------------------------

  Widget _buildTaskRow(BuildContext context, DownloadTask task) {
    final isMerging = task.state == DownloadState.merging;

    final onPauseClosure = widget.onPauseTask?.call(task);
    final onResumeClosure = widget.onResumeTask?.call(task);

    return DownloadCard(
      task: task,
      onOpenDownload: widget.onOpenDownload,
      onPause: onPauseClosure,
      onResume: onResumeClosure,
      onRetry: widget.onRetryTask == null
          ? null
          : () => widget.onRetryTask!(task),
      onCancel: () => unawaited(_deleteTaskWithUndo(task)),
      onForceMerge: widget.onForceMergeTask == null
          ? null
          : () => unawaited(widget.onForceMergeTask!(task)),
      onResniffAuto: widget.onResniffAuto,
      onResniffManual: widget.onResniffManual,
      onOpenUrlInBrowser: widget.onOpenUrlInBrowser,
      onShare: widget.onShareDownload,
      onExport: widget.onExportDownload,
      enableSwipe: !_selectionMode && !isMerging,
      selectionMode: _selectionMode,
      selected: _selectedIds.contains(task.id),
      onToggleSelected: () => setState(() {
        if (_selectedIds.contains(task.id)) {
          _selectedIds.remove(task.id);
        } else {
          _selectedIds.add(task.id);
        }
      }),
    );
  }

  String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').last;
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
      'Done — Removed "${taskDisplayName(task)}".',
      actionLabel: 'Undo',
      onAction: undoAction,
    );
  }

  /// Renders the task filename with middle-ellipsis for the grid tile.
  Widget _buildGridNameWidget(DownloadTask task, TextStyle style) {
    final name = taskDisplayName(task);
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx > 0 && name.length - dotIdx <= 6) {
      final base = name.substring(0, dotIdx);
      final ext = name.substring(dotIdx);
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
    return Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
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
            _buildGridNameWidget(
              task,
              TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: ac.textPrimary,
              ),
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
