part of '../sniffer_screen.dart';

class _AddQueueDialogContent extends StatefulWidget {
  final SniffedMedia media;
  final List<SniffedMedia> variants;
  final BrowserTab tab;
  final String? currentUrl;
  final String suggestedName;
  final String? baseDir;
  final String? baseTemp;
  final Future<Map<String, String>> Function(String) getCookiesForUrl;
  final DownloadQueue downloadQueue;
  final Future<String> Function(String, Map<String, String>)
  refreshM3u8IfNeeded;
  final Future<String?> Function({bool forceReload})? onTokenExpired;
  final Future<List<SniffedMedia>> Function(String url)?
      fetchMasterPlaylistVariants;

  const _AddQueueDialogContent({
    required this.media,
    this.variants = const [],
    required this.tab,
    required this.currentUrl,
    required this.suggestedName,
    required this.baseDir,
    required this.baseTemp,
    required this.getCookiesForUrl,
    required this.downloadQueue,
    required this.refreshM3u8IfNeeded,
    this.onTokenExpired,
    this.fetchMasterPlaylistVariants,
  });

  @override
  _AddQueueDialogContentState createState() => _AddQueueDialogContentState();
}

class _AddQueueDialogContentState extends State<_AddQueueDialogContent> {
  late TextEditingController filenameController;
  DownloadPriority selectedPriority = DownloadPriority.medium;
  bool isResolving = false;
  String selectedFolder = '';
  late SniffedMedia selectedMedia;
  List<SniffedMedia> _variants = [];

  @override
  void initState() {
    super.initState();
    selectedMedia = widget.media;
    _variants = widget.variants;
    filenameController = TextEditingController(text: widget.suggestedName);
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

    setState(() => isResolving = true);
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
      if (mounted) setState(() => isResolving = false);
    }
  }

  Future<void> _showRenameDialog() async {
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => _RenameFileDialog(
        initialValue: filenameController.text,
        textFieldKey: const Key('dialog_filename_input'),
        okButtonKey: const Key('dialog_rename_ok_button'),
      ),
    );
    if (newName != null && mounted) {
      setState(() {
        filenameController.text = newName;
      });
    }
  }

  String _variantLabel(SniffedMedia m) {
    // Prefer the height field populated from the HLS RESOLUTION attribute.
    if (m.height != null) return '${m.height}p';
    // Fallback: look for a resolution marker in the URL or name.
    final res = RegExp(r'(?<!\d)(2160|1440|1080|720|540|480|360)p(?!\d)')
        .firstMatch('${m.name.toLowerCase()} ${m.url.toLowerCase()}')
        ?.group(1);
    if (res != null) return '${res}p';
    if (m.width != null && m.height != null) return '${m.width}x${m.height}';
    if (m.bandwidth != null) {
      return '${(m.bandwidth! / 1000000).toStringAsFixed(1)} Mbps';
    }
    return 'Default / Master';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add to Download Queue'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'From: ${selectedMedia.sourcePageUrl ?? widget.tab.addressController.text}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: AuroraColors.mutedText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Link: ${selectedMedia.url}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: AuroraColors.mutedText,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Filename',
                        style: TextStyle(
                          color: AuroraColors.mutedText,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        filenameController.text,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AuroraColors.text,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('dialog_rename_pencil_button'),
                  icon: const Icon(Icons.edit, color: AuroraColors.accent),
                  onPressed: isResolving ? null : _showRenameDialog,
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
              onChanged: isResolving
                  ? null
                  : (val) {
                      if (val != null) {
                        setState(() => selectedPriority = val);
                      }
                    },
            ),
            if (isResolving) ...[
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
                    'Refreshing media URL...',
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
          onPressed: isResolving
              ? null
              : () {
                  Navigator.of(context).pop();
                },
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const Key('dialog_add_button'),
          onPressed: isResolving
              ? null
              : () async {
                  final filename = filenameController.text.trim();
                  if (filename.isEmpty) return;
                  final navigator = Navigator.of(context);
                  final messenger = ScaffoldMessenger.of(context);

                  setState(() => isResolving = true);

                  try {
                    final baseDir = widget.baseDir ?? Directory.systemTemp.path;
                    final baseTemp =
                        widget.baseTemp ?? Directory.systemTemp.path;
                    final cookieHeaders = await widget.getCookiesForUrl(
                      selectedMedia.url,
                    );
                    final taskHeaders = _buildSniffedDownloadHeaders(
                      tab: widget.tab,
                      media: selectedMedia,
                      cookieHeaders: cookieHeaders,
                      currentUrl: widget.currentUrl,
                    );

                    final refreshedUrl = await widget.refreshM3u8IfNeeded(
                      selectedMedia.url,
                      taskHeaders,
                    );

                    final taskId = DateTime.now().millisecondsSinceEpoch
                        .toString();
                    final bool isCustomDirectory =
                        selectedFolder.startsWith('content://');
                    final saveDir = isCustomDirectory
                        ? '$baseDir${Platform.pathSeparator}completed'
                        : (selectedFolder.isNotEmpty
                            ? '$baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}$selectedFolder'
                            : '$baseDir${Platform.pathSeparator}completed');
                    final task = DownloadTask(
                      id: taskId,
                      url: refreshedUrl,
                      sourcePageUrl: selectedMedia.sourcePageUrl,
                      savePath: '$saveDir${Platform.pathSeparator}$filename',
                      tempDir: '$baseTemp${Platform.pathSeparator}temp_$taskId',
                      priority: selectedPriority,
                      contentType: selectedMedia.contentType,
                      headers: taskHeaders,
                      exportDirectoryUri: isCustomDirectory ? selectedFolder : null,
                      totalBytes: selectedMedia.contentLengthBytes ?? -1,
                    );
                    // Wire up the token-refresh hook so the HLS downloader
                    // can recover from 403 by re-sniffing the page URL.
                    if (widget.onTokenExpired != null) {
                      task.onTokenExpired = widget.onTokenExpired;
                    }
                    // Wire up the WebView JS fetch bridge so the HLS
                    // downloader can request playlists through the
                    // browser's networking stack (Cloudflare clearance
                    // cookies, raw UA, correct TLS fingerprint).
                    task.fetchViaWebView = (url, {headers}) =>
                        widget.tab.controller.fetchViaJavaScript(url, headers: headers);
                    // Wire up the HLS playlist body cache so the
                    // downloader can use browser-captured playlist
                    // bodies directly (zero network requests).
                    task.hlsPlaylistCache = (url) =>
                        widget.tab.hlsPlaylistCache[url];
                    task.fetchBinaryViaWebView = (url) =>
                        widget.tab.controller.fetchBinaryViaJavaScript(url);

                    bool force = false;
                    if (widget.downloadQueue.urlExists(refreshedUrl)) {
                      if (!context.mounted) return;
                      final skip = await showDialog<bool>(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            title: const Text('Duplicate Download'),
                            content: Text(
                              'The file "$filename" is already in your download queue/history.\n\n'
                              'Do you want to skip downloading it again?',
                            ),
                            actions: <Widget>[
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(false),
                                child: const Text('Download Anyway'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(true),
                                child: const Text('Skip'),
                              ),
                            ],
                          );
                        },
                      );
                      if (skip ?? true) {
                        if (mounted) {
                          setState(() => isResolving = false);
                        }
                        return;
                      }
                      force = true;
                    }

                    widget.downloadQueue.addTask(task, force: force);
                    AuroraLog.instance.info(
                      'Media added to queue: "$filename" (${task.contentType ?? "unknown type"}) from ${task.sourcePageUrl ?? "unknown"}',
                      category: LogCategory.sniffer,
                      screen: LogScreen.browser,
                      eventType: LogEventType.sniff,
                      taskId: task.id,
                    );

                    if (!mounted) return;
                    navigator.pop();
                    messenger.showSnackBar(
                      SnackBar(content: Text('Added "$filename" to queue.')),
                    );
                  } catch (e) {
                    if (mounted) {
                      setState(() => isResolving = false);
                    }
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          'Failed to add download: ${e.toString().length > 120 ? e.toString().substring(0, 120) : e.toString()}',
                        ),
                      ),
                    );
                  }
                },
          child: const Text('Download'),
        ),
      ],
    );
  }
}
