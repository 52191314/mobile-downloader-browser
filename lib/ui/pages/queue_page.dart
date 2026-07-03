import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../downloader/downloader.dart';
import '../../theme/aurora_colors.dart';
import '../widgets/empty_queue.dart';
import '../widgets/download_task_row.dart';

class QueuePage extends StatefulWidget {
  final DownloadQueue queue;
  final TextEditingController urlController;
  final Future<void> Function() onAddDownload;
  final Future<void> Function(DownloadTask task) onOpenDownload;
  final Future<void> Function(DownloadTask task) onShareDownload;
  final Future<void> Function(DownloadTask task)? onExportDownload;
  final Future<void> Function(DownloadTask task)? onRetryTask;
  final VoidCallback? Function(DownloadTask task)? onPauseTask;
  final VoidCallback? Function(DownloadTask task)? onResumeTask;
  final VoidCallback? Function(DownloadTask task)? onCancelTask;
  final Future<bool> Function(DownloadTask task)? onForceMergeTask;
  final double speedLimitKbps;

  const QueuePage({
    super.key,
    required this.queue,
    required this.urlController,
    required this.onAddDownload,
    required this.onOpenDownload,
    required this.onShareDownload,
    this.onExportDownload,
    this.onRetryTask,
    this.onPauseTask,
    this.onResumeTask,
    this.onCancelTask,
    this.onForceMergeTask,
    required this.speedLimitKbps,
  });

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  StreamSubscription<DownloadTask>? _sub;
  Timer? _rebuildTimer;
  String _selectedFolderFilter = 'All';
  bool _viewMode = false; // false = list, true = grid
  final FocusNode _urlFocusNode = FocusNode();
  bool _hasUrlText = false;

  @override
  void initState() {
    super.initState();
    _hasUrlText = widget.urlController.text.isNotEmpty;
    widget.urlController.addListener(_onUrlTextChanged);
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
  }

  void _onUrlTextChanged() {
    final hasText = widget.urlController.text.isNotEmpty;
    if (hasText != _hasUrlText) {
      if (mounted) setState(() => _hasUrlText = hasText);
    }
  }

  @override
  void dispose() {
    widget.urlController.removeListener(_onUrlTextChanged);
    _urlFocusNode.dispose();
    _rebuildTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  String? _getTaskFolder(DownloadTask task) {
    if (task.exportDirectoryUri != null && task.exportDirectoryUri!.isNotEmpty) {
      final uri = task.exportDirectoryUri!;
      try {
        final decoded = Uri.decodeFull(uri);
        final segments = decoded.split(':');
        if (segments.length > 1) {
          final folderPart = segments.last.split('/').last;
          if (folderPart.isNotEmpty) return folderPart;
        }
      } catch (_) {}
      return 'Custom Folder';
    }
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
    final completed =
        tasks.where((t) => t.state == DownloadState.completed).toList();
    final failed =
        tasks.where((t) => t.state == DownloadState.failed).toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
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
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.download), text: 'Queue'),
              Tab(icon: Icon(Icons.list_alt), text: 'Logs'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildQueueTab(context, tasks, completed, failed),
              _buildLogsTab(context),
            ],
          ),
        ),
      ),
    );
  }

  String _speedLabel(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 KB/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
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

    final sortedTasks = List<DownloadTask>.from(tasks)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final filteredTasks = sortedTasks.where((task) {
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

    return RefreshIndicator(
      onRefresh: () async {
        // Soft refresh: just rebuild the UI
        await Future<void>.delayed(const Duration(milliseconds: 300));
      },
      child: ListView(
        cacheExtent: 2000,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // -- Aggregate stats header --
          _buildAggregateHeader(
            context,
            activeCount: activeCount,
            queuedCount: queuedCount,
            completedCount: filteredCompleted,
            failedCount: filteredFailed,
            totalSpeed: totalSpeed,
          ),
          const SizedBox(height: 16),

          // -- URL input (address / link bar) --
          GestureDetector(
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
                padding: const EdgeInsets.only(
                    left: 4, right: 4, top: 4, bottom: 4),
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
          ),
          const SizedBox(height: 12),

          // -- Folder filter chips --
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
            const SizedBox(height: 12),
          ],

          // -- Bulk action buttons --
          if (filteredTasks.isNotEmpty && !_viewMode)
            _buildBulkActions(filteredTasks, filteredFailed),
          const SizedBox(height: 8),

          // -- Task list or grid --
          if (filteredTasks.isEmpty)
            const SizedBox(
              height: 280,
              child: EmptyQueue(),
            )
          else if (_viewMode)
            _buildGridView(filteredTasks)
          else
            ...filteredTasks.map((task) => _buildTaskRow(context, task)),
        ],
      ),
    );
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
                  const AuroraColors.nordGreen),
              const SizedBox(width: 8),
              _statBadge(Icons.error_outline, '$failedCount', 'Failed',
                  const AuroraColors.nordRed),
            ],
          ),
          if (activeCount > 0 || queuedCount > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.speed, size: 14, color: AuroraColors.mutedText),
                const SizedBox(width: 4),
                Text(
                  '${_speedLabel(totalSpeed)}',
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
        return const AuroraColors.nordGreen; // Green (Nord)
      case DownloadState.failed:
        return const AuroraColors.nordRed; // Red (Nord)
      default:
        return AuroraColors.mutedDeep; // Grey
    }
  }

  IconData _taskIcon(DownloadTask task) {
    switch (task.state) {
      case DownloadState.downloading:
      case DownloadState.idle:
        return Icons.download_rounded;
      case DownloadState.paused:
        return Icons.pause_circle_outline;
      case DownloadState.completed:
        return Icons.check_circle_outline;
      case DownloadState.failed:
        return Icons.error_outline;
      default:
        return Icons.hourglass_empty;
    }
  }

  Widget _buildTaskRow(BuildContext context, DownloadTask task) {
    final color = _statusColor(task.state);
    // null = unknown total → indeterminate bar animates instead of showing 0%
    final progress = task.totalBytes > 0
        ? (task.downloadedBytes / task.totalBytes).clamp(0.0, 1.0)
        : null;

    return Dismissible(
      key: ValueKey('task_${task.id}'),
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        color: AuroraColors.accent.withValues(alpha: 0.2),
        child: Icon(Icons.pause, color: AuroraColors.accent),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AuroraColors.nordRed.withValues(alpha: 0.2),
        child: const Icon(Icons.delete_outline, color: AuroraColors.nordRed),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Swipe right → pause/resume
          if (task.state == DownloadState.downloading ||
              task.state == DownloadState.idle) {
            widget.onPauseTask?.call(task)?.call();
          } else if (task.state == DownloadState.paused) {
            widget.onResumeTask?.call(task)?.call();
          }
          return false; // Don't actually dismiss
        } else {
          // Swipe left → delete
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Remove download?'),
              content: Text('Remove "${_fileName(task.savePath)}"?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Remove'),
                ),
              ],
            ),
          );
          if (confirm == true) {
            widget.onCancelTask?.call(task)?.call();
          }
          return false;
        }
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
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
                      Text(
                        _fileName(task.savePath),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
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
                        ClipRRect(
                          borderRadius: BorderRadius.circular(1),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 2,
                            backgroundColor:
                                AuroraColors.surfaceVariant,
                            valueColor: AlwaysStoppedAnimation<Color>(color),
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
    final list = <Widget>[];

    // 1. Primary Action (Play/Pause/Retry/Open)
    if (task.state == DownloadState.downloading || task.state == DownloadState.idle) {
      list.add(
        _compactButton(
          icon: Icons.pause_rounded,
          color: AuroraColors.accent,
          tooltip: 'Pause',
          onPressed: () => widget.onPauseTask?.call(task)?.call(),
        ),
      );
    } else if (task.state == DownloadState.paused) {
      list.add(
        _compactButton(
          icon: Icons.play_arrow_rounded,
          color: AuroraColors.accent,
          tooltip: 'Resume',
          onPressed: () => widget.onResumeTask?.call(task)?.call(),
        ),
      );
    } else if (task.state == DownloadState.completed) {
      if (widget.onExportDownload != null) {
        list.add(
          _compactButton(
            icon: Icons.drive_file_move_outlined,
            color: const AuroraColors.nordGreen,
            tooltip: 'Export',
            onPressed: () => widget.onExportDownload!(task),
          ),
        );
      }
    } else if (task.state == DownloadState.failed) {
      list.add(
        _compactButton(
          icon: Icons.refresh_rounded,
          color: const AuroraColors.nordRed,
          tooltip: 'Retry',
          onPressed: () => widget.onRetryTask?.call(task),
        ),
      );
      if (widget.onForceMergeTask != null) {
        list.add(
          _compactButton(
            icon: Icons.merge_type,
            color: Colors.orange,
            tooltip: 'Force Merge',
            onPressed: () => widget.onForceMergeTask!(task),
          ),
        );
      }
    }

    // 2. Delete / Cancel Action
    list.add(
      _compactButton(
        icon: Icons.delete_outline,
        color: const AuroraColors.nordRed,
        tooltip: task.state == DownloadState.completed ? 'Remove' : 'Cancel',
        onPressed: () async {
          final isCompleted = task.state == DownloadState.completed;
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(isCompleted ? 'Remove download?' : 'Cancel download?'),
              content: Text(
                isCompleted
                    ? 'Remove "${_fileName(task.savePath)}" from the download list?'
                    : 'Cancel and remove "${_fileName(task.savePath)}" from your queue?\nThis will delete any temporary or downloaded files.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(isCompleted ? 'Remove' : 'Cancel')),
              ],
            ),
          );
          if (confirm == true) {
            widget.onCancelTask?.call(task)?.call();
          }
        },
      ),
    );

    // 3. Info / Properties Action
    list.add(
      _compactButton(
        icon: Icons.info_outline,
        color: AuroraColors.mutedText,
        tooltip: 'Properties',
        onPressed: () {
          showDialog(
            context: context,
            builder: (context) => DownloadPropertiesDialog(
              task: task,
              onOpenDownload: widget.onOpenDownload,
              onShareDownload: widget.onShareDownload,
              onExport: widget.onExportDownload,
            ),
          ).then((_) {
            if (mounted) setState(() {});
          });
        },
      ),
    );

    final rows = <Widget>[];
    for (int i = 0; i < list.length; i += 2) {
      final rowChildren = <Widget>[];
      rowChildren.add(list[i]);
      if (i + 1 < list.length) {
        rowChildren.add(const SizedBox(width: 4));
        rowChildren.add(list[i + 1]);
      }
      rows.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: rowChildren,
        ),
      );
      if (i + 2 < list.length) {
        rows.add(const SizedBox(height: 4));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: rows,
      ),
    );
  }

  String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  String _metadataLabel(DownloadTask task) {
    final parts = <String>[];
    if (task.state == DownloadState.downloading ||
        task.state == DownloadState.idle) {
      if (task.totalBytes > 0) {
        parts.add('${_formatBytes(task.downloadedBytes)} / ${_formatBytes(task.totalBytes)}');
      } else if (task.downloadedBytes > 0) {
        parts.add('${_formatBytes(task.downloadedBytes)} downloaded');
      }
      parts.add(_speedLabel(task.speed));
      final elapsed = DateTime.now().difference(task.createdAt);
      final m = elapsed.inMinutes;
      final s = elapsed.inSeconds % 60;
      parts.add('${m}m ${s}s');
    } else if (task.state == DownloadState.completed && task.totalBytes > 0) {
      parts.add(_formatBytes(task.totalBytes));
    } else if (task.state == DownloadState.completed && task.downloadedBytes > 0) {
      parts.add('${_formatBytes(task.downloadedBytes)} downloaded');
    } else if (task.state == DownloadState.failed && task.errorMessage != null) {
      parts.add(task.errorMessage!.length > 40
          ? '${task.errorMessage!.substring(0, 40)}…'
          : task.errorMessage!);
    } else if (task.state == DownloadState.paused) {
      if (task.totalBytes > 0) {
        parts.add('${_formatBytes(task.downloadedBytes)} / ${_formatBytes(task.totalBytes)}');
      } else if (task.downloadedBytes > 0) {
        parts.add('${_formatBytes(task.downloadedBytes)} downloaded');
      }
      parts.add('Paused');
    }
    return parts.join(' · ');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // ---------------------------------------------------------------------------
  // Grid view (completed only)
  // ---------------------------------------------------------------------------

  Widget _buildGridView(List<DownloadTask> tasks) {
    final completed = tasks
        .where((t) => t.state == DownloadState.completed)
        .toList(growable: false);

    if (completed.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(
          child: Text(
            'No completed downloads yet',
            style: TextStyle(color: AuroraColors.mutedText),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.2,
        ),
        itemCount: completed.length,
        itemBuilder: (context, index) {
          final task = completed[index];
          return _buildGridTile(task);
        },
      ),
    );
  }

  Widget _buildGridTile(DownloadTask task) {
    return GestureDetector(
      onTap: () => widget.onOpenDownload(task),
      onLongPress: () => widget.onShareDownload(task),
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
              color: const AuroraColors.nordGreen,
            ),
            const SizedBox(height: 8),
            Text(
              _fileName(task.savePath),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AuroraColors.text,
              ),
            ),
            if (task.totalBytes > 0) ...[
              const SizedBox(height: 4),
              Text(
                _formatBytes(task.totalBytes),
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

  // ---------------------------------------------------------------------------
  // Logs tab (unchanged, same as before)
  // ---------------------------------------------------------------------------

  Widget _buildLogsTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<LogEntry>>(
      stream: DownloadLogger.instance.onLogsChanged,
      initialData: DownloadLogger.instance.logs,
      builder: (context, snapshot) {
        final logs = snapshot.data ?? [];
        if (logs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.receipt_long_outlined,
                  size: 48,
                  color: scheme.onSurfaceVariant.withAlpha(128),
                ),
                const SizedBox(height: 12),
                Text(
                  'No logs recorded yet',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: scheme.surfaceContainerLow,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${logs.length} logs',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label:
                            const Text('Copy All', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          final text = logs
                              .map((e) =>
                                  '[${e.formattedTime}] [${e.level}] ${e.message}')
                              .join('\n');
                          Clipboard.setData(ClipboardData(text: text));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Logs copied to clipboard')),
                          );
                        },
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label:
                            const Text('Clear', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.error,
                        ),
                        onPressed: () => DownloadLogger.instance.clear(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final entry = logs[index];
                  Color levelColor = scheme.onSurface;
                  IconData levelIcon = Icons.info_outline;
                  if (entry.level == 'WARN') {
                    levelColor = Colors.orange;
                    levelIcon = Icons.warning_amber_outlined;
                  } else if (entry.level == 'ERROR') {
                    levelColor = scheme.error;
                    levelIcon = Icons.error_outline;
                  } else {
                    levelColor = scheme.primary;
                    levelIcon = Icons.info_outline;
                  }

                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(levelIcon, size: 16, color: levelColor),
                        const SizedBox(width: 8),
                        Text(
                          entry.formattedTime,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SelectableText(
                            entry.message,
                            style: TextStyle(
                              fontSize: 12,
                              color: entry.level == 'ERROR'
                                  ? scheme.error
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        ok
                            ? 'Partial file merged successfully.'
                            : 'Failed to merge partial file.',
                      ),
                    ),
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
}
