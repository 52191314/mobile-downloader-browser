import 'dart:io';

import 'package:flutter/material.dart';

import '../../compliance/restricted_media_policy.dart';
import '../../downloader/downloader.dart';
import '../../downloader/file_classifier.dart';
import '../../downloader/filename_service.dart';
import '../../theme/aurora_palette.dart';
import '../../ui/notifications/aurora_snackbar.dart';
import '../filename_utils.dart';
import '../hls_playlist_cache_lookup.dart';
import '../models/browser_tab.dart';
import '../models/sniffed_media.dart';
import '../sniffer_url_utils.dart';
import '../sheets/duplicate_download_dialog.dart';
import 'folder_selector.dart';
import 'rename_file_dialog.dart';

/// Full-featured "Add to Download Queue" dialog.
///
/// Shows the captured media URL, suggested filename, quality dropdown
/// (for HLS variants), folder picker, and priority.  The user can
/// rename the file, pick a folder, and confirm enqueue or cancel.
class AddQueueDialogContent extends StatefulWidget {
  final SniffedMedia media;
  final List<SniffedMedia> variants;
  final BrowserTab tab;
  final String? currentUrl;
  final String suggestedName;
  final String? baseDir;
  final String? baseTemp;
  final Future<Map<String, String>> Function(String) getCookiesForUrl;
  final DownloadQueue downloadQueue;
  final Future<String?> Function({bool forceReload})? onTokenExpired;
  final Future<List<SniffedMedia>> Function(String url)?
      fetchMasterPlaylistVariants;

  const AddQueueDialogContent({
    super.key,
    required this.media,
    this.variants = const [],
    required this.tab,
    required this.currentUrl,
    required this.suggestedName,
    required this.baseDir,
    required this.baseTemp,
    required this.getCookiesForUrl,
    required this.downloadQueue,
    this.onTokenExpired,
    this.fetchMasterPlaylistVariants,
  });

  @override
  AddQueueDialogContentState createState() => AddQueueDialogContentState();
}

class AddQueueDialogContentState extends State<AddQueueDialogContent> {
  late TextEditingController filenameController;
  DownloadPriority selectedPriority = DownloadPriority.medium;
  /// True while master-playlist variants are loading for the quality dropdown.
  bool isResolvingVariants = false;
  /// True while the Download button handler is running (cookies + enqueue).
  bool isSubmitting = false;
  String selectedFolder = '';
  late SniffedMedia selectedMedia;
  List<SniffedMedia> _variants = [];

  bool get _busy => isResolvingVariants || isSubmitting;

  @override
  void initState() {
    super.initState();
    selectedMedia = widget.media;
    _variants = widget.variants;
    var name = widget.suggestedName;
    if (FilenameService.utf8ByteLength(name) >
        FilenameService.defaultMaxFileNameBytes) {
      name = truncateFilename(
        name,
        maxLength: FilenameService.defaultMaxFileNameBytes,
      );
    }
    filenameController = TextEditingController(text: name);
    // Pre-populate the folder picker based on auto-classification.
    _autoSelectFolder();
    // Try to resolve missing HLS variants after the frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveVariants());
  }

  /// Sets [selectedFolder] to the auto-classified category folder for the
  /// suggested filename, so the user sees the destined folder in the dialog
  /// and can override it if desired.
  void _autoSelectFolder() {
    final category = FileClassifier.classify(widget.suggestedName);
    selectedFolder = FileClassifier.categoryLabel(category);
  }


  @override
  void dispose() {
    filenameController.dispose();
    super.dispose();
  }

  /// Collects all .m3u8 URLs from [widget.media] and [_variants], then tries
  /// each one (preferring URLs that look like master playlists — no resolution
  /// marker in the path) to populate the quality dropdown with all variant
  /// streams. Removes the bare master-playlist entry once real variants arrive.
  Future<void> _resolveVariants() async {
    if (widget.fetchMasterPlaylistVariants == null) return;
    // Collect all candidate .m3u8 URLs
    final all = [..._variants, widget.media];
    final m3u8Urls = all
        .map((m) => m.url)
        .where((u) => u.toLowerCase().endsWith('.m3u8'))
        .toSet()
        .toList();
    if (m3u8Urls.isEmpty) return;

    // Sort: URLs without a resolution marker (master-playlist) first.
    final resRe = RegExp(
      r'(?<!\d)(2160|1440|1080|720|540|480|360)p(?!\d)',
      caseSensitive: false,
    );
    m3u8Urls.sort((a, b) {
      final aIsVariant = resRe.hasMatch(a.toLowerCase()) ? 1 : 0;
      final bIsVariant = resRe.hasMatch(b.toLowerCase()) ? 1 : 0;
      return aIsVariant.compareTo(bIsVariant); // 0 (master) sorts first
    });

    setState(() => isResolvingVariants = true);
    try {
      List<SniffedMedia> fetched = const [];
      for (final url in m3u8Urls) {
        fetched = await widget.fetchMasterPlaylistVariants!(url);
        if (fetched.isNotEmpty) break;
      }
      if (!mounted || fetched.isEmpty) return;

      final existingUrls = _variants.map((v) => v.url).toSet();
      final newVariants =
          fetched.where((v) => !existingUrls.contains(v.url)).toList();
      if (newVariants.isEmpty) return;

      setState(() {
        // Remove the bare master-playlist entry now that real variants exist.
        // Keep it only if the master URL itself carries resolution info.
        _variants.removeWhere((v) {
          final label = '${v.name.toLowerCase()} ${v.url.toLowerCase()}';
          return !resRe.hasMatch(label) &&
              (v.width == null || v.height == null) &&
              (v.bandwidth == null);
        });
        _variants.addAll(newVariants);
        // Preserve the user's current selection by resolution (height) when
        // possible, rather than resetting to highest-bandwidth.  The async
        // re-fetch creates new SniffedMedia objects, so object-identity and
        // URL-string matching both break when the server returns different
        // variant URLs.  Matching by height keeps 480p selected as 480p.
        if (selectedMedia.url == widget.media.url ||
            !_variants.any((v) => v.url == selectedMedia.url)) {
          final preferredHeight = selectedMedia.height;
          SniffedMedia? match;
          if (preferredHeight != null) {
            match = _variants.where((v) => v.height == preferredHeight).firstOrNull;
          }
          // Also try matching by bandwidth if height is not available.
          match ??= _variants
              .where((v) => v.bandwidth == selectedMedia.bandwidth)
              .firstOrNull;
          if (match != null) {
            selectedMedia = match;
          } else {
            newVariants.sort(
              (a, b) => (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0),
            );
            if (newVariants.isNotEmpty) selectedMedia = newVariants.first;
          }
        }
      });
    } finally {
      if (mounted) setState(() => isResolvingVariants = false);
    }
  }

  Future<void> _showRenameDialog() async {
    final originalName = filenameController.text;
    String ext = '';
    final dotIndex = originalName.lastIndexOf('.');
    if (dotIndex != -1 && dotIndex > originalName.length - 10) {
      ext = originalName.substring(dotIndex);
    }

    final newName = await showRenameFileDialog(
      context,
      initialValue: filenameController.text,
      textFieldKey: const Key('dialog_filename_input'),
      okButtonKey: const Key('dialog_rename_ok_button'),
    );

    if (newName != null && mounted) {
      var finalName = newName;
      if (ext.isNotEmpty && !newName.toLowerCase().endsWith(ext.toLowerCase())) {
        finalName = '$newName$ext';
      }
      if (FilenameService.utf8ByteLength(finalName) >
          FilenameService.defaultMaxFileNameBytes) {
        finalName = truncateFilename(
          finalName,
          maxLength: FilenameService.defaultMaxFileNameBytes,
        );
      }
      setState(() {
        filenameController.text = finalName;
        _autoSelectFolder();
      });
    }
  }

  /// Date + time pickers for "Download later". Returns null if cancelled.
  Future<DateTime?> _pickScheduleStartAt() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
    );
    if (picked == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return null;
    return DateTime(
      picked.year,
      picked.month,
      picked.day,
      time.hour,
      time.minute,
    );
  }

  /// Builds the task and either starts now or schedules for [startAt].
  Future<void> _submit({DateTime? startAt}) async {
    var filename = filenameController.text.trim();
    if (filename.isEmpty) return;
    if (FilenameService.utf8ByteLength(filename) >
        FilenameService.defaultMaxFileNameBytes) {
      filename = FilenameService.truncate(
        filename,
        maxBytes: FilenameService.defaultMaxFileNameBytes,
      );
    }
    final navigator = Navigator.of(context);
    final scheduleLater = startAt != null;

    setState(() => isSubmitting = true);

    try {
      final mediaUrl = selectedMedia.url;
      if (RestrictedMediaPolicy.isBlocked(
        mediaUrl: mediaUrl,
        sourcePageUrl: widget.currentUrl ??
            widget.tab.currentUrl ??
            selectedMedia.sourcePageUrl,
      )) {
        if (mounted) {
          setState(() => isSubmitting = false);
          AuroraSnackbar.show(
            context,
            RestrictedMediaPolicy.userMessageRestricted,
          );
        }
        return;
      }

      final baseDir = widget.baseDir ?? Directory.systemTemp.path;
      final baseTemp = widget.baseTemp ?? Directory.systemTemp.path;
      final cookieHeaders = await widget.getCookiesForUrl(selectedMedia.url);
      final taskHeaders = buildSniffedDownloadHeaders(
        tab: widget.tab,
        media: selectedMedia,
        cookieHeaders: cookieHeaders,
        currentUrl: widget.currentUrl,
      );

      // Use the sniffer/quality-picker URL as-is. No pre-flight playlist
      // refresh — that only delayed the queue and often 403'd on Cloudflare
      // while the selected URL was already fine.

      final taskId = DateTime.now().millisecondsSinceEpoch.toString();
      final saveDir = selectedFolder.isNotEmpty
          ? '$baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}$selectedFolder'
          : '$baseDir${Platform.pathSeparator}completed';
      final savePath = FilenameService.uniquePath(
        '$saveDir${Platform.pathSeparator}$filename',
        reservedPaths: widget.downloadQueue.allTasks.map((t) => t.savePath),
      );
      final task = DownloadTask(
        id: taskId,
        url: mediaUrl,
        sourcePageUrl: selectedMedia.sourcePageUrl,
        savePath: savePath,
        tempDir: '$baseTemp${Platform.pathSeparator}temp_$taskId',
        priority: selectedPriority,
        contentType: selectedMedia.contentType,
        headers: taskHeaders,
        totalBytes: selectedMedia.contentLengthBytes ?? -1,
      );
      // Wire up the token-refresh hook so the HLS downloader can recover
      // from 403 by re-sniffing the page URL.
      if (widget.onTokenExpired != null) {
        task.onTokenExpired = widget.onTokenExpired;
      }
      // Wire up the WebView JS fetch bridge so the HLS downloader can
      // request playlists through the browser's networking stack.
      task.fetchViaWebView = (url, {headers}) =>
          widget.tab.controller.fetchPlaylistBodyViaJavaScript(url);
      // Wire up the HLS playlist body cache so the downloader can use
      // browser-captured playlist bodies directly.
      task.hlsPlaylistCache = (url) =>
          lookupHlsPlaylistCache(widget.tab.hlsPlaylistCache, url);
      task.fetchBinaryViaWebView =
          (url) => widget.tab.controller.fetchBinaryViaJavaScript(url);
      task.cookieProvider =
          (url) => widget.tab.controller.getCookiesForDomain(url: url);

      bool force = false;
      final hasDuplicate = widget.downloadQueue.urlExists(mediaUrl) ||
          widget.downloadQueue.samePageFilenameExists(
            filename,
            selectedMedia.sourcePageUrl,
          );
      if (hasDuplicate) {
        if (!mounted) return;
        // Shared duplicate prompt (same widget as enqueue_download's) so the
        // copy and the DuplicateChoice mapping stay consistent.
        final choice =
            await showDuplicateDownloadDialog(context: context, filename: filename);
        if (choice == DuplicateChoice.skip) {
          if (mounted) {
            setState(() => isSubmitting = false);
          }
          return;
        }
        if (choice == DuplicateChoice.updateExisting) {
          final existingId = widget.downloadQueue.resniffPendingTaskId ??
              widget.downloadQueue.getTaskByUrl(mediaUrl)?.id ??
              widget.downloadQueue.getTaskByUrl(selectedMedia.url)?.id;
          if (existingId != null) {
            await widget.downloadQueue.updateTaskFromDonor(existingId, task);
            if (!mounted) return;
            navigator.pop(true);
            AuroraSnackbar.show(
              context,
              'Done — Link updated. Download will retry.',
            );
            return;
          }
        }
        force = true;
      }

      if (scheduleLater) {
        // scheduleTask owns persistence + scheduled state; ignore force —
        // a new id always creates a distinct scheduled entry.
        widget.downloadQueue.scheduleTask(task, startAt);
        debugPrint('Media scheduled: "$filename" for $startAt (${task.contentType ?? "unknown type"}) from ${task.sourcePageUrl ?? "unknown"}');
        if (!mounted) return;
        navigator.pop(true);
        final hh = startAt.hour.toString().padLeft(2, '0');
        final mm = startAt.minute.toString().padLeft(2, '0');
        AuroraSnackbar.show(
          context,
          'Scheduled "$filename" for ${startAt.month}/${startAt.day} $hh:$mm.',
        );
      } else {
        widget.downloadQueue.addTask(task, force: force);
        debugPrint('Media added to queue: "$filename" (${task.contentType ?? "unknown type"}) from ${task.sourcePageUrl ?? "unknown"}');
        if (!mounted) return;
        navigator.pop(true);
        AuroraSnackbar.show(context, 'Added "$filename" to queue.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => isSubmitting = false);
        AuroraSnackbar.show(
          context,
          'Failed to add download: ${e.toString().length > 120 ? e.toString().substring(0, 120) : e.toString()}',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // While submitting, block barrier taps AND system back so the route
    // can't be dismissed under the async submit (a late navigator.pop(true)
    // would then pop the wrong route). Dismissal is still allowed when idle.
    return PopScope(
      canPop: !isSubmitting,
      child: AlertDialog(
      title: const Text('Add to Download Queue'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'From: ${selectedMedia.sourcePageUrl ?? widget.tab.addressController.text}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: context.ac.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Link: ${selectedMedia.url}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: context.ac.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Filename',
                        style: TextStyle(
                          color: context.ac.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        filenameController.text,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: context.ac.textPrimary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (FilenameService.utf8ByteLength(widget.suggestedName) >
                              FilenameService.defaultMaxFileNameBytes ||
                          FilenameService.utf8ByteLength(
                                filenameController.text,
                              ) >=
                              FilenameService.defaultMaxFileNameBytes) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Filename is long and was auto-truncated to fit Android\'s ${FilenameService.defaultMaxFileNameBytes}-byte file-name limit. You can rename it, or keep this name.',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('dialog_rename_pencil_button'),
                  icon: Icon(Icons.edit, color: context.ac.accentFrost),
                  onPressed: _busy ? null : _showRenameDialog,
                ),
              ],
            ),
            const SizedBox(height: 14),
            FolderSelector(
              baseDir: widget.baseDir,
              onChanged: (val) {
                setState(() {
                  selectedFolder = val ?? '';
                });
              },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<DownloadPriority>(
              key: const Key('dialog_priority_dropdown'),
              value: selectedPriority,
              decoration: const InputDecoration(
                labelText: 'Priority',
                border: OutlineInputBorder(),
              ),
              items: DownloadPriority.values.map((priority) {
                return DropdownMenuItem<DownloadPriority>(
                  value: priority,
                  child: Text(priority.name.toUpperCase()),
                );
              }).toList(),
              onChanged: _busy
                  ? null
                  : (val) {
                      if (val != null) {
                        setState(() => selectedPriority = val);
                      }
                    },
            ),
            // Only show spinner while loading quality options — not on Download.
            // Pre-download m3u8 "refresh" was removed: the selected quality URL
            // is already the right media playlist; mid-download onTokenExpired
            // handles real 403 recovery.
            if (isResolvingVariants) ...[
              const SizedBox(height: 16),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Loading quality options...',
                    style: TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('dialog_cancel_button'),
          onPressed: isSubmitting
              ? null
              : () {
                  Navigator.of(context).pop(false);
                },
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('dialog_download_later_button'),
          onPressed: isSubmitting
              ? null
              : () async {
                  final startAt = await _pickScheduleStartAt();
                  if (startAt == null || !mounted) return;
                  await _submit(startAt: startAt);
                },
          child: const Text('Download later'),
        ),
        ElevatedButton(
          key: const Key('dialog_add_button'),
          onPressed: isSubmitting ? null : () => _submit(),
          child: isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Download'),
        ),
      ],
      ),
    );
  }
}

/// Convenience wrapper that shows [AddQueueDialogContent] in a dialog and
/// returns `true` when the user confirmed enqueue, `false` otherwise.
Future<bool> showAddQueueDialog(
  BuildContext context, {
  required SniffedMedia media,
  List<SniffedMedia> variants = const [],
  required BrowserTab tab,
  required String? currentUrl,
  required String suggestedName,
  required String? baseDir,
  required String? baseTemp,
  required Future<Map<String, String>> Function(String) getCookiesForUrl,
  required DownloadQueue downloadQueue,
  Future<String?> Function({bool forceReload})? onTokenExpired,
  Future<List<SniffedMedia>> Function(String url)? fetchMasterPlaylistVariants,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AddQueueDialogContent(
        media: media,
        variants: variants,
        tab: tab,
        currentUrl: currentUrl,
        suggestedName: suggestedName,
        baseDir: baseDir,
        baseTemp: baseTemp,
        getCookiesForUrl: getCookiesForUrl,
        downloadQueue: downloadQueue,
        onTokenExpired: onTokenExpired,
        fetchMasterPlaylistVariants: fetchMasterPlaylistVariants,
      );
    },
  );
  return result ?? false;
}
