import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../logging/aurora_log.dart';
import '../../logging/log_exporter.dart';
import '../../logging/log_settings_store.dart';
import '../../theme/aurora_colors.dart';
import '../notifications/aurora_snackbar.dart';

/// Full diagnostics viewer with filters, search, verbosity toggle, and
/// export to plain-text or JSON.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  LogVerbosity _verbosity = LogVerbosity.verbose;

  // Filter state
  final Set<LogLevel> _levelFilter = LogLevel.values.toSet();
  final Set<LogCategory> _categoryFilter = LogCategory.values.toSet();
  final Set<LogScreen> _screenFilter = LogScreen.values.toSet();
  final TextEditingController _searchController = TextEditingController();
  String _searchText = '';

  @override
  void initState() {
    super.initState();
    _verbosity = AuroraLog.instance.verbosity;
    _searchController.addListener(() {
      setState(() => _searchText = _searchController.text.toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // Filtered entries
  // -----------------------------------------------------------------------

  List<AuroraLogEntry> _filter(List<AuroraLogEntry> all) {
    return all.where((e) {
      if (!_levelFilter.contains(e.level)) return false;
      if (!_categoryFilter.contains(e.category)) return false;
      if (!_screenFilter.contains(e.screen)) return false;
      if (_searchText.isNotEmpty &&
          !e.message.toLowerCase().contains(_searchText)) {
        return false;
      }
      return true;
    }).toList();
  }

  // -----------------------------------------------------------------------
  // Actions
  // -----------------------------------------------------------------------

  Future<void> _setVerbosity(LogVerbosity v) async {
    setState(() => _verbosity = v);
    AuroraLog.instance.setVerbosity(v);
    try {
      final docs = await getApplicationSupportDirectory();
      await LogSettingsStore.instance.save(docs.path, v);
    } catch (_) {}
  }

  Future<void> _copyAll(List<AuroraLogEntry> entries) async {
    final text = LogExporter.toPlainText(entries);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      AuroraSnackbar.show(context, 'Logs copied to clipboard');
    }
  }

  Future<void> _export(List<AuroraLogEntry> entries) async {
    bool exportApp = true;
    bool exportBrowser = true;
    bool exportDownload = true;
    bool exportSystem = true;
    bool sanitize = false;
    LogExportFormat selectedFormat = LogExportFormat.plainText;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            // Count entries in each group
            final appCount = entries.where((e) =>
              e.category == LogCategory.app ||
              e.category == LogCategory.settings ||
              e.category == LogCategory.notification
            ).length;

            final browserCount = entries.where((e) =>
              e.category == LogCategory.browser ||
              e.category == LogCategory.sniffer ||
              e.category == LogCategory.adblock
            ).length;

            final downloadCount = entries.where((e) =>
              e.category == LogCategory.download ||
              e.category == LogCategory.hls ||
              e.category == LogCategory.torrent
            ).length;

            final systemCount = entries.where((e) =>
              e.category == LogCategory.native ||
              e.category == LogCategory.platform ||
              e.category == LogCategory.sync
            ).length;

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.file_upload_outlined,
                          color: AuroraColors.accent,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Export Logs',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AuroraColors.text,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'App & Settings',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: Text(
                        '$appCount entries (General, settings, notifications)',
                        style: const TextStyle(color: AuroraColors.mutedText, fontSize: 11),
                      ),
                      value: exportApp,
                      onChanged: (val) =>
                          setModalState(() => exportApp = val),
                    ),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'Browser & Sniffer',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: Text(
                        '$browserCount entries (WebView, sniffer, adblock)',
                        style: const TextStyle(color: AuroraColors.mutedText, fontSize: 11),
                      ),
                      value: exportBrowser,
                      onChanged: (val) =>
                          setModalState(() => exportBrowser = val),
                    ),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'Download Engine',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: Text(
                        '$downloadCount entries (HTTP splitter, HLS, torrent)',
                        style: const TextStyle(color: AuroraColors.mutedText, fontSize: 11),
                      ),
                      value: exportDownload,
                      onChanged: (val) =>
                          setModalState(() => exportDownload = val),
                    ),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'System & Sync',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: Text(
                        '$systemCount entries (Native C++, platform, Drive sync)',
                        style: const TextStyle(color: AuroraColors.mutedText, fontSize: 11),
                      ),
                      value: exportSystem,
                      onChanged: (val) =>
                          setModalState(() => exportSystem = val),
                    ),
                    const Divider(height: 24),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'Sanitize for sharing',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: const Text(
                        'Replaces URL paths with secure hashes to hide sensitive links',
                        style: TextStyle(color: AuroraColors.mutedText, fontSize: 11),
                      ),
                      value: sanitize,
                      onChanged: (val) =>
                          setModalState(() => sanitize = val),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Text(
                            'Format:',
                            style: TextStyle(
                              color: AuroraColors.text,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const Spacer(),
                          SegmentedButton<LogExportFormat>(
                            segments: const [
                              ButtonSegment(
                                value: LogExportFormat.plainText,
                                label: Text('Plain Text (.txt)', style: TextStyle(fontSize: 11)),
                              ),
                              ButtonSegment(
                                value: LogExportFormat.json,
                                label: Text('JSON (.json)', style: TextStyle(fontSize: 11)),
                              ),
                            ],
                            selected: {selectedFormat},
                            onSelectionChanged: (v) =>
                                setModalState(() => selectedFormat = v.first),
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: AuroraColors.mutedText),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          key: const Key('confirm_log_export_button'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AuroraColors.accent,
                            foregroundColor: AuroraColors.background,
                          ),
                          onPressed: (!exportApp &&
                                  !exportBrowser &&
                                  !exportDownload &&
                                  !exportSystem)
                              ? null
                              : () async {
                                  Navigator.pop(ctx);

                                  final toExport = entries.where((e) {
                                    if (e.category == LogCategory.app ||
                                        e.category == LogCategory.settings ||
                                        e.category == LogCategory.notification) {
                                      return exportApp;
                                    }
                                    if (e.category == LogCategory.browser ||
                                        e.category == LogCategory.sniffer ||
                                        e.category == LogCategory.adblock) {
                                      return exportBrowser;
                                    }
                                    if (e.category == LogCategory.download ||
                                        e.category == LogCategory.hls ||
                                        e.category == LogCategory.torrent) {
                                      return exportDownload;
                                    }
                                    if (e.category == LogCategory.native ||
                                        e.category == LogCategory.platform ||
                                        e.category == LogCategory.sync) {
                                      return exportSystem;
                                    }
                                    return true;
                                  }).toList();

                                  try {
                                    await LogExporter.exportAndShare(
                                      toExport,
                                      selectedFormat,
                                      sanitize: sanitize,
                                    );
                                  } catch (e) {
                                    if (mounted) {
                                      AuroraSnackbar.show(
                                        context,
                                        'Export failed: $e',
                                      );
                                    }
                                  }
                                },
                          child: const Text('Export'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _clear() {
    AuroraLog.instance.clear();
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  Color _levelColor(LogLevel level) {
    return switch (level) {
      LogLevel.debug => AuroraColors.mutedDeep,
      LogLevel.info => AuroraColors.accent,
      LogLevel.warn => Colors.orange,
      LogLevel.error => Colors.redAccent,
      LogLevel.fatal => Colors.deepPurpleAccent,
    };
  }

  IconData _levelIcon(LogLevel level) {
    return switch (level) {
      LogLevel.debug => Icons.bug_report_outlined,
      LogLevel.info => Icons.info_outline,
      LogLevel.warn => Icons.warning_amber_outlined,
      LogLevel.error => Icons.error_outline,
      LogLevel.fatal => Icons.report_outlined,
    };
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: Column(
        children: [
          _buildHeader(context),
          _buildSearchBar(context),
          _buildFilterChips(context),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<List<AuroraLogEntry>>(
              stream: AuroraLog.instance.onEntriesChanged,
              initialData: AuroraLog.instance.entries,
              builder: (context, snapshot) {
                final all = snapshot.data ?? [];
                final filtered = _filter(all);
                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.receipt_long_outlined,
                            size: 48, color: scheme.onSurfaceVariant.withAlpha(128)),
                        const SizedBox(height: 12),
                        Text(
                          all.isEmpty
                              ? 'No logs recorded yet'
                              : 'No logs match the current filters',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  );
                }
                return _buildLogList(filtered, scheme);
              },
            ),
          ),
          _buildBottomBar(context),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Header — verbosity toggle
  // -----------------------------------------------------------------------

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AuroraColors.surfaceVariant,
      child: Row(
        children: [
          Icon(Icons.monitor_heart_outlined,
              color: AuroraColors.accent, size: 20),
          const SizedBox(width: 8),
          Text(
            '${AuroraLog.instance.count} entries',
            style: TextStyle(
              color: AuroraColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          SegmentedButton<LogVerbosity>(
            segments: const [
              ButtonSegment(
                value: LogVerbosity.minimal,
                label: Text('Minimal', style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: LogVerbosity.verbose,
                label: Text('Verbose', style: TextStyle(fontSize: 11)),
              ),
            ],
            selected: {_verbosity},
            onSelectionChanged: (v) => _setVerbosity(v.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(
                const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Search bar
  // -----------------------------------------------------------------------

  Widget _buildSearchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search logs…',
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => _searchController.clear(),
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Filter chips
  // -----------------------------------------------------------------------

  Widget _buildFilterChips(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildChipRow(
            'Level:',
            LogLevel.values,
            (l) => l.label,
            _levelColor,
            _levelFilter,
            (l) => setState(() {
              if (_levelFilter.contains(l)) {
                if (_levelFilter.length > 1) _levelFilter.remove(l);
              } else {
                _levelFilter.add(l);
              }
            }),
          ),
          const SizedBox(height: 4),
          _buildChipRow(
            'Category:',
            LogCategory.values,
            (c) => c.label,
            (c) => AuroraColors.accentPurple,
            _categoryFilter,
            (c) => setState(() {
              if (_categoryFilter.contains(c)) {
                if (_categoryFilter.length > 1) _categoryFilter.remove(c);
              } else {
                _categoryFilter.add(c);
              }
            }),
          ),
          const SizedBox(height: 4),
          _buildChipRow(
            'Screen:',
            LogScreen.values,
            (s) => s.label,
            (s) => AuroraColors.accentAmber,
            _screenFilter,
            (s) => setState(() {
              if (_screenFilter.contains(s)) {
                if (_screenFilter.length > 1) _screenFilter.remove(s);
              } else {
                _screenFilter.add(s);
              }
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildChipRow<T extends Object>(
    String label,
    List<T> items,
    String Function(T) labelFor,
    Color Function(T) colorFor,
    Set<T> selected,
    void Function(T) onTap,
  ) {
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AuroraColors.mutedText)),
        ...items.map((item) {
          final active = selected.contains(item);
          return GestureDetector(
            onTap: () => onTap(item),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: active
                    ? colorFor(item).withAlpha(40)
                    : AuroraColors.surfaceCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      active ? colorFor(item) : AuroraColors.border,
                  width: 1,
                ),
              ),
              child: Text(
                labelFor(item),
                style: TextStyle(
                  fontSize: 10,
                  color: active ? colorFor(item) : AuroraColors.mutedDeep,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Log list
  // -----------------------------------------------------------------------

  Widget _buildLogList(List<AuroraLogEntry> entries, ColorScheme scheme) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final e = entries[index];
        final lc = _levelColor(e.level);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              // Show full detail on tap.
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: Row(
                    children: [
                      Icon(_levelIcon(e.level), color: lc, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(e.level.name.toUpperCase(),
                              style: TextStyle(color: lc, fontSize: 14))),
                    ],
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _detailRow('Time', e.formattedTime),
                        _detailRow('Category', e.category.name),
                        _detailRow('Screen', e.screen.name),
                        _detailRow('Type', e.eventType.name),
                        if (e.taskId != null) _detailRow('Task ID', e.taskId!),
                        const SizedBox(height: 8),
                        SelectableText(e.message),
                        if (e.stackTrace != null &&
                            e.stackTrace!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          const Text('Stack Trace:',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          SelectableText(e.stackTrace!,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AuroraColors.mutedDeep,
                                  fontFamily: 'monospace')),
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
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AuroraColors.surfaceCard,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AuroraColors.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_levelIcon(e.level), size: 14, color: lc),
                  const SizedBox(width: 6),
                  Text(
                    e.formattedTime.substring(11), // time portion only
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: AuroraColors.mutedDeep,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: lc.withAlpha(30),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      e.category.name,
                      style: TextStyle(fontSize: 9, color: lc),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: AuroraColors.accentPurple.withAlpha(25),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      e.screen.name,
                      style: TextStyle(
                          fontSize: 9, color: AuroraColors.accentPurple),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      e.message,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: e.level == LogLevel.error ||
                                e.level == LogLevel.fatal
                            ? Colors.redAccent
                            : AuroraColors.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AuroraColors.mutedText)),
          ),
          Expanded(
            child: SelectableText(value,
                style: TextStyle(fontSize: 11, color: AuroraColors.text)),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Bottom action bar
  // -----------------------------------------------------------------------

  Widget _buildBottomBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AuroraColors.surfaceVariant,
        border: Border(top: BorderSide(color: AuroraColors.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${_filter(AuroraLog.instance.entries).length} shown',
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
                onPressed: () =>
                    _copyAll(_filter(AuroraLog.instance.entries)),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                icon: const Icon(Icons.share, size: 16),
                label: const Text('Export', style: TextStyle(fontSize: 12)),
                onPressed: () =>
                    _export(_filter(AuroraLog.instance.entries)),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Clear', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.error,
                ),
                onPressed: () => _clear(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
