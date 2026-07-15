import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/aurora_palette.dart';
import '../../downloader/downloader.dart';
import '../../platform/public_downloads_service.dart';
import '../notifications/aurora_snackbar.dart';
import 'panel.dart';
import 'settings_formatters.dart';

class DownloadTaskRow extends StatelessWidget {
  final DownloadTask task;
  final Future<void> Function(DownloadTask task) onOpenDownload;
  final VoidCallback? onRetry;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final VoidCallback? onForceMerge;

  const DownloadTaskRow({
    super.key,
    required this.task,
    required this.onOpenDownload,
    this.onRetry,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.onForceMerge,
  });

  void _showPropertiesDialog(BuildContext context, DownloadTask task) {
    showDialog(
      context: context,
      builder: (context) => DownloadPropertiesDialog(
        task: task,
        onOpenDownload: onOpenDownload,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    if (task.state == DownloadState.completed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _buildTaskNameWidget(
                      task,
                      const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    tooltip: 'View details',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () => _showPropertiesDialog(context, task),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    'Completed',
                    style: TextStyle(
                      fontSize: 12,
                      color: ac.accentFrost,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '•  ${formatBytes(task.downloadedBytes)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: ac.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final hasKnownTotal = task.totalBytes > 0;
    final isIndeterminate =
        task.state == DownloadState.downloading && !hasKnownTotal;
    final progress = hasKnownTotal
        ? task.progress.clamp(0.0, 1.0).toDouble()
        : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: filename + action icons (no left state icon)
            Row(
              children: [
                Expanded(
                  child: _buildTaskNameWidget(
                    task,
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
                if (onForceMerge != null && task.state == DownloadState.failed)
                  IconButton(
                    key: Key('force_merge_${task.id}'),
                    icon: const Icon(Icons.merge_type, size: 20),
                    tooltip: 'Force merge — build the final file from whatever finished. Use when a download stalled and you want the partial file now.',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: onForceMerge,
                  ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Retry',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: task.state == DownloadState.failed ? onRetry : null,
                ),
                IconButton(
                  icon: Icon(
                    task.state == DownloadState.paused ? Icons.play_arrow : Icons.pause,
                    size: 20,
                  ),
                  tooltip: task.state == DownloadState.paused ? 'Resume' : 'Pause',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: (task.state == DownloadState.downloading || task.state == DownloadState.idle)
                      ? onPause
                      : (task.state == DownloadState.paused ? onResume : null),
                ),
                IconButton(
                  icon: const Icon(Icons.info_outline, size: 20),
                  tooltip: 'View details',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () => _showPropertiesDialog(context, task),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: task.state == DownloadState.completed ? 'Remove' : 'Cancel',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: onCancel != null
                      ? () async {
                          final isCompleted = task.state == DownloadState.completed;
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(isCompleted ? 'Remove download?' : 'Cancel download?'),
                              content: Text(
                                isCompleted
                                    ? 'Remove "${taskDisplayName(task)}" from your queue? The file stays on your device.'
                                    : 'Cancel "${taskDisplayName(task)}" and remove it from your queue?\nTemporary files will be deleted.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(false),
                                  child: const Text('Keep'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(true),
                                  child: Text(isCompleted ? 'Remove' : 'Cancel'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            onCancel!();
                          }
                        }
                      : null,
                ),
              ],
            ),
            // Stats row + progress bar (for active/paused/idle/failed tasks)
            if (task.state == DownloadState.downloading ||
                task.state == DownloadState.paused ||
                task.state == DownloadState.idle) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatBytesPair(task.downloadedBytes, task.totalBytes),
                    style: TextStyle(fontSize: 12, color: ac.textSecondary),
                  ),
                  Text(
                    task.state == DownloadState.downloading
                        ? formatSpeed(task.speed)
                        : stateLabel(task.state),
                    style: TextStyle(fontSize: 12, color: ac.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              RepaintBoundary(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: isIndeterminate ? null : progress,
                    minHeight: 6,
                  ),
                ),
              ),
            ],
            // Error message for failed tasks
            if (task.state == DownloadState.failed &&
                task.errorMessage != null &&
                task.errorMessage!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 14,
                    color: ac.statusError,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      task.errorMessage!,
                      style: TextStyle(
                        fontSize: 12,
                        color: ac.statusError,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Renders the task filename with middle-ellipsis: the base name
  /// is end-ellipsized inside an Expanded, while the file extension
  /// sits in a separate non-shrinking Text so it is always visible.
  /// For filenames without a recognizable extension, falls back to a
  /// plain Text with end-ellipsis.
  Widget _buildTaskNameWidget(DownloadTask task, TextStyle style) {
    final name = taskDisplayName(task);
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx > 0 && name.length - dotIdx <= 6) {
      final base = name.substring(0, dotIdx);
      final ext = name.substring(dotIdx); // includes the dot
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
}

class DownloadPropertiesDialog extends StatefulWidget {
  final DownloadTask task;
  final Future<void> Function(DownloadTask task) onOpenDownload;
  final void Function(String url)? onOpenUrlInBrowser;
  final void Function(DownloadTask task)? onTaskUpdated;
  final Future<void> Function(DownloadTask task)? onShareDownload;
  final Future<void> Function(DownloadTask task)? onExport;

  const DownloadPropertiesDialog({
    required this.task,
    required this.onOpenDownload,
    this.onOpenUrlInBrowser,
    this.onTaskUpdated,
    this.onShareDownload,
    this.onExport,
  });

  @override
  State<DownloadPropertiesDialog> createState() => DownloadPropertiesDialogState();
}

class DownloadPropertiesDialogState extends State<DownloadPropertiesDialog> {
  late TextEditingController _nameController;
  late String _currentName;
  late String _dir;

  @override
  void initState() {
    super.initState();
    final normalizedPath = widget.task.savePath.replaceAll('\\', '/');
    final lastSlash = normalizedPath.lastIndexOf('/');
    _dir = lastSlash >= 0 ? widget.task.savePath.substring(0, lastSlash) : '';
    _currentName = lastSlash >= 0
        ? widget.task.savePath.substring(lastSlash + 1)
        : widget.task.savePath;
    _nameController = TextEditingController(text: _currentName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty || newName == _currentName) return;

    final separator = widget.task.savePath.contains('\\') ? '\\' : '/';
    final newPath = _dir.isEmpty ? newName : '$_dir$separator$newName';

    if (widget.task.state == DownloadState.completed) {
      try {
        if (widget.task.publicUri != null) {
          // Published file — rename via MediaStore on the public copy.
          final ok = await const PublicDownloadsService().renamePublishedFile(
            publicUri: widget.task.publicUri!,
            newDisplayName: newName,
          );
          if (!ok) throw Exception('MediaStore rename returned false');
        } else {
          // Not yet published — rename the internal file directly.
          final file = File(widget.task.savePath);
          if (await file.exists()) {
            await file.rename(newPath);
          }
        }
        if (!mounted) return;
        setState(() {
          widget.task.savePath = newPath;
          widget.task.publicPathLabel = newPath;
          _currentName = newName;
        });
        widget.onTaskUpdated?.call(widget.task);
        AuroraSnackbar.show(context, 'Done — File renamed.');
      } catch (e) {
        if (!mounted) return;
        AuroraSnackbar.show(context, "Couldn't rename. $e. Try a different name.");
      }
    } else {
      setState(() {
        widget.task.savePath = newPath;
        _currentName = newName;
      });
      widget.onTaskUpdated?.call(widget.task);
      AuroraSnackbar.show(context, 'Done — Save path renamed.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isCompleted = widget.task.state == DownloadState.completed;

    return AlertDialog(
      title: const Text('File details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'File name',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Save new name',
                  onPressed: _rename,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Location', style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              widget.task.publicPathLabel ?? widget.task.savePath,
              style: TextStyle(fontSize: 12, color: ac.textSecondary),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Download link', style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
                      const SizedBox(height: 4),
                      Text(
                        widget.task.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: ac.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy link',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.task.url));
                    AuroraSnackbar.show(context, 'Done — Link copied.');
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.task.sourcePageUrl != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Source page', style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(
                          widget.task.sourcePageUrl!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: ac.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy page link',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.task.sourcePageUrl!));
                      AuroraSnackbar.show(context, 'Done — Page link copied.');
                    },
                  ),
                  if (widget.onOpenUrlInBrowser != null)
                    IconButton(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      tooltip: 'Open in browser',
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onOpenUrlInBrowser!(widget.task.sourcePageUrl!);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            if (isCompleted) ...[
              const Divider(),
              const SizedBox(height: 8),
              Text('Actions', style: TextStyle(fontWeight: FontWeight.bold, color: ac.accentFrost, fontSize: 12)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Open'),
                    onPressed: widget.task.publicUri == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            widget.onOpenDownload(widget.task);
                          },
                  ),
                  if (widget.onShareDownload != null)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.share, size: 16),
                      label: const Text('Share'),
                      onPressed: widget.task.publicUri == null
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              widget.onShareDownload!(widget.task);
                            },
                    ),
                  if (widget.onExport != null)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.save_alt, size: 16),
                      label: const Text('Export'),
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onExport!(widget.task);
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
