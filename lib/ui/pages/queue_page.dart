import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../compliance/restricted_media_policy.dart';
import '../../downloader/downloader.dart';
import '../../premium/ffmpeg/ffmpeg_module_loader.dart';
import '../../premium/ffmpeg/ffmpeg_service.dart';
import '../../premium/pro_entitlement.dart';
import '../../premium/pro_features.dart';
import '../../premium/pro_upsell_sheet.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/aurora_palette.dart';
import '../../theme/aurora_tokens.dart';
import '../notifications/aurora_snackbar.dart';
import '../widgets/download_card.dart';
import '../widgets/empty_queue.dart';
import '../widgets/settings_formatters.dart';
import 'ffmpeg_studio_page.dart';

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

/// Lightweight placeholder for a section header inside the lazy list plan —
/// keeps the eager build cost O(sections) instead of O(tasks).
final class _SectionHeaderRow {
  final _TaskSection section;
  final bool collapsed;
  const _SectionHeaderRow(this.section, this.collapsed);
}

/// Lightweight gap marker between sections in the lazy list plan.
final class _SectionGap {
  const _SectionGap();
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
  final Future<void> Function(DownloadTask task)? onSendToPc;
  final Future<void> Function(DownloadTask task)? onMoveToVault;
  final Future<void> Function(DownloadTask task)? onRedownload;
  final Future<void> Function(DownloadTask task)? onOpenFfmpegStudio;
  final VoidCallback? onOpenBrowser;
  final GlobalKey? urlInputKey;

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
    this.onSendToPc,
    this.onMoveToVault,
    this.onRedownload,
    this.onOpenFfmpegStudio,
    this.onOpenBrowser,
    this.urlInputKey,
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

  /// Last-seen state per task id — the listener rebuilds the page only on
  /// transitions (P1b); progress ticks update per-card notifiers instead.
  final Map<String, DownloadState> _lastTaskStates = {};

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
  String? _lastToggledId;

  /// Task ids with a "Save partial file?" dialog currently on screen — used
  /// to dedup [DownloadQueue.onTaskUpdated] emissions so auto-retry
  /// re-failures don't stack duplicate dialogs.
  final Set<String> _partialMergeDialogTaskIds = {};

  /// True while the sort bottom sheet is on screen — guards against a rapid
  /// double-tap on the sort chip pushing two identical sheets.
  bool _sortPickerShowing = false;

  // -- Sectioned-mode partition cache ---------------------------------------
  // Sectioned mode re-sorts 4 sections on every build. Because the queue's
  // task list is mutated in place (no list identity change on progress), the
  // cache is keyed on a cheap fingerprint of the task set + states + the
  // sort/filter/collapse state, so pure progress ticks reuse the previous
  // partition instead of re-sorting. Reset in initState/dispose.
  List<_TaskSection>? _cachedSections;
  int? _sectionsFingerprint;
  int? _sectionsStateKey;
  AColors? _cachedSectionsAc;

  // -- Filtered-list cache (flat mode) --------------------------------------
  // Flat mode re-runs queryTasks (full materialize + O(n log n) sort +
  // substring search) on every rebuild, including the periodic progress-tick
  // rebuilds. Cache the filtered+sorted list keyed on the same fingerprint
  // family as the sectioned partition cache — task set + states +
  // sort-relevant fields + filter/sort/search state — with pure-progress
  // fields (bytes/speed) excluded so progress ticks reuse the cached list.
  // Speed-sorted lists are never cached: task.speed mutates every tick and
  // changes order, so flat speed-sort must keep recomputing (same exception
  // as the sectioned cache). Reset in initState/dispose.
  List<DownloadTask>? _cachedFilteredTasks;
  int? _filteredTasksFingerprint;
  int? _filteredTasksStateKey;

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
      // P1b: rebuild the whole page only when something structural changed
      // (task added / state transitioned). Pure progress ticks update the
      // per-card ValueNotifier and the header's queueVersion instead —
      // rebuilding all cards at 250 ms × active downloads was the top jank
      // vector during downloads. Exception: flat-mode sort by speed depends
      // on live speed, so keep the periodic rebuild while that is active.
      final prevState = _lastTaskStates[task.id];
      if (prevState != task.state) {
        _lastTaskStates[task.id] = task.state;
        if (mounted) setState(() {});
      } else if (_flatList &&
          _sortBy == TaskSortField.speed &&
          mounted &&
          (_rebuildTimer == null || !_rebuildTimer!.isActive)) {
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
    _removedSub = widget.queue.onTaskRemoved.listen((taskId) {
      _lastTaskStates.remove(taskId);
      if (mounted) setState(() {});
    });
    if (_searchQuery.isNotEmpty) {
      _searchExpanded = true;
    }
    _cachedSections = null;
    _sectionsFingerprint = null;
    _sectionsStateKey = null;
    _cachedSectionsAc = null;
    _cachedFilteredTasks = null;
    _filteredTasksFingerprint = null;
    _filteredTasksStateKey = null;
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
    _cachedSections = null;
    _sectionsFingerprint = null;
    _sectionsStateKey = null;
    _cachedSectionsAc = null;
    _cachedFilteredTasks = null;
    _filteredTasksFingerprint = null;
    _filteredTasksStateKey = null;
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
    final filteredTasks = _computeFilteredTasks(tasks);
    final _selectedTasks = filteredTasks
        .where((t) => _selectedIds.contains(t.id))
        .toList();

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              ),
              title: Text(
                AppLocalizations.of(
                  context,
                )!.queueSelected(_selectedIds.length),
              ),
              actions: _buildSelectionActions(_selectedTasks),
            )
          : AppBar(
              title: Text(AppLocalizations.of(context)!.queueTitle),
              actions: [
                IconButton(
                  icon: Icon(_searchExpanded ? Icons.search_off : Icons.search),
                  tooltip: _searchExpanded
                      ? AppLocalizations.of(context)!.queueTooltipCloseSearch
                      : AppLocalizations.of(context)!.queueTooltipSearch,
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
                    tooltip: AppLocalizations.of(context)!.queueTooltipSelect,
                    onPressed: _enterSelectionMode,
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: AppLocalizations.of(
                      context,
                    )!.queueTooltipBulkActions,
                    itemBuilder: (ctx) => _buildBulkOverflowMenu(filteredTasks),
                    onSelected: (value) =>
                        _handleBulkAction(value, filteredTasks),
                  ),
                  IconButton(
                    icon: Icon(
                      _viewMode ? Icons.list_rounded : Icons.grid_view_rounded,
                    ),
                    tooltip: _viewMode
                        ? AppLocalizations.of(context)!.queueTooltipShowList
                        : AppLocalizations.of(context)!.queueTooltipShowGrid,
                    onPressed: () => setState(() => _viewMode = !_viewMode),
                  ),
                ],
              ],
            ),
      body: SafeArea(child: _buildQueueTab(context, tasks, filteredTasks)),
    );
  }

  // ---------------------------------------------------------------------------
  // Queue tab
  // ---------------------------------------------------------------------------

  /// Returns the filtered + sorted task list, cached across progress ticks.
  ///
  /// Flat mode sorts inside [DownloadQueue.queryTasks], so under speed sort the
  /// list order depends on live speed and must never be cached — see the
  /// sectioned-cache speed exception. Otherwise the cache reuses the previous
  /// result while the task-set fingerprint (states + sort-relevant fields,
  /// excluding pure progress) and the filter/sort/search state key are
  /// unchanged, so progress ticks skip the O(n log n) sort + substring search.
  List<DownloadTask> _computeFilteredTasks(List<DownloadTask> tasks) {
    final bypassCache = _flatList && _sortBy == TaskSortField.speed;
    if (!bypassCache) {
      final fingerprint = _tasksFingerprint(tasks);
      final stateKey = _computeSectionsStateKey();
      if (_cachedFilteredTasks != null &&
          fingerprint == _filteredTasksFingerprint &&
          stateKey == _filteredTasksStateKey) {
        return _cachedFilteredTasks!;
      }
      _cachedFilteredTasks = _computeFilteredTasksUncached();
      _filteredTasksFingerprint = fingerprint;
      _filteredTasksStateKey = stateKey;
      return _cachedFilteredTasks!;
    }
    return _computeFilteredTasksUncached();
  }

  List<DownloadTask> _computeFilteredTasksUncached() {
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
        final hasWork = filteredTasks.any(
          (t) =>
              t.state == DownloadState.downloading ||
              t.state == DownloadState.idle ||
              t.state == DownloadState.merging ||
              t.state == DownloadState.paused,
        );
        final completedCount = filteredTasks
            .where((t) => t.state == DownloadState.completed)
            .length;
        if (hasWork && completedCount > 8) {
          _collapsedSections.add('Completed');
        }
      }
    }

    final folderTabs = ['All'];
    if (folders.isNotEmpty) {
      if (tasks.any((t) => _getTaskFolder(t) == null))
        folderTabs.add('Default');
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
                    color: isSelected ? ac.accentFrost : ac.textSecondary,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
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
          sliver: SliverList(delegate: SliverChildListDelegate(headerSlivers)),
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

  /// Cheap fingerprint of [tasks] for the partition + filtered-list caches.
  ///
  /// Order-sensitive rolling hash, so even two tasks *swapping* states (e.g.
  /// one pausing while another resumes in the same tick) invalidate the cache
  /// — a plain sum of state indexes would miss that and serve a stale section
  /// order. `savePath` + `url` always fold in because name sort, the folder
  /// filter, and full-text search all key off them, so an in-place rename /
  /// re-sniff must invalidate the cache under any sort. Also folds in the
  /// sort-relevant field for the current sort so mid-download changes (HLS
  /// `totalBytes` refinement under size sort, priority changes) can't serve a
  /// stale partition. Speed-sorted lists are never cached anyway (task.speed
  /// mutates every tick), so speed is deliberately omitted.
  int _tasksFingerprint(List<DownloadTask> tasks) {
    var fp = tasks.length;
    for (final task in tasks) {
      fp = fp * 31 + task.state.index;
      fp = fp * 31 + task.savePath.hashCode;
      fp = fp * 31 + task.url.hashCode;
      switch (_sortBy) {
        case TaskSortField.date:
          fp = fp * 31 + task.createdAt.millisecondsSinceEpoch;
        case TaskSortField.name:
          break; // savePath already folded above
        case TaskSortField.size:
          fp = fp * 31 + task.totalBytes;
        case TaskSortField.priority:
          fp = fp * 31 + task.priority.index;
        case TaskSortField.state:
          fp = fp * 31 + task.state.index;
        case TaskSortField.speed:
          break; // speed-sorted lists are never cached
      }
      // Scheduled-section default order sorts by scheduledStartAt.
      fp = fp * 31 + (task.scheduledStartAt?.millisecondsSinceEpoch ?? 0);
      fp = fp * 31 + task.id.hashCode;
    }
    return fp;
  }

  /// Fingerprint of the sort/filter/collapse state that affects the partition
  /// output. Filter changes also shift the task fingerprint (the filtered task
  /// set differs), but sort-direction toggles and section collapse changes
  /// would otherwise slip through the fingerprint.
  int _computeSectionsStateKey() {
    var key = _sortBy.index;
    key = key * 31 + (_sortDescending ? 1 : 0);
    key = key * 31 + (_stateFilter?.hashCode ?? 0);
    key = key * 31 + _searchQuery.hashCode;
    key = key * 31 + _selectedFolderFilter.hashCode;
    key = key * 31 + (_flatList ? 1 : 0);
    key = key * 31 + _collapsedSections.hashCode;
    return key;
  }

  /// Partitions [tasks] into 4 ordered sections, sorting each section
  /// according to the section-specific rules (or global sort when
  /// non-default is active).
  List<_TaskSection> _partitionIntoSections(
    List<DownloadTask> tasks,
    AColors ac,
  ) {
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
      final scmp = statePriority[a.state]!.compareTo(statePriority[b.state]!);
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
        _TaskSection('Needs attention', needsAttention, ac.statusError),
      );
    }
    if (scheduled.isNotEmpty) {
      result.add(_TaskSection('Scheduled', scheduled, ac.accentPurple));
    }
    if (completed.isNotEmpty) {
      result.add(_TaskSection('Completed', completed, ac.statusSuccess));
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          (context, index) =>
              _buildTaskRow(context, filteredTasks[index], filteredTasks),
          childCount: filteredTasks.length,
        ),
      );
    }

    // Sectioned mode. Reuse the previously computed sections unless the task
    // set/states (fingerprint), the sort/filter/collapse state, or the
    // palette changed — pure progress ticks on the in-place-mutated task list
    // produce the same partition, so re-sorting all 4 sections every ~500 ms
    // is avoided. Speed-sorted partitions are never cached: `task.speed`
    // changes on every tick, so a cached order would be stale.
    final fingerprint = _tasksFingerprint(filteredTasks);
    final stateKey = _computeSectionsStateKey();
    if (_cachedSections == null ||
        fingerprint != _sectionsFingerprint ||
        stateKey != _sectionsStateKey ||
        !identical(ac, _cachedSectionsAc) ||
        _sortBy == TaskSortField.speed) {
      _cachedSections = _partitionIntoSections(filteredTasks, ac);
      _sectionsFingerprint = fingerprint;
      _sectionsStateKey = stateKey;
      _cachedSectionsAc = ac;
    }
    final sections = _cachedSections!;

    // Lazy sectioned list: build a lightweight plan (headers + task refs,
    // NOT widgets) and let SliverChildBuilderDelegate materialize only the
    // visible rows. Building 40 task cards eagerly per frame is what made
    // batch-added queues (40+ tasks) memory-heavy.
    final plan = <Object>[];
    for (int i = 0; i < sections.length; i++) {
      final section = sections[i];
      final isCollapsed = _collapsedSections.contains(section.title);

      // Small gap between sections
      if (i > 0) {
        plan.add(const _SectionGap());
      }

      plan.add(_SectionHeaderRow(section, isCollapsed));

      if (!isCollapsed) {
        plan.addAll(section.tasks);
      }
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final entry = plan[index];
        if (entry is DownloadTask) {
          return _buildTaskRow(context, entry, filteredTasks);
        }
        if (entry is _SectionHeaderRow) {
          return _buildSectionHeader(entry.section, entry.collapsed);
        }
        return const SizedBox(height: 6);
      }, childCount: plan.length),
    );
  }

  Widget _buildEmptyHint(BuildContext context) {
    if (_searchQuery.isNotEmpty || _stateFilter != null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                EmptyQueue(
                  icon: Icons.search_off,
                  message: _searchQuery.isNotEmpty
                      ? 'Nothing matches "$_searchQuery"'
                      : 'No downloads match this filter',
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: Text(AppLocalizations.of(context)!.queueResetFilters),
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
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 240),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const EmptyQueue(),
              if (widget.onOpenBrowser != null) ...[
                const SizedBox(height: 16),
                TextButton.icon(
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: Text(AppLocalizations.of(context)!.queueOpenBrowser),
                  onPressed: widget.onOpenBrowser,
                ),
              ],
            ],
          ),
        ),
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
        key: widget.urlInputKey,
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
                    prefixIcon: Icon(
                      Icons.link,
                      color: ac.accentFrost,
                      size: 18,
                    ),
                    suffixIcon: _hasUrlText
                        ? IconButton(
                            icon: Icon(
                              Icons.clear,
                              size: 18,
                              color: ac.textSecondary,
                            ),
                            onPressed: () {
                              widget.urlController.clear();
                              _urlFocusNode.requestFocus();
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            splashRadius: 14,
                          )
                        : null,
                    filled: true,
                    fillColor: ac.surfacePanel,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
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
                  style: TextStyle(fontSize: 13, color: ac.textPrimary),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => widget.onAddDownload(),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                height: 40,
                child: IconButton(
                  tooltip: 'Schedule download',
                  icon: Icon(Icons.schedule, size: 20, color: ac.accentFrost),
                  onPressed: () => _scheduleDownloadFromUrlInput(context),
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

  Future<void> _scheduleDownloadFromUrlInput(BuildContext context) async {
    final rawUrl = widget.urlController.text.trim();
    if (rawUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.queueSnackEnterUrl),
        ),
      );
      return;
    }

    if (RestrictedMediaPolicy.isBlocked(mediaUrl: rawUrl)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(RestrictedMediaPolicy.userMessageRestricted),
        ),
      );
      return;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(hours: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (picked == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(picked),
    );
    if (time == null || !context.mounted) return;
    final startAt = DateTime(
      picked.year,
      picked.month,
      picked.day,
      time.hour,
      time.minute,
    );

    final taskId = DateTime.now().millisecondsSinceEpoch.toString();
    final docsDir = await getApplicationDocumentsDirectory();
    final tempDir = await getTemporaryDirectory();
    final baseDir = Directory(p.join(docsDir.path, 'completed'));
    if (!baseDir.existsSync()) {
      await baseDir.create(recursive: true);
    }

    var baseName = rawUrl.split('/').last.split('?').first.trim();
    if (baseName.isEmpty) baseName = 'download';
    baseName = FilenameService.sanitize(baseName);
    if (baseName.isEmpty) baseName = 'download';

    final savePath = FilenameService.uniquePath(
      p.join(baseDir.path, baseName),
      reservedPaths: widget.queue.allTasks.map((t) => t.savePath),
    );

    final task = DownloadTask(
      id: taskId,
      url: rawUrl,
      savePath: savePath,
      tempDir: p.join(tempDir.path, taskId),
    );
    widget.queue.scheduleTask(task, startAt);
    widget.urlController.clear();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.queueSnackDownloadScheduled,
          ),
        ),
      );
    }
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
            prefixIcon: Icon(Icons.search, color: ac.accentFrost, size: 18),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear, size: 18, color: ac.textSecondary),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    splashRadius: 14,
                  )
                : null,
            filled: true,
            fillColor: ac.surfacePanel,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
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
          style: TextStyle(fontSize: 13, color: ac.textPrimary),
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
    _StateFilterOption(
      {DownloadState.downloading, DownloadState.idle, DownloadState.merging},
      'Active',
      Icons.bolt,
    ),
    _StateFilterOption({DownloadState.scheduled}, 'Scheduled', Icons.schedule),
    _StateFilterOption(
      {DownloadState.paused},
      'Paused',
      Icons.pause_circle_outline,
    ),
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
      label: Text(
        sortLabel,
        style: TextStyle(fontFamily: 'Inter', fontSize: 11),
      ),
      backgroundColor: ac.glassSurface,
      side: BorderSide(color: ac.glassBorder),
      onPressed: () => _showSortPicker(context),
    );
  }

  Widget _buildStateChip(_StateFilterOption option) {
    final ac = context.ac;
    final l = AppLocalizations.of(context);
    final isSelected = _stateFilter == option.states;
    final labelText = switch (option.label) {
      'All' => l?.lblFilterAll ?? 'All',
      'Active' => l?.lblFilterDownloading ?? 'Active',
      'Paused' => l?.lblFilterPaused ?? 'Paused',
      'Done' => l?.lblFilterCompleted ?? 'Done',
      'Failed' => l?.lblFilterFailed ?? 'Failed',
      _ => option.label,
    };
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            option.icon,
            size: 13,
            color: isSelected ? ac.accentFrost : ac.textSecondary,
          ),
          const SizedBox(width: 4),
          Text(labelText, style: TextStyle(fontFamily: 'Inter', fontSize: 11)),
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
    if (_sortPickerShowing) return;
    _sortPickerShowing = true;
    final ac = context.ac;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: ac.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppLocalizations.of(context)!.queueSortBy,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: ac.textPrimary,
                    ),
                  ),
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
                          horizontal: 20,
                          vertical: 14,
                        ),
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
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            AppLocalizations.of(context)!.queueFlatList,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              color: ac.textPrimary,
                            ),
                          ),
                        ),
                        Switch(
                          value: _flatList,
                          activeThumbColor: ac.accentFrost,
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
          ),
        );
      },
    ).whenComplete(() => _sortPickerShowing = false);
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
    List<DownloadTask> filteredTasks,
  ) {
    final hasActive = filteredTasks.any(
      (t) =>
          t.state == DownloadState.downloading || t.state == DownloadState.idle,
    );
    final hasPaused = filteredTasks.any((t) => t.state == DownloadState.paused);
    final hasFailed = filteredTasks.any((t) => t.state == DownloadState.failed);
    final hasScheduled = filteredTasks.any(
      (t) => t.state == DownloadState.scheduled,
    );

    final items = <PopupMenuEntry<String>>[];
    if (hasActive) {
      items.add(
        PopupMenuItem(
          value: 'pause_all',
          child: Builder(
            builder: (ctx) => ListTile(
              leading: const Icon(Icons.pause_rounded, size: 20),
              title: Text(AppLocalizations.of(ctx)!.queueBulkPauseAll),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
    }
    if (hasPaused) {
      items.add(
        PopupMenuItem(
          value: 'resume_all',
          child: Builder(
            builder: (ctx) => ListTile(
              leading: const Icon(Icons.play_arrow_rounded, size: 20),
              title: Text(AppLocalizations.of(ctx)!.queueBulkResumeAll),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
    }
    if (hasFailed) {
      items.add(
        PopupMenuItem(
          value: 'retry_all',
          child: Builder(
            builder: (ctx) => ListTile(
              leading: const Icon(Icons.refresh_rounded, size: 20),
              title: Text(AppLocalizations.of(ctx)!.queueBulkRetryFailed),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
    }
    if (hasScheduled) {
      items.add(
        PopupMenuItem(
          value: 'cancel_scheduled',
          child: Builder(
            builder: (ctx) => ListTile(
              leading: const Icon(Icons.event_busy_rounded, size: 20),
              title: Text(AppLocalizations.of(ctx)!.queueBulkCancelScheduled),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
    }
    items.add(
      PopupMenuItem(
        value: 'cancel_active',
        child: Builder(
          builder: (ctx) => ListTile(
            leading: const Icon(Icons.cancel_outlined, size: 20),
            title: Text(AppLocalizations.of(ctx)!.queueBulkCancelActive),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );
    // P12 duplicateFinder: Pro+ can scan the queue for duplicate URLs/names.
    items.add(
      PopupMenuItem(
        value: 'find_duplicates',
        child: Builder(
          builder: (ctx) => ListTile(
            leading: const Icon(Icons.content_copy_rounded, size: 20),
            title: Text(AppLocalizations.of(ctx)!.queueBulkFindDuplicates),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );
    // Batch salvage: force merge partials / refresh links / clear errors.
    if (filteredTasks.any(_isForceMergeEligible) &&
        widget.onForceMergeTask != null) {
      items.add(
        PopupMenuItem(
          value: 'force_merge_all',
          child: Builder(
            builder: (ctx) => ListTile(
              leading: Icon(Icons.merge_type, size: 20, color: Colors.orange),
              title: Text(AppLocalizations.of(ctx)!.cardMenuForceMerge),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
    }
    if (filteredTasks.any(_isResniffEligible) && widget.onResniffAuto != null) {
      items.add(
        PopupMenuItem(
          value: 'resniff_all',
          child: Builder(
            builder: (ctx) => ListTile(
              leading: const Icon(Icons.find_replace_rounded, size: 20),
              title: Text(AppLocalizations.of(ctx)!.cardMenuRefreshLink),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
    }
    if (filteredTasks.any(_isResettable)) {
      items.add(
        PopupMenuItem(
          value: 'reset_errors_all',
          child: Builder(
            builder: (ctx) => ListTile(
              leading: const Icon(Icons.restart_alt, size: 20),
              title: const Text('Clear all errors / reset'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
    }
    return items;
  }

  Future<void> _handleBulkAction(
    String value,
    List<DownloadTask> filteredTasks,
  ) async {
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
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text(
              AppLocalizations.of(context)!.queueDlgCancelScheduledTitle,
            ),
            content: const Text('All scheduled downloads will be removed.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(AppLocalizations.of(context)!.queueDlgKeep),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(AppLocalizations.of(context)!.queueDlgRemoveAll),
              ),
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
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text(
              AppLocalizations.of(context)!.queueDlgCancelActiveTitle,
            ),
            content: const Text(
              'This removes all active and queued downloads.\n'
              'Temporary files will be deleted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove all'),
              ),
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
      case 'find_duplicates':
        _findDuplicates(filteredTasks);
        break;
      case 'force_merge_all':
        for (final task in filteredTasks) {
          if (widget.onForceMergeTask != null && _isForceMergeEligible(task)) {
            await widget.onForceMergeTask!(task);
          }
        }
        break;
      case 'resniff_all':
        for (final task in filteredTasks) {
          if (widget.onResniffAuto != null && _isResniffEligible(task)) {
            await widget.onResniffAuto!(task);
          }
        }
        break;
      case 'reset_errors_all':
        for (final task in filteredTasks) {
          if (_isResettable(task)) {
            await widget.queue.resetTaskState(task.id);
          }
        }
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Selection mode helpers
  // ---------------------------------------------------------------------------

  void _enterSelectionMode() => setState(() {
    _selectionMode = true;
    _selectedIds.clear();
    _lastToggledId = null;
  });

  void _exitSelectionMode() => setState(() {
    _selectionMode = false;
    _selectedIds.clear();
    _lastToggledId = null;
  });

  /// P12 duplicateFinder: scans all tasks (from [widget.queue]) for duplicate
  /// URLs and similar filenames.  Gated behind Pro — free users see an upsell.
  /// Shows results in a dialog.
  Future<void> _findDuplicates(List<DownloadTask> filtered) async {
    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    if (!ProFeatures.allows(ProFeature.duplicateFinder, tier)) {
      showProUpsell(context, ProFeature.duplicateFinder);
      return;
    }

    // Collect all tasks (not just filtered) for a complete scan.
    final all = widget.queue.allTasks;
    final urlMap = <String, List<DownloadTask>>{};
    final nameMap = <String, List<DownloadTask>>{};

    for (final task in all) {
      urlMap.putIfAbsent(task.url, () => []).add(task);
      final name = p.basename(task.savePath);
      nameMap.putIfAbsent(name, () => []).add(task);
    }

    final duplicates = <String>[];
    for (final entry in urlMap.entries) {
      if (entry.value.length > 1) {
        duplicates.add('Same URL (${entry.value.length}x): ${entry.key}');
      }
    }
    for (final entry in nameMap.entries) {
      if (entry.value.length > 1) {
        final tasks = entry.value;
        // Only report if they have different URLs (same name+URL is already
        // reported above).
        if (tasks.map((t) => t.url).toSet().length > 1) {
          duplicates.add('Same filename (${tasks.length}x): ${entry.key}');
        }
      }
    }

    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          duplicates.isEmpty
              ? AppLocalizations.of(context)!.queueDlgNoDuplicates
              : AppLocalizations.of(context)!.queueDlgDuplicatesTitle,
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: duplicates.isEmpty
              ? Text(AppLocalizations.of(context)!.queueDlgNoDuplicates)
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: duplicates.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(duplicates[i]),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocalizations.of(ctx)!.queueDlgClose),
          ),
        ],
      ),
    );
  }

  /// Force-merge eligibility — mirrors the single-task card menu
  /// (partial/interrupted HTTP or HLS tasks only, never native torrents,
  /// never while active).
  bool _isForceMergeEligible(DownloadTask task) {
    final isActive =
        task.state == DownloadState.downloading ||
        task.state == DownloadState.idle ||
        task.state == DownloadState.merging;
    final isMagnet = task.url.startsWith('magnet:');
    final isTorrentEngineTask =
        isMagnet || task.url.toLowerCase().endsWith('.torrent');
    return !isActive &&
        task.state != DownloadState.completed &&
        !isTorrentEngineTask;
  }

  /// Re-sniff eligibility — mirrors the single-task card menu (needs a
  /// live link, not a magnet/blob, not completed, not active).
  bool _isResniffEligible(DownloadTask task) {
    final isActive =
        task.state == DownloadState.downloading ||
        task.state == DownloadState.idle ||
        task.state == DownloadState.merging;
    return task.state != DownloadState.completed &&
        !isActive &&
        !task.url.startsWith('magnet:') &&
        !task.url.startsWith('blob:');
  }

  bool _isResettable(DownloadTask task) =>
      task.state == DownloadState.failed || task.state == DownloadState.merging;

  List<Widget> _buildSelectionActions(List<DownloadTask> selectedTasks) {
    final hasActive = selectedTasks.any(
      (t) =>
          t.state == DownloadState.downloading || t.state == DownloadState.idle,
    );
    final hasPaused = selectedTasks.any((t) => t.state == DownloadState.paused);
    final hasFailed = selectedTasks.any((t) => t.state == DownloadState.failed);
    final hasScheduled = selectedTasks.any(
      (t) => t.state == DownloadState.scheduled,
    );

    return [
      if (hasActive)
        IconButton(
          icon: const Icon(Icons.pause),
          tooltip: 'Pause selected',
          onPressed: () =>
              unawaited(_applyBulkActionToSelected(selectedTasks, 'pause')),
        ),
      if (hasPaused)
        IconButton(
          icon: const Icon(Icons.play_arrow),
          tooltip: 'Resume selected',
          onPressed: () =>
              unawaited(_applyBulkActionToSelected(selectedTasks, 'resume')),
        ),
      if (hasFailed)
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Retry selected',
          onPressed: () =>
              unawaited(_applyBulkActionToSelected(selectedTasks, 'retry')),
        ),
      if (hasScheduled)
        IconButton(
          icon: const Icon(Icons.event_busy),
          tooltip: 'Cancel scheduled',
          onPressed: () => unawaited(
            _applyBulkActionToSelected(selectedTasks, 'cancel_scheduled'),
          ),
        ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove selected',
        onPressed: () =>
            unawaited(_applyBulkActionToSelected(selectedTasks, 'remove')),
      ),
      // Overflow: force merge / re-sniff / clear-error — less frequent
      // batch actions that would overflow the action bar as icons.
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        tooltip: 'More batch actions',
        onSelected: (value) =>
            unawaited(_applyBulkActionToSelected(selectedTasks, value)),
        itemBuilder: (ctx) {
          final l10n = AppLocalizations.of(ctx)!;
          final hasMergeable = selectedTasks.any(_isForceMergeEligible);
          final hasResniffable = selectedTasks.any(_isResniffEligible);
          final hasResettable = selectedTasks.any(_isResettable);
          return [
            if (hasMergeable && widget.onForceMergeTask != null)
              PopupMenuItem(
                value: 'force_merge',
                child: Builder(
                  builder: (ctx) => ListTile(
                    leading: Icon(
                      Icons.merge_type,
                      size: 20,
                      color: Colors.orange,
                    ),
                    title: Text(l10n.cardMenuForceMerge),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            if (hasResniffable && widget.onResniffAuto != null)
              PopupMenuItem(
                value: 'resniff',
                child: Builder(
                  builder: (ctx) => ListTile(
                    leading: const Icon(Icons.find_replace_rounded, size: 20),
                    title: Text(l10n.cardMenuRefreshLink),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            if (hasResettable)
              PopupMenuItem(
                value: 'reset_state',
                child: Builder(
                  builder: (ctx) => ListTile(
                    leading: const Icon(Icons.restart_alt, size: 20),
                    title: const Text('Clear errors / reset'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
          ];
        },
      ),
    ];
  }

  Future<void> _applyBulkActionToSelected(
    List<DownloadTask> selectedTasks,
    String action,
  ) async {
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
        // Consistent with the batch cancel_scheduled above: confirm before
        // removing selected scheduled downloads.
        final confirm = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Cancel scheduled downloads?'),
            content: const Text(
              'Selected scheduled downloads will be removed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove all'),
              ),
            ],
          ),
        );
        if (confirm != true) break;
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
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text(AppLocalizations.of(context)!.queueDlgRemoveSelected),
            content: const Text(
              'Selected downloads will be removed.\n'
              'Temporary files will be deleted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove all'),
              ),
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
      case 'force_merge':
        // Sequential — force merge is disk+I/O heavy and shares the
        // per-task operation chain in the queue.
        for (final task in selectedTasks) {
          if (widget.onForceMergeTask != null && _isForceMergeEligible(task)) {
            await widget.onForceMergeTask!(task);
          }
        }
        break;
      case 'resniff':
        // Sequential — each may show its own "new link" dialog and refresh
        // the task URL before the next one starts.
        for (final task in selectedTasks) {
          if (widget.onResniffAuto != null && _isResniffEligible(task)) {
            await widget.onResniffAuto!(task);
          }
        }
        break;
      case 'reset_state':
        // Clear error fields and re-queue failed/interrupted tasks without
        // forcing a token refresh (unlike Retry).
        for (final task in selectedTasks) {
          if (_isResettable(task)) {
            await widget.queue.resetTaskState(task.id);
          }
        }
        break;
    }
    if (mounted) _exitSelectionMode();
  }

  // ---------------------------------------------------------------------------
  // Status line (single row, unfiltered counts)
  // ---------------------------------------------------------------------------

  Widget _buildStatusLine() {
    // P1b: the aggregate speed/counts line updates on every progress tick
    // but only this subtree rebuilds — the cards rebuild via their own
    // per-task notifiers.
    return ValueListenableBuilder<int>(
      valueListenable: widget.queue.queueVersion,
      builder: (context, _, _) => _buildStatusLineContent(),
    );
  }

  Widget _buildStatusLineContent() {
    final ac = context.ac;
    // Single pass over the queue (one list allocation) collects every count
    // the status line needs. Previously this ran 5 separate O(n) scans, and
    // each `activeTasks`/`queuedTasks`/`allTasks` getter allocated a fresh
    // list. `running`/`waiting` map to the `downloading`/`idle` states, which
    // track the queue's active-set and execution-queue membership.
    var running = 0; // downloading
    var waiting = 0; // idle
    var paused = 0;
    var failed = 0;
    var totalSpeed = 0.0;
    for (final task in widget.queue.allTasks) {
      switch (task.state) {
        case DownloadState.downloading:
          running++;
          totalSpeed += task.speed;
        case DownloadState.idle:
          waiting++;
        case DownloadState.paused:
          paused++;
        case DownloadState.failed:
          failed++;
        // Remaining states are not rendered on the status line.
        case DownloadState.completed:
        case DownloadState.scheduled:
        case DownloadState.merging:
          break;
      }
    }

    if (running == 0 && waiting == 0 && paused == 0 && failed == 0) {
      return const SizedBox.shrink();
    }

    final children = <Widget>[];

    void addSegment(Widget child) {
      if (children.isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '·',
              style: TextStyle(
                color: ac.textTertiary,
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
        );
      }
      children.add(child);
    }

    final activeFilter = () => setState(
      () => _stateFilter = {
        DownloadState.downloading,
        DownloadState.idle,
        DownloadState.merging,
      },
    );
    final pausedFilter = () =>
        setState(() => _stateFilter = {DownloadState.paused});
    final failedFilter = () =>
        setState(() => _stateFilter = {DownloadState.failed});

    // Work section: running + waiting
    if (running > 0 || waiting > 0) {
      if (running > 0) {
        addSegment(
          _statusSegment(
            Icons.play_circle_filled,
            ac.accentFrost,
            '$running running',
            activeFilter,
          ),
        );
      } else {
        addSegment(
          _statusSegment(
            Icons.play_circle_filled,
            ac.textTertiary,
            '0 running',
            activeFilter,
          ),
        );
      }
      if (waiting > 0) {
        addSegment(
          _statusSegment(
            Icons.pending_actions,
            ac.accentPurple,
            '$waiting waiting',
            activeFilter,
          ),
        );
      }
    }

    // Paused
    if (paused > 0) {
      addSegment(
        _statusSegment(
          Icons.pause_circle_outline,
          ac.accentAmber,
          '$paused paused',
          pausedFilter,
        ),
      );
    }

    // Failed
    if (failed > 0) {
      addSegment(
        _statusSegment(
          Icons.error_outline,
          ac.statusError,
          '$failed failed',
          failedFilter,
        ),
      );
    }

    // Speed (non-interactive)
    if (totalSpeed > 0) {
      addSegment(
        _statusSegment(
          Icons.speed,
          ac.accentFrost,
          formatSpeed(totalSpeed),
          null,
        ),
      );
    }

    // Speed limit (non-interactive)
    if (widget.speedLimitKbps > 0) {
      addSegment(
        _statusSegment(
          Icons.tune,
          ac.textTertiary,
          'limit ${widget.speedLimitKbps.round()} KB/s',
          null,
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
  }

  Widget _statusSegment(
    IconData icon,
    Color iconColor,
    String text,
    VoidCallback? onTap,
  ) {
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

  Widget _buildTaskRow(
    BuildContext context,
    DownloadTask task,
    List<DownloadTask> filteredTasks,
  ) {
    final isMerging = task.state == DownloadState.merging;

    final onPauseClosure = widget.onPauseTask?.call(task);
    final onResumeClosure = widget.onResumeTask?.call(task);

    return DownloadCard(
      task: task,
      // P1b: the card's live progress area listens to the per-task
      // notifier instead of waiting for whole-list rebuilds.
      progressListenable: widget.queue.taskNotifierFor(task.id),
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
      onSendToPc: widget.onSendToPc,
      onMoveToVault: widget.onMoveToVault,
      onRedownload: widget.onRedownload,
      onOpenFfmpegStudio: widget.onOpenFfmpegStudio ?? _openFfmpegStudioForTask,
      onSchedule: (t, startAt) {
        widget.queue.scheduleTask(t, startAt);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.queueSnackDownloadScheduled,
              ),
            ),
          );
        }
      },
      enableSwipe: !_selectionMode && !isMerging,
      selectionMode: _selectionMode,
      selected: _selectedIds.contains(task.id),
      onToggleSelected: () => setState(() {
        if (_selectedIds.contains(task.id)) {
          _selectedIds.remove(task.id);
        } else {
          _selectedIds.add(task.id);
        }
        _lastToggledId = task.id;
      }),
      onSelectRange: () => setState(() {
        if (_lastToggledId == null) {
          _selectedIds.add(task.id);
          _lastToggledId = task.id;
          return;
        }
        final startIndex = filteredTasks.indexWhere(
          (t) => t.id == _lastToggledId,
        );
        final endIndex = filteredTasks.indexWhere((t) => t.id == task.id);
        if (startIndex != -1 && endIndex != -1) {
          final minIdx = startIndex < endIndex ? startIndex : endIndex;
          final maxIdx = startIndex > endIndex ? startIndex : endIndex;
          for (var i = minIdx; i <= maxIdx; i++) {
            _selectedIds.add(filteredTasks[i].id);
          }
        }
        _lastToggledId = task.id;
      }),
    );
  }

  Future<void> _openFfmpegStudioForTask(DownloadTask task) async {
    String? path = task.savePath;
    if (path.isEmpty || !File(path).existsSync()) {
      // After a successful download the private copy at [task.savePath] is
      // deleted once the file is published to MediaStore ([task.publicUri]).
      // Materialize it back to a local path so FFmpeg Studio can read it
      // (and write the output next to it).
      final uri = task.publicUri?.trim();
      if (uri != null && uri.isNotEmpty) {
        path = await _materializePublishedSource(uri, task);
      }
    }
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.queueSnackFileMissing),
        ),
      );
      return;
    }
    final resolvedPath = path;

    // Ensure the FFmpeg on-demand module is installed (Play) or ready (GitHub).
    if (!mounted) return;
    final loader = FeatureModuleLoader.instance;
    final moduleReady = await _ensureFfmpegModule(context, loader);
    if (!moduleReady) return;
    if (!mounted) return;

    final name = resolvedPath.replaceAll('\\', '/').split('/').last;
    final item = FfmpegStudioItem(
      id: task.id,
      name: name,
      filePath: resolvedPath,
      fileSizeBytes: task.totalBytes,
    );
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FfmpegStudioPage(
          ffmpegService: FfmpegService(),
          proEntitlement: proUpsellEntitlement ?? ProEntitlement(),
          items: [item],
        ),
      ),
    );
  }

  /// Copies a published content:// URI back into a private workspace so
  /// FFmpeg can operate on a real local path. Returns the local path or null.
  Future<String?> _materializePublishedSource(
    String uri,
    DownloadTask task,
  ) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'ffmpeg_sources'));
      await dir.create(recursive: true);
      var baseName = p.basename(task.savePath);
      if (baseName.isEmpty || baseName == '.') {
        baseName = 'download';
      }
      // Ensure an extension so FFmpeg can sniff the container; the original
      // name already carries one in normal flows.
      final dest = p.join(dir.path, baseName);
      final copied =
          await const MethodChannel(
            'aurora_downloader/public_downloads',
          ).invokeMethod<String>('copyContentUriToFile', {
            'uri': uri,
            'destPath': dest,
          });
      if (copied == null || copied.isEmpty || !File(copied).existsSync()) {
        return null;
      }
      return copied;
    } catch (e, s) {
      debugPrint('[QueuePage] materialize published source failed: $e\n$s');
      return null;
    }
  }

  /// Checks FFmpeg module availability and prompts Play install if needed.
  /// Returns `true` if the module is ready (or fat APK).
  Future<bool> _ensureFfmpegModule(
    BuildContext context,
    FeatureModuleLoader loader,
  ) async {
    final status = loader.statusFor('ffmpeg');
    if (status == FeatureModuleStatus.ready ||
        status == FeatureModuleStatus.notNeeded) {
      return true;
    }

    if (status == FeatureModuleStatus.downloading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.queueSnackFfmpegDownloading,
          ),
        ),
      );
      return false;
    }

    // Show confirmation dialog before triggering the download.
    if (!context.mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.queueDlgFfmpegTitle),
        content: Text(
          'FFmpeg media tools are not included in the base app on this '
          'distribution channel.\n\n'
          'A one-time download of ~10 MB is required. '
          'Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppLocalizations.of(context)!.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppLocalizations.of(context)!.queueDlgDownload),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    if (!context.mounted) return false;

    // Trigger install.
    final ok = await loader.ensureInstalled('ffmpeg');
    if (!context.mounted) return false;

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.queueSnackFfmpegReady),
        ),
      );
      return true;
    }

    // Show failure + retry.
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.queueDlgFfmpegFailedTitle),
        content: const Text(
          'Could not download the FFmpeg module. '
          'Check your network connection and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppLocalizations.of(context)!.queueDlgRetry),
          ),
        ],
      ),
    );
    if (retry == true && context.mounted) {
      return _ensureFfmpegModule(context, loader);
    }
    return false;
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
            child: Text(
              base,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          Text(ext, maxLines: 1, style: style),
        ],
      );
    }
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
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
            Icon(Icons.check_circle_outline, size: 32, color: ac.statusSuccess),
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
    // Dedup: never stack a second "Save partial file?" for the same task
    // (auto-retry re-failure re-emits with a fresh [PARTIAL: message) and
    // never show it while one is already up.
    if (_partialMergeDialogTaskIds.contains(task.id)) return;
    _partialMergeDialogTaskIds.add(task.id);
    final match = RegExp(
      r'\[PARTIAL:([\d.]+)\]',
    ).firstMatch(task.errorMessage ?? '');
    final pct = match?.group(1) ?? '?';
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.queueDlgSavePartialTitle),
        content: Text(
          'The server closed the connection at $pct% completion.\n\n'
          'Merge the partial file to keep what finished, '
          'or retry to download the rest.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(context)!.queueDlgDismiss),
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
            child: Text(AppLocalizations.of(context)!.queueDlgMergeAndSave),
          ),
        ],
      ),
    ).whenComplete(() {
      // Release the dedup slot when the dialog closes, so a later genuine
      // re-failure (new task, or user dismissed and it failed again) can
      // prompt again.
      _partialMergeDialogTaskIds.remove(task.id);
    });
  }

  /// Called by [DownloadQueue.onResniffDuplicate] when a duplicate URL is
  /// detected while the queue is in manual-resniff mode.  Shows a dialog
  /// asking whether to update the existing download or create a new one.
  void _handleResniffDuplicate(String existingTaskId, DownloadTask newTask) {
    if (!mounted) return;
    widget.queue.resniffPendingTaskId = null; // exit resniff mode
    _showResniffDuplicateDialog(existingTaskId, newTask);
  }

  void _showResniffDuplicateDialog(
    String existingTaskId,
    DownloadTask newTask,
  ) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          AppLocalizations.of(context)!.queueDlgLinkAlreadyQueuedTitle,
        ),
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
                  tempDir:
                      '${existing.tempDir}_${DateTime.now().millisecondsSinceEpoch}',
                  contentType: newTask.contentType ?? existing.contentType,
                  sourcePageUrl:
                      newTask.sourcePageUrl ?? existing.sourcePageUrl,
                );
                created.copyBrowserBridgesFrom(newTask);
                widget.queue.addTask(created, force: true);
                if (mounted) {
                  AuroraSnackbar.show(
                    context,
                    AppLocalizations.of(context)!.queueSnackNewDownloadCreated,
                  );
                }
              }
            },
            child: Text(AppLocalizations.of(context)!.queueDlgCreateNew),
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
