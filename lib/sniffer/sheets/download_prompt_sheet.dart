import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../sniffer_formatters.dart';

enum DownloadPromptAction {
  download,
  downloadAndOpen,
  cancel,
}

class DownloadPromptResult {
  final DownloadPromptAction action;
  final bool rememberType;
  final bool rememberHost;

  const DownloadPromptResult({
    required this.action,
    this.rememberType = false,
    this.rememberHost = false,
  });
}

/// Category metadata for direct download items.
class _FileCategoryInfo {
  final String categoryName;
  final IconData icon;
  final Color color;
  final bool isMedia;

  const _FileCategoryInfo({
    required this.categoryName,
    required this.icon,
    required this.color,
    required this.isMedia,
  });
}

_FileCategoryInfo _detectCategory(String filename, String? contentType) {
  final ext = filename.contains('.')
      ? filename.split('.').last.toLowerCase().trim()
      : '';
  final mime = (contentType ?? '').toLowerCase().trim();

  // Installers / Apps
  if (['apk', 'exe', 'msi', 'dmg', 'ipa', 'deb', 'rpm'].contains(ext) ||
      mime.contains('android.package-archive') ||
      mime.contains('octet-stream')) {
    return const _FileCategoryInfo(
      categoryName: 'Installer',
      icon: Icons.android_rounded,
      color: Colors.greenAccent,
      isMedia: false,
    );
  }

  // Archives
  if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso'].contains(ext) ||
      mime.contains('zip') ||
      mime.contains('compressed') ||
      mime.contains('tar') ||
      mime.contains('archive')) {
    return const _FileCategoryInfo(
      categoryName: 'Archive',
      icon: Icons.inventory_2_rounded,
      color: Colors.amberAccent,
      isMedia: false,
    );
  }

  // Documents
  if (['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'epub', 'mobi', 'csv'].contains(ext) ||
      mime.contains('pdf') ||
      mime.contains('document') ||
      mime.contains('text/')) {
    return const _FileCategoryInfo(
      categoryName: 'Document',
      icon: Icons.description_rounded,
      color: Colors.lightBlueAccent,
      isMedia: false,
    );
  }

  // Video
  if (['mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'ts', 'm3u8'].contains(ext) ||
      mime.contains('video')) {
    return const _FileCategoryInfo(
      categoryName: 'Video',
      icon: Icons.movie_rounded,
      color: Colors.purpleAccent,
      isMedia: true,
    );
  }

  // Audio
  if (['mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus'].contains(ext) ||
      mime.contains('audio')) {
    return const _FileCategoryInfo(
      categoryName: 'Audio',
      icon: Icons.audiotrack_rounded,
      color: Colors.pinkAccent,
      isMedia: true,
    );
  }

  // Fallback
  return const _FileCategoryInfo(
    categoryName: 'File',
    icon: Icons.download_rounded,
    color: Colors.cyanAccent,
    isMedia: false,
  );
}

Future<DownloadPromptResult?> showDownloadPromptSheet({
  required BuildContext context,
  required String url,
  required String suggestedFilename,
  int? contentLengthBytes,
  String? contentType,
  String? sourceHost,
}) {
  return showModalBottomSheet<DownloadPromptResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _DownloadPromptSheetContent(
      url: url,
      suggestedFilename: suggestedFilename,
      contentLengthBytes: contentLengthBytes,
      contentType: contentType,
      sourceHost: sourceHost,
    ),
  );
}

class _DownloadPromptSheetContent extends StatefulWidget {
  final String url;
  final String suggestedFilename;
  final int? contentLengthBytes;
  final String? contentType;
  final String? sourceHost;

  const _DownloadPromptSheetContent({
    required this.url,
    required this.suggestedFilename,
    this.contentLengthBytes,
    this.contentType,
    this.sourceHost,
  });

  @override
  State<_DownloadPromptSheetContent> createState() =>
      __DownloadPromptSheetContentState();
}

class __DownloadPromptSheetContentState
    extends State<_DownloadPromptSheetContent> {
  bool _openAfterDownload = false;
  bool _rememberType = false;
  bool _rememberHost = false;

  @override
  Widget build(BuildContext context) {
    final catInfo = _detectCategory(widget.suggestedFilename, widget.contentType);
    final ext = widget.suggestedFilename.contains('.')
        ? widget.suggestedFilename.split('.').last.toLowerCase().trim()
        : 'file';
    final host = widget.sourceHost ?? Uri.tryParse(widget.url)?.host ?? '';

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header with category icon badge
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: catInfo.color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(catInfo.icon, color: catInfo.color, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Download this file?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      catInfo.categoryName,
                      style: TextStyle(
                        color: catInfo.color,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // File Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.suggestedFilename,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (widget.contentLengthBytes != null &&
                        widget.contentLengthBytes! > 0) ...[
                      Icon(Icons.sd_card_rounded,
                          size: 14, color: Colors.grey[400]),
                      const SizedBox(width: 4),
                      Text(
                        formatByteSize(widget.contentLengthBytes!),
                        style: TextStyle(
                          color: Colors.grey[300],
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (host.isNotEmpty) ...[
                      Icon(Icons.public, size: 14, color: Colors.grey[400]),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          host,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Option: Open after completion (ONLY for non-media: docs/apks/archives)
          if (!catInfo.isMedia) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _openAfterDownload,
              activeColor: Colors.blueAccent,
              title: const Text(
                'Open file after download completes',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              onChanged: (val) {
                setState(() => _openAfterDownload = val ?? false);
              },
            ),
          ],

          // Option: Remember for file type (e.g. .apk, .zip)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _rememberType,
            activeColor: Colors.blueAccent,
            title: Text(
              'Always download .$ext files automatically',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            onChanged: (val) {
              setState(() => _rememberType = val ?? false);
            },
          ),

          // Option: Remember for site host
          if (host.isNotEmpty) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _rememberHost,
              activeColor: Colors.blueAccent,
              title: Text(
                'Remember my choice for $host',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              onChanged: (val) {
                setState(() => _rememberHost = val ?? false);
              },
            ),
          ],

          const SizedBox(height: 16),

          // Buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(
                      context,
                      DownloadPromptResult(
                        action: DownloadPromptAction.cancel,
                        rememberType: _rememberType,
                        rememberHost: _rememberHost,
                      ),
                    );
                  },
                  child: Text(AppLocalizations.of(context)!.btnNotNow),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: Icon(
                    _openAfterDownload
                        ? Icons.file_open_rounded
                        : Icons.download_rounded,
                  ),
                  label: Text(
                    _openAfterDownload ? 'Download & Open' : 'Download',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () {
                    Navigator.pop(
                      context,
                      DownloadPromptResult(
                        action: _openAfterDownload
                            ? DownloadPromptAction.downloadAndOpen
                            : DownloadPromptAction.download,
                        rememberType: _rememberType,
                        rememberHost: _rememberHost,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
