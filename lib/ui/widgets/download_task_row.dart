import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../downloader/downloader.dart';
import 'panel.dart';

class DownloadTaskRow extends StatelessWidget {
  final DownloadTask task;
  final Future<void> Function(DownloadTask task) onOpenDownload;
  final Future<void> Function(DownloadTask task) onShareDownload;
  final Future<void> Function(DownloadTask task)? onExport;
  final VoidCallback? onRetry;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final VoidCallback? onForceMerge;

  const DownloadTaskRow({
    super.key,
    required this.task,
    required this.onOpenDownload,
    required this.onShareDownload,
    this.onExport,
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
        onShareDownload: onShareDownload,
        onExport: onExport,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
                    child: Text(
                      _taskName(task),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    tooltip: 'Properties',
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
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '•  ${_formatBytes(task.downloadedBytes)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
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
                  child: Text(
                    _taskName(task),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
                if (onForceMerge != null && task.state == DownloadState.failed)
                  IconButton(
                    key: Key('force_merge_${task.id}'),
                    icon: const Icon(Icons.merge_type, size: 20),
                    tooltip: 'Force merge partial chunks',
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
                  tooltip: 'Properties',
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
                              title: Text(isCompleted ? 'Remove Download?' : 'Cancel Download?'),
                              content: Text(
                                isCompleted
                                    ? 'Are you sure you want to remove "${_taskName(task)}" from the download list?'
                                    : 'Are you sure you want to cancel and remove "${_taskName(task)}" from your queue?\nThis will delete any temporary or downloaded files.',
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
                    _bytesLabel(task.downloadedBytes, task.totalBytes),
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  Text(
                    task.state == DownloadState.downloading
                        ? _speedLabel(task.speed)
                        : _stateLabel(task.state),
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: isIndeterminate ? null : progress,
                  minHeight: 6,
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
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      task.errorMessage!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
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

  static String _taskName(DownloadTask task) {
    final uri = Uri.tryParse(task.url);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return Uri.decodeComponent(uri.pathSegments.last);
    }
    return task.url;
  }
}

class DownloadPropertiesDialog extends StatefulWidget {
  final DownloadTask task;
  final Future<void> Function(DownloadTask task) onOpenDownload;
  final Future<void> Function(DownloadTask task) onShareDownload;
  final Future<void> Function(DownloadTask task)? onExport;

  const DownloadPropertiesDialog({
    required this.task,
    required this.onOpenDownload,
    required this.onShareDownload,
    required this.onExport,
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
        final file = File(widget.task.savePath);
        if (await file.exists()) {
          await file.rename(newPath);
        }
        if (!mounted) return;
        setState(() {
          widget.task.savePath = newPath;
          widget.task.publicPathLabel = newPath;
          _currentName = newName;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File renamed successfully')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $e')),
        );
      }
    } else {
      setState(() {
        widget.task.savePath = newPath;
        _currentName = newName;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Download target path renamed')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCompleted = widget.task.state == DownloadState.completed;

    return AlertDialog(
      title: const Text('Download Properties'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Filename',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Rename',
                  onPressed: _rename,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Location', style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              widget.task.publicPathLabel ?? widget.task.savePath,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Download URL', style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary, fontSize: 12)),
                      const SizedBox(height: 4),
                      Text(
                        widget.task.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy URL',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.task.url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URL copied to clipboard')),
                    );
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
                        Text('Source Page', style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(
                          widget.task.sourcePageUrl!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy Source Page',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.task.sourcePageUrl!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Source page URL copied')),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            if (isCompleted) ...[
              const Divider(),
              const SizedBox(height: 8),
              Text('Actions', style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary, fontSize: 12)),
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
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.share, size: 16),
                    label: const Text('Share'),
                    onPressed: widget.task.publicUri == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            widget.onShareDownload(widget.task);
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

String _stateLabel(DownloadState state) {
  return switch (state) {
    DownloadState.completed => 'Completed',
    DownloadState.failed => 'Failed',
    DownloadState.paused => 'Paused',
    DownloadState.downloading => 'Downloading',
    DownloadState.idle => 'Waiting',
  };
}

String _bytesLabel(int downloaded, int total) {
  if (total <= 0) return '${_formatBytes(downloaded)} downloaded';
  return '${_formatBytes(downloaded)} / ${_formatBytes(total)}';
}

String _speedLabel(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 KB/s';
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
