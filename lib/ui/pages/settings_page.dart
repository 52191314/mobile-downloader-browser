import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../downloader/downloader.dart';
import '../../platform/public_downloads_service.dart';
import '../../sniffer/browser_library.dart';
import '../../sniffer/idm_backup_parser.dart';

import '../../settings/download_settings.dart';
import '../../sniffer/media_sniffer_engine.dart';
import '../../sniffer/models/sniffed_media.dart';
import '../../sync/sync.dart';
import '../../theme/aurora_colors.dart';
import '../widgets/media_type_chip.dart';
import '../widgets/panel.dart';

class SettingsPage extends StatefulWidget {
  final DriveSyncService driveSyncService;
  final TextEditingController folderController;
  final TextEditingController adblockSourceController;
  final TextEditingController customSearchController;
  final DownloadSettings settings;
  final ValueChanged<DownloadSettings> onSettingsChanged;
  final double speedLimitKbps;
  final ValueChanged<double> onSpeedLimitChanged;
  final DownloadQueue downloadQueue;
  final ValueNotifier<int> libraryUpdateNotifier;

  const SettingsPage({
    super.key,
    required this.driveSyncService,
    required this.folderController,
    required this.adblockSourceController,
    required this.customSearchController,
    required this.settings,
    required this.onSettingsChanged,
    required this.speedLimitKbps,
    required this.onSpeedLimitChanged,
    required this.downloadQueue,
    required this.libraryUpdateNotifier,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late DownloadSettings _settings;
  late double _speedLimitKbps;

  StreamSubscription<DriveSyncState>? _driveSubscription;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _speedLimitKbps = widget.speedLimitKbps;
    _subscribeDriveSync();
  }

  void _subscribeDriveSync() {
    _driveSubscription?.cancel();
    _driveSubscription = widget.driveSyncService.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) _settings = widget.settings;
    if (oldWidget.speedLimitKbps != widget.speedLimitKbps) {
      _speedLimitKbps = widget.speedLimitKbps;
    }
  }

  @override
  void dispose() {
    _driveSubscription?.cancel();
    super.dispose();
  }

  bool get _driveConnected =>
      widget.driveSyncService.state.status == DriveConnectionStatus.connected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildProfileHeader(),
            const SizedBox(height: 20),
            _buildSectionTitle('Downloads'),
            const SizedBox(height: 8),
            _buildCardGrid(),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Profile header
  // ---------------------------------------------------------------------------

  Widget _buildProfileHeader() {
    final state = widget.driveSyncService.state;
    final connected = _driveConnected;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AuroraColors.glassSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AuroraColors.glassBorder),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor:
                connected ? AuroraColors.nordGreen : AuroraColors.mutedDeep,
            radius: 24,
            child: Icon(
              connected ? Icons.cloud_done : Icons.cloud_outlined,
              color: AuroraColors.background,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Aurora Downloader',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AuroraColors.text)),
                const SizedBox(height: 2),
                Text(
                  connected
                      ? 'Drive: ${state.account ?? "Connected"}'
                      : 'Drive not linked',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          connected ? AuroraColors.accent : AuroraColors.mutedText),
                ),
              ],
            ),
          ),
          TextButton.icon(
            icon: Icon(connected ? Icons.sync : Icons.link, size: 16),
            label: Text(connected ? 'Sync' : 'Link'),
            onPressed: () {
              if (connected) {
                widget.driveSyncService.disconnect();
              } else {
                widget.driveSyncService.connect();
              }
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section title
  // ---------------------------------------------------------------------------

  Widget _buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AuroraColors.mutedText,
              letterSpacing: 0.5)),
    );
  }

  // ---------------------------------------------------------------------------
  // Dashboard card grid
  // ---------------------------------------------------------------------------

  Widget _buildCardGrid() {
    final state = widget.driveSyncService.state;
    return Column(
      children: [
        Row(children: [
          Expanded(child: _buildCard(Icons.download_rounded, 'Defaults',
              'Path, threads, retry', () => _openPage(_buildDefaultsPage()))),
          const SizedBox(width: 12),
          Expanded(child: _buildCard(
              Icons.speed_rounded, 'Speed',
              _speedLimitKbps == 0 ? 'Unlimited' : '${_speedLimitKbps.round()} KB/s',
              () => _openPage(_buildSpeedPage()))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _buildCard(Icons.shield_rounded, 'Adblock',
              '${_settings.manualAdBlockRules.length} rules',
              () => _openPage(_buildAdblockPage()))),
          const SizedBox(width: 12),
          Expanded(child: _buildCard(Icons.search_rounded, 'Search',
              _settings.searchEngine.name,
              () => _openPage(_buildSearchPage()))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _buildCard(Icons.tune_rounded, 'Sniffer',
              'Media detection', () => _openPage(_buildSnifferPage()))),
          const SizedBox(width: 12),
          Expanded(child: _buildCard(Icons.cloud_rounded, 'Drive Sync',
              state.autoSyncEnabled ? 'Auto: on' : 'Auto: off',
              () => _openPage(_buildDrivePage()))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _buildCard(Icons.palette_outlined, 'Appearance',
              'OLED mode, theme', () => _openPage(_buildAppearancePage()))),
          const SizedBox(width: 12),
          Expanded(child: _buildCard(Icons.wifi_rounded, 'Network',
              'Proxy, user-agent', () => _openPage(_buildNetworkPage()))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _buildCard(
              Icons.info_outline, 'About', 'v1.1.9', () => _openPage(_buildAboutPage()))),
          const SizedBox(width: 12),
          Expanded(child: _buildCard(
              Icons.backup_rounded, 'Backup', 'Import & export data', () => _openPage(_buildBackupPage()))),
        ]),
      ],
    );
  }

  Widget _buildCard(
      IconData icon, String title, String subtitle, VoidCallback onTap) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: AuroraColors.accent, size: 28),
            const SizedBox(height: 10),
            Text(title,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AuroraColors.text)),
            const SizedBox(height: 2),
            Text(subtitle,
                style:
                    TextStyle(fontSize: 11, color: AuroraColors.mutedDeep)),
          ]),
        ),
      ),
    );
  }

  void _openPage(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  // ---------------------------------------------------------------------------
  // Detail pages
  // ---------------------------------------------------------------------------

  Widget _buildDefaultsPage() {
    var local = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Download Defaults')),
      body: StatefulBuilder(
        builder: (context, setLocal) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PanelHeader(
                icon: Icons.download_rounded, title: 'Download Defaults'),
            const SizedBox(height: 8),
            Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _label('Destination'),
              Text(
                local.downloadDestination.isNotEmpty
                    ? local.downloadDestination
                    : 'App support directory',
                style:
                    TextStyle(fontSize: 13, color: AuroraColors.mutedText, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),
              _label('Max concurrent'),
              _slider(local.maxConcurrentDownloads.toDouble(), 1, 8, 7,
                  '${local.maxConcurrentDownloads}',
                  (v) {
                    setLocal(() => local = local.copyWith(maxConcurrentDownloads: v.round()));
                    _update(local);
                  }),
              const SizedBox(height: 16),
              _label('Chunks per task'),
              _slider(local.chunksPerTask.toDouble(), 1, 12, 11,
                  '${local.chunksPerTask}',
                  (v) {
                    setLocal(() => local = local.copyWith(chunksPerTask: v.round()));
                    _update(local);
                  }),
              const SizedBox(height: 16),
              SwitchListTile(
                  title: const Text('Auto-retry'),
                  value: local.autoRetry,
                  onChanged: (v) {
                    setLocal(() => local = local.copyWith(autoRetry: v));
                    _update(local);
                  },
                  contentPadding: EdgeInsets.zero),
              if (local.autoRetry) ...[
                const SizedBox(height: 8),
                _label('Retry limit'),
                _slider(local.retryLimit.toDouble(), 1, 10, 9,
                    '${local.retryLimit}',
                    (v) {
                      setLocal(() => local = local.copyWith(retryLimit: v.round()));
                      _update(local);
                    }),
              ],
              const SizedBox(height: 16),
              _label('Max detected media'),
              _slider(local.maxDetectedMedia.toDouble(), 20, 150, 13,
                  '${local.maxDetectedMedia}',
                  (v) {
                    setLocal(() => local = local.copyWith(maxDetectedMedia: v.round()));
                    _update(local);
                  }),
              const SizedBox(height: 16),
              _label('Download link behavior'),
              const SizedBox(height: 4),
              _buildDownloadBehaviorDropdown(local, setLocal),
            ])),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedPage() {
    double localSpeed = _speedLimitKbps;
    return Scaffold(
      appBar: AppBar(title: const Text('Speed Limiter')),
      body: StatefulBuilder(
        builder: (context, setLocal) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PanelHeader(icon: Icons.speed_rounded, title: 'Speed Limiter'),
            const SizedBox(height: 8),
            Panel(child: Column(children: [
              Row(children: [
                Icon(Icons.speed, color: AuroraColors.accent, size: 28),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(localSpeed == 0 ? 'Unlimited' : '${localSpeed.round()} KB/s',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700, color: AuroraColors.accent)),
                  Text('Global download speed cap',
                      style: TextStyle(fontSize: 12, color: AuroraColors.mutedText)),
                ])),
              ]),
              const SizedBox(height: 20),
              Slider(
                  value: localSpeed,
                  min: 0, max: 2048, divisions: 16,
                  activeColor: AuroraColors.accent,
                  inactiveColor: AuroraColors.surfaceVariant,
                  onChanged: (v) {
                    setLocal(() => localSpeed = v);
                    widget.onSpeedLimitChanged(v);
                  }),
              Text('0 KB/s (unlimited) — 2048 KB/s',
                  style: TextStyle(fontSize: 11, color: AuroraColors.mutedDeep)),
            ])),
          ],
        ),
      ),
    );
  }

  Widget _buildAdblockPage() {
    var local = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Adblock')),
      body: StatefulBuilder(
        builder: (context, setLocal) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PanelHeader(icon: Icons.shield_rounded, title: 'Adblock'),
            const SizedBox(height: 8),
            Panel(child: Column(children: [
              SwitchListTile(
                  title: const Text('Enable adblock'),
                  value: local.adblockEnabled,
                  onChanged: (v) {
                    setLocal(() => local = local.copyWith(adblockEnabled: v));
                    _update(local);
                  },
                  contentPadding: EdgeInsets.zero),
              SwitchListTile(
                  title: const Text('Block popups'),
                  subtitle: Text(
                      local.popupBlockingEnabled
                          ? 'Programmatic popups are blocked'
                          : 'Popups can open normally',
                      style: TextStyle(fontSize: 12, color: AuroraColors.mutedText)),
                  value: local.popupBlockingEnabled,
                  onChanged: (v) {
                    setLocal(() => local = local.copyWith(popupBlockingEnabled: v));
                    _update(local);
                  },
                  contentPadding: EdgeInsets.zero),
              ListTile(
                title: const Text('Per-site allowlist'),
                subtitle: Text(
                    local.adblockAllowlist.isEmpty
                        ? 'No sites are allowlisted. Manage allowlist per-site from the browser toolbar shield icon.'
                        : '${local.adblockAllowlist.length} site${local.adblockAllowlist.length == 1 ? "" : "s"} allowlisted',
                    style: TextStyle(fontSize: 12, color: AuroraColors.mutedText)),
                trailing: local.adblockAllowlist.isEmpty
                    ? null
                    : TextButton(
                        onPressed: () {
                          final updated = local.copyWith(adblockAllowlist: const []);
                          setLocal(() => local = updated);
                          _update(updated);
                        },
                        child: const Text('Clear all'),
                      ),
                contentPadding: EdgeInsets.zero,
              ),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Sources (${local.adblockFilterSources.length})',
                      style: TextStyle(fontWeight: FontWeight.w600, color: AuroraColors.text)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          final updatedSources = local.adblockFilterSources
                              .map((s) => s.copyWith(enabled: true))
                              .toList();
                          final updated = local.copyWith(adblockFilterSources: updatedSources);
                          setLocal(() => local = updated);
                          _update(updated);
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Enable all', style: TextStyle(fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: () {
                          final updatedSources = local.adblockFilterSources
                              .map((s) => s.copyWith(enabled: false))
                              .toList();
                          final updated = local.copyWith(adblockFilterSources: updatedSources);
                          setLocal(() => local = updated);
                          _update(updated);
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Disable all', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._buildAdblockSourceTiles(local, setLocal),
              const SizedBox(height: 12),
              TextField(
                  controller: widget.adblockSourceController,
                  decoration: InputDecoration(
                    hintText: 'Add custom filter URL',
                    suffixIcon: IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () {
                          final url = widget.adblockSourceController.text.trim();
                          if (url.isNotEmpty) {
                            final updated = local.copyWith(
                                adblockFilterSources: [
                                  ...local.adblockFilterSources,
                                  AdblockFilterSource(url: url, name: url),
                                ]);
                            setLocal(() => local = updated);
                            _update(updated);
                            widget.adblockSourceController.clear();
                          }
                        }),
                  )),
              const SizedBox(height: 16),
              Text(
                  'Manual rules: ${local.manualAdBlockRules.length} network, '
                  '${local.manualCosmeticRules.length} cosmetic',
                  style: TextStyle(fontSize: 12, color: AuroraColors.mutedText)),
            ])),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildAdblockSourceTiles(
      DownloadSettings local, void Function(void Function()) setLocal) {
    final trustedUrls = {
      for (final s in AdblockFilterSource.trustedSources) s.url,
    };
    return [
      for (var index = 0; index < local.adblockFilterSources.length; index++)
        (() {
          final source = local.adblockFilterSources[index];
          final isCustom = !trustedUrls.contains(source.url);
          return CheckboxListTile(
            title: Text(source.name, style: const TextStyle(fontSize: 13)),
            value: source.enabled,
            onChanged: (v) {
              final updatedSources = List<AdblockFilterSource>.from(
                  local.adblockFilterSources);
              updatedSources[index] = source.copyWith(enabled: v ?? false);
              final updated =
                  local.copyWith(adblockFilterSources: updatedSources);
              setLocal(() => local = updated);
              _update(updated);
            },
            secondary: isCustom
                ? IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Remove source',
                    onPressed: () {
                      final updatedSources = List<AdblockFilterSource>.from(
                          local.adblockFilterSources);
                      updatedSources.removeAt(index);
                      final updated =
                          local.copyWith(adblockFilterSources: updatedSources);
                      setLocal(() => local = updated);
                      _update(updated);
                    },
                  )
                : null,
            contentPadding: EdgeInsets.zero,
            dense: true,
          );
        })(),
    ];
  }

  Widget _buildSearchPage() {
    return Scaffold(
      appBar: AppBar(title: const Text('Search Engine')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PanelHeader(icon: Icons.search_rounded, title: 'Search Engine'),
          const SizedBox(height: 8),
          Panel(child: Column(children: [
            DropdownButtonFormField<String>(
                value: _settings.searchEngine.id == 'custom'
                    ? 'custom'
                    : _settings.searchEngine.id,
                decoration: InputDecoration(
                    labelText: 'Search engine',
                    border:
                        OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
                items: ['google', 'duckduckgo', 'bing', 'brave', 'custom']
                    .map((id) => DropdownMenuItem(
                        value: id,
                        child: Text(switch (id) {
                          'google' => 'Google',
                          'duckduckgo' => 'DuckDuckGo',
                          'bing' => 'Bing',
                          'brave' => 'Brave',
                          _ => 'Custom',
                        })))
                    .toList(),
                onChanged: (id) {
                  if (id == null) return;
                  if (id == 'custom') {
                    _update(_settings.copyWith(
                        searchEngine: SearchEngine(
                            id: 'custom',
                            name: 'Custom',
                            templateUrl:
                                _settings.searchEngine.templateUrl)));
                  } else {
                    _update(_settings.copyWith(
                        searchEngine: switch (id) {
                          'google' => SearchEngine.google,
                          'duckduckgo' => SearchEngine.duckDuckGo,
                          'bing' => SearchEngine.bing,
                          _ => SearchEngine.brave,
                        }));
                  }
                }),
            if (_settings.searchEngine.id == 'custom') ...[
              const SizedBox(height: 16),
              TextField(
                  controller: widget.customSearchController,
                  decoration: InputDecoration(
                      labelText: 'Custom URL template (use %s for query)',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8))),
                  onChanged: (v) => _update(_settings.copyWith(
                      searchEngine: SearchEngine(
                          id: 'custom', name: 'Custom', templateUrl: v)))),
            ],
          ])),
        ],
      ),
    );
  }

  Widget _buildSnifferPage() {
    var localDisabled = Set<MediaType>.from(_settings.disabledMediaTypes);
    return Scaffold(
      appBar: AppBar(title: const Text('Media Sniffer')),
      body: StatefulBuilder(
        builder: (context, setLocal) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PanelHeader(icon: Icons.tune_rounded, title: 'Disabled Media Types'),
            const SizedBox(height: 8),
            Panel(child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: MediaType.values.map((type) {
                final isDisabled = localDisabled.contains(type);
                return MediaTypeChip(
                  type: type,
                  disabled: isDisabled,
                  onChanged: (_) {
                    final updated = Set<MediaType>.from(localDisabled);
                    if (isDisabled) {
                      updated.remove(type);
                    } else {
                      updated.add(type);
                    }
                    setLocal(() => localDisabled = updated);
                    _update(_settings.copyWith(disabledMediaTypes: updated));
                  },
                );
              }).toList(),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildDrivePage() {
    return _DriveSyncPageContent(
      driveSyncService: widget.driveSyncService,
      folderController: widget.folderController,
      initialState: widget.driveSyncService.state,
      initialConnected: _driveConnected,
    );
  }

  Widget _buildAppearancePage() {
    var localPref = _settings.darkModePreference;
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: StatefulBuilder(
        builder: (context, setLocal) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PanelHeader(icon: Icons.palette_outlined, title: 'Appearance'),
            const SizedBox(height: 8),
            Panel(child: Column(children: [
              DropdownButtonFormField<DarkModePreference>(
                value: localPref,
                decoration: InputDecoration(
                  labelText: 'Dark mode preference',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                items: DarkModePreference.values
                    .map((pref) => DropdownMenuItem(
                          value: pref,
                          child: Text(switch (pref) {
                            DarkModePreference.system => 'System default',
                            DarkModePreference.off => 'Light',
                            DarkModePreference.forced => 'Dark (OLED black)',
                          }),
                        ))
                    .toList(),
                onChanged: (pref) {
                  if (pref == null) return;
                  setLocal(() => localPref = pref);
                  _update(_settings.copyWith(darkModePreference: pref));
                },
              ),
            ])),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkPage() {
    return Scaffold(
      appBar: AppBar(title: const Text('Network')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PanelHeader(icon: Icons.wifi_rounded, title: 'Network'),
          const SizedBox(height: 8),
          Panel(child: Column(
            children: [
              Text('Proxy and user-agent settings coming soon.',
                  style: TextStyle(fontSize: 13, color: AuroraColors.mutedText)),
            ],
          )),
        ],
      ),
    );
  }

  Widget _buildAboutPage() {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PanelHeader(icon: Icons.info_outline, title: 'About'),
          const SizedBox(height: 8),
          Panel(child: Column(
            children: [
              Text('Aurora Downloader',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AuroraColors.text)),
              const SizedBox(height: 4),
              Text('v1.1.9', style: TextStyle(fontSize: 13, color: AuroraColors.mutedText)),
              const SizedBox(height: 16),
              Text('Android download manager with segmented HTTP, HLS, torrent, browser sniffing, and Google Drive sync.',
                  style: TextStyle(fontSize: 13, color: AuroraColors.mutedText)),
              const SizedBox(height: 24),
              Text('Built with Flutter, libtorrent, and the Nord palette.',
                  style: TextStyle(fontSize: 12, color: AuroraColors.mutedDeep)),
            ],
          )),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _update(DownloadSettings s) {
    setState(() => _settings = s);
    widget.onSettingsChanged(s);
  }

  Widget _buildDownloadBehaviorDropdown(
    DownloadSettings local,
    void Function(void Function()) setLocal,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AuroraColors.glassSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AuroraColors.glassBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<DownloadLinkBehavior>(
          value: local.downloadLinkBehavior,
          isExpanded: true,
          icon: Icon(Icons.expand_more, color: AuroraColors.mutedText),
          items: const [
            DropdownMenuItem(
              value: DownloadLinkBehavior.capture,
              child: Text('Capture to tray (review before download)'),
            ),
            DropdownMenuItem(
              value: DownloadLinkBehavior.autoDownload,
              child: Text('Download directly'),
            ),
            DropdownMenuItem(
              value: DownloadLinkBehavior.ask,
              child: Text('Ask each time'),
            ),
            DropdownMenuItem(
              value: DownloadLinkBehavior.block,
              child: Text('Block all downloads'),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setLocal(() => local = local.copyWith(downloadLinkBehavior: v));
            _update(local);
          },
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AuroraColors.text)),
    );
  }

  Widget _slider(double value, double min, double max, int divisions,
      String label, ValueChanged<double> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SliderTheme(
          data: SliderThemeData(
              activeTrackColor: AuroraColors.accent,
              inactiveTrackColor: AuroraColors.surfaceVariant,
              thumbColor: AuroraColors.accent,
              overlayColor: AuroraColors.accent.withValues(alpha: 0.14)),
          child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: label,
              onChanged: onChanged)),
      Text(label,
          style: TextStyle(
              fontSize: 12,
              color: AuroraColors.accent,
              fontFamily: 'monospace')),
    ]);
  }

  Widget _buildBackupPage() {
    return BackupPage(
      downloadQueue: widget.downloadQueue,
      settings: _settings,
      onSettingsChanged: _update,
      libraryUpdateNotifier: widget.libraryUpdateNotifier,
    );
  }
}

/// Detail page for Drive Sync settings with live state subscription.
class _DriveSyncPageContent extends StatefulWidget {
  final DriveSyncService driveSyncService;
  final TextEditingController folderController;
  final DriveSyncState initialState;
  final bool initialConnected;

  const _DriveSyncPageContent({
    required this.driveSyncService,
    required this.folderController,
    required this.initialState,
    required this.initialConnected,
  });

  @override
  State<_DriveSyncPageContent> createState() => _DriveSyncPageContentState();
}

class _DriveSyncPageContentState extends State<_DriveSyncPageContent> {
  late DriveSyncState _state;
  late bool _connected;
  StreamSubscription<DriveSyncState>? _sub;

  @override
  void initState() {
    super.initState();
    _state = widget.initialState;
    _connected = widget.initialConnected;
    _sub = widget.driveSyncService.onStateChanged.listen((s) {
      if (mounted) setState(() {
        _state = s;
        _connected = s.status == DriveConnectionStatus.connected;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Drive Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PanelHeader(
              icon: Icons.cloud_rounded,
              title: 'Drive Sync',
              trailing: TextButton(
                  onPressed: _connected
                      ? () => widget.driveSyncService.disconnect()
                      : () => widget.driveSyncService.connect(),
                  child: Text(_connected ? 'Disconnect' : 'Link'))),
          const SizedBox(height: 8),
          Panel(
              child: _connected
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Connected as ${_state.account ?? "Unknown"}',
                            style: TextStyle(
                                color: AuroraColors.accent, fontSize: 13)),
                        if (_state.errorMessage != null) ...[
                          const SizedBox(height: 8),
                          Text(_state.errorMessage!,
                              style: TextStyle(
                                  color: AuroraColors.nordRed,
                                  fontSize: 12)),
                        ],
                        const SizedBox(height: 16),
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: widget.folderController,
                                  decoration: InputDecoration(
                                      labelText: 'Upload folder',
                                      isDense: true,
                                      border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8))))),
                          const SizedBox(width: 8),
                          ElevatedButton(
                              onPressed: () => widget.driveSyncService
                                  .setDestinationFolder(
                                      widget.folderController.text),
                              child: const Text('Set')),
                        ]),
                        const SizedBox(height: 12),
                        SwitchListTile(
                            title: const Text('Auto upload completed files'),
                            value: _state.autoSyncEnabled,
                            onChanged: (v) =>
                                widget.driveSyncService.setAutoSyncEnabled(v),
                            contentPadding: EdgeInsets.zero),
                      ],
                    )
                  : Column(children: [
                      Text('Link Google Drive to auto-upload completed downloads.',
                          style: TextStyle(
                              color: AuroraColors.mutedText, fontSize: 13)),
                      const SizedBox(height: 16),
                      SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                              icon: const Icon(Icons.link),
                              label: const Text('Link Google Drive'),
                              onPressed: () =>
                                  widget.driveSyncService.connect())),
                    ])),
        ],
      ),
    );
  }
}

class BackupPage extends StatefulWidget {
  final DownloadQueue downloadQueue;
  final DownloadSettings settings;
  final ValueChanged<DownloadSettings> onSettingsChanged;
  final ValueNotifier<int> libraryUpdateNotifier;

  const BackupPage({
    super.key,
    required this.downloadQueue,
    required this.settings,
    required this.onSettingsChanged,
    required this.libraryUpdateNotifier,
  });

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  BrowserLibrary? _library;
  bool _loading = true;

  bool exportFavorites = true;
  bool exportHistory = true;
  bool exportSavedPages = true;
  bool exportQueue = true;
  bool exportSettings = true;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final lib = await const BrowserLibraryStore().load();
    if (mounted) {
      setState(() {
        _library = lib;
        _loading = false;
      });
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: AuroraColors.text)),
        backgroundColor: AuroraColors.surfaceVariant,
      ),
    );
  }

  Future<void> _exportBackup() async {
    try {
      final List<Map<String, dynamic>>? downloadQueueJson = exportQueue
          ? widget.downloadQueue.allTasks.map((t) => t.toJson()).toList()
          : null;
      final Map<String, dynamic>? settingsJson = exportSettings
          ? widget.settings.toJson()
          : null;

      final file = await const BrowserLibraryStore().exportToFile(
        exportFavorites: exportFavorites,
        exportHistory: exportHistory,
        exportSavedPages: exportSavedPages,
        downloadQueueJson: downloadQueueJson,
        settingsJson: settingsJson,
      );
      await PublicDownloadsService.shareFile(file.path);
      _showSnack('Backup exported successfully.');
    } catch (error) {
      _showSnack('Export failed: $error');
    }
  }

  Future<void> _importBackup() async {
    try {
      final filePath = await PublicDownloadsService.pickImportFile();
      if (filePath == null) return;

      final Map<String, dynamic> decoded;
      if (filePath.toLowerCase().endsWith('.1dmbak')) {
        decoded = await IdmBackupParser.parse(filePath);
      } else {
        decoded = await const BrowserLibraryStore().readImportMap(filePath);
      }

      final hasFavorites = decoded.containsKey('favorites') && (decoded['favorites'] is List) && (decoded['favorites'] as List).isNotEmpty;
      final hasHistory = decoded.containsKey('history') && (decoded['history'] is List) && (decoded['history'] as List).isNotEmpty;
      final hasSavedPages = decoded.containsKey('savedPages') && (decoded['savedPages'] is List) && (decoded['savedPages'] as List).isNotEmpty;
      final hasQueue = decoded.containsKey('downloadQueue') && (decoded['downloadQueue'] is List) && (decoded['downloadQueue'] as List).isNotEmpty;
      final hasSettings = decoded.containsKey('settings');

      final isLegacy = decoded.containsKey('favorites') ||
          decoded.containsKey('history') ||
          decoded.containsKey('savedPages') ||
          (!decoded.containsKey('settings') &&
              !decoded.containsKey('downloadQueue') &&
              decoded.isNotEmpty &&
              !decoded.containsKey('favorites') &&
              !decoded.containsKey('history') &&
              !decoded.containsKey('savedPages'));

      bool importFavorites = hasFavorites || isLegacy;
      bool importHistory = hasHistory || isLegacy;
      bool importSavedPages = hasSavedPages || isLegacy;
      bool importQueue = hasQueue;
      bool importSettings = hasSettings;

      if (!hasFavorites && !isLegacy) importFavorites = false;
      if (!hasHistory && !isLegacy) importHistory = false;
      if (!hasSavedPages && !isLegacy) importSavedPages = false;

      bool proceed = false;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setModalState) {
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
                            Icons.file_download_outlined,
                            color: AuroraColors.accent,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Import Library',
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
                        title: const Text('Favorites / Bookmarks', style: TextStyle(color: AuroraColors.text)),
                        value: importFavorites,
                        onChanged: (hasFavorites || isLegacy)
                            ? (val) => setModalState(() => importFavorites = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('Web History', style: TextStyle(color: AuroraColors.text)),
                        value: importHistory,
                        onChanged: (hasHistory || isLegacy)
                            ? (val) => setModalState(() => importHistory = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('Saved Pages', style: TextStyle(color: AuroraColors.text)),
                        value: importSavedPages,
                        onChanged: (hasSavedPages || isLegacy)
                            ? (val) => setModalState(() => importSavedPages = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('Download History (Queue)', style: TextStyle(color: AuroraColors.text)),
                        value: importQueue,
                        onChanged: hasQueue
                            ? (val) => setModalState(() => importQueue = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('App Settings', style: TextStyle(color: AuroraColors.text)),
                        value: importSettings,
                        onChanged: hasSettings
                            ? (val) => setModalState(() => importSettings = val)
                            : null,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel', style: TextStyle(color: AuroraColors.mutedText)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AuroraColors.accent,
                              foregroundColor: AuroraColors.background,
                            ),
                            onPressed: (!importFavorites &&
                                    !importHistory &&
                                    !importSavedPages &&
                                    !importQueue &&
                                    !importSettings)
                                ? null
                                : () {
                                    proceed = true;
                                    Navigator.pop(ctx);
                                  },
                            child: const Text('Import'),
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

      if (!proceed) return;

      final baseDir = (await getApplicationSupportDirectory()).path;
      final baseTemp = (await getTemporaryDirectory()).path;
      int importedFavoritesCount = 0;
      int importedHistoryCount = 0;
      int importedSavedPagesCount = 0;
      int importedQueueCount = 0;
      bool importedSettings = false;

      BrowserLibrary updatedLibrary = _library ?? BrowserLibrary.empty();

      // 1. App Settings
      if (importSettings && decoded.containsKey('settings')) {
        final settingsMap = decoded['settings'];
        if (settingsMap is Map) {
          final imported = DownloadSettings.fromJson(
            Map<String, dynamic>.from(settingsMap),
          );
          widget.onSettingsChanged.call(imported);
          importedSettings = true;
        }
      }

      // 2. Download Queue
      if (importQueue && decoded.containsKey('downloadQueue')) {
        final queueList = decoded['downloadQueue'];
        if (queueList is List) {
          for (final item in queueList) {
            if (item is! Map) continue;
            try {
              final taskMap = Map<String, dynamic>.from(item);

              // Dynamic re-basing of savePath to the current base directory
              String savePath = taskMap['savePath'] as String? ?? '';
              final normalized = savePath.replaceAll('\\', '/');
              final completedIndex = normalized.lastIndexOf('/completed/');
              if (completedIndex != -1) {
                final relativePart = normalized.substring(
                  completedIndex + '/completed/'.length,
                );
                taskMap['savePath'] =
                    '$baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}${relativePart.replaceAll('/', Platform.pathSeparator)}';
              } else if (savePath.startsWith('completed/') ||
                  savePath.startsWith('completed\\')) {
                final relativePart = savePath.substring('completed/'.length);
                taskMap['savePath'] =
                    '$baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}${relativePart.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator)}';
              } else {
                final filename = p.basename(savePath);
                taskMap['savePath'] =
                    '$baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}$filename';
              }

              // Dynamic re-basing of tempDir to the current base temp directory
              String tempDir = taskMap['tempDir'] as String? ?? '';
              final normalizedTemp = tempDir.replaceAll('\\', '/');
              final tempIndex = normalizedTemp.lastIndexOf('/temp_');
              if (tempIndex != -1) {
                final relativePart = normalizedTemp.substring(tempIndex);
                taskMap['tempDir'] = '$baseTemp$relativePart';
              } else {
                taskMap['tempDir'] =
                    '$baseTemp${Platform.pathSeparator}temp_${DateTime.now().millisecondsSinceEpoch}_$importedQueueCount';
              }

              final task = DownloadTask.fromJson(taskMap);
              widget.downloadQueue.addTask(task);
              importedQueueCount++;
            } catch (_) {}
          }
        }
      }

      // 3. Browser Library - Favorites / Folders
      if (importFavorites && decoded.containsKey('favorites')) {
        final importedFolders = decoded.containsKey('folders')
            ? (decoded['folders'] as List? ?? const [])
                  .whereType<Map>()
                  .map(
                    (item) => BookmarkFolder.fromJson(
                      Map<String, dynamic>.from(item),
                    ),
                  )
                  .toList()
            : updatedLibrary.folders;
        final known = {for (final folder in importedFolders) folder.id};
        final importedFavorites = (decoded['favorites'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  BrowserFavorite.fromJson(Map<String, dynamic>.from(item)),
            )
            .map((favorite) {
              if (favorite.folderId != null &&
                  !known.contains(favorite.folderId)) {
                return favorite.copyWith(clearFolder: true);
              }
              return favorite;
            })
            .toList();

        updatedLibrary = updatedLibrary.copyWith(
          favorites: importedFavorites,
          folders: importedFolders,
        );
        importedFavoritesCount = importedFavorites.length;
      }

      // 4. Browser Library - History
      if (importHistory && decoded.containsKey('history')) {
        final importedHistory = (decoded['history'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  BrowserHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
        updatedLibrary = updatedLibrary.copyWith(history: importedHistory);
        importedHistoryCount = importedHistory.length;
      }

      // 5. Browser Library - Saved Pages
      if (importSavedPages && decoded.containsKey('savedPages')) {
        final importedSavedPages = (decoded['savedPages'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => SavedPage.fromJson(Map<String, dynamic>.from(item)))
            .toList();
        updatedLibrary = updatedLibrary.copyWith(
          savedPages: importedSavedPages,
        );
        importedSavedPagesCount = importedSavedPages.length;
      }

      if (importFavorites || importHistory || importSavedPages) {
        if (!decoded.containsKey('favorites') &&
            !decoded.containsKey('history') &&
            !decoded.containsKey('savedPages')) {
          final legacyLib = BrowserLibrary.fromJson(decoded);
          List<BrowserFavorite>? favs;
          List<BookmarkFolder>? folders;
          List<BrowserHistoryEntry>? hist;
          List<SavedPage>? saved;

          if (importFavorites) {
            favs = legacyLib.favorites;
            folders = legacyLib.folders;
            importedFavoritesCount = legacyLib.favorites.length;
          }
          if (importHistory) {
            hist = legacyLib.history;
            importedHistoryCount = legacyLib.history.length;
          }
          if (importSavedPages) {
            saved = legacyLib.savedPages;
            importedSavedPagesCount = legacyLib.savedPages.length;
          }

          updatedLibrary = updatedLibrary.copyWith(
            favorites: favs,
            folders: folders,
            history: hist,
            savedPages: saved,
          );
        }
        await const BrowserLibraryStore().save(updatedLibrary);
      }

      final List<String> summary = [];
      if (importedFavoritesCount > 0) {
        summary.add('$importedFavoritesCount favorites');
      }
      if (importedHistoryCount > 0) {
        summary.add('$importedHistoryCount history entries');
      }
      if (importedSavedPagesCount > 0) {
        summary.add('$importedSavedPagesCount saved pages');
      }
      if (importedQueueCount > 0) {
        summary.add('$importedQueueCount download tasks');
      }
      if (importedSettings) {
        summary.add('app settings');
      }

      if (summary.isEmpty) {
        _showSnack('Import completed (no new items found).');
      } else {
        _showSnack('Imported: ${summary.join(", ")}.');
      }

      widget.libraryUpdateNotifier.value++;
      await _loadLibrary();
    } catch (error) {
      _showSnack('Import failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  PanelHeader(icon: Icons.backup_rounded, title: 'Backup & Restore'),
                  const SizedBox(height: 8),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Export Backup',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AuroraColors.text),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Select categories to include in your backup file:',
                          style: TextStyle(fontSize: 12, color: AuroraColors.mutedText),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          activeColor: AuroraColors.accent,
                          title: const Text('Favorites / Bookmarks', style: TextStyle(color: AuroraColors.text, fontSize: 13)),
                          subtitle: Text(
                            '${_library?.favorites.length ?? 0} favorites, ${_library?.folders.length ?? 0} folders',
                            style: const TextStyle(color: AuroraColors.mutedDeep, fontSize: 11),
                          ),
                          value: exportFavorites,
                          onChanged: (v) => setState(() => exportFavorites = v),
                        ),
                        SwitchListTile(
                          activeColor: AuroraColors.accent,
                          title: const Text('Web History', style: TextStyle(color: AuroraColors.text, fontSize: 13)),
                          subtitle: Text(
                            '${_library?.history.length ?? 0} entries',
                            style: const TextStyle(color: AuroraColors.mutedDeep, fontSize: 11),
                          ),
                          value: exportHistory,
                          onChanged: (v) => setState(() => exportHistory = v),
                        ),
                        SwitchListTile(
                          activeColor: AuroraColors.accent,
                          title: const Text('Saved Pages', style: TextStyle(color: AuroraColors.text, fontSize: 13)),
                          subtitle: Text(
                            '${_library?.savedPages.length ?? 0} pages',
                            style: const TextStyle(color: AuroraColors.mutedDeep, fontSize: 11),
                          ),
                          value: exportSavedPages,
                          onChanged: (v) => setState(() => exportSavedPages = v),
                        ),
                        SwitchListTile(
                          activeColor: AuroraColors.accent,
                          title: const Text('Download History (Queue)', style: TextStyle(color: AuroraColors.text, fontSize: 13)),
                          subtitle: Text(
                            '${widget.downloadQueue.allTasks.length} tasks',
                            style: const TextStyle(color: AuroraColors.mutedDeep, fontSize: 11),
                          ),
                          value: exportQueue,
                          onChanged: (v) => setState(() => exportQueue = v),
                        ),
                        SwitchListTile(
                          activeColor: AuroraColors.accent,
                          title: const Text('App Settings', style: TextStyle(color: AuroraColors.text, fontSize: 13)),
                          subtitle: const Text(
                            'Limits, search engine, adblock toggles',
                            style: TextStyle(color: AuroraColors.mutedDeep, fontSize: 11),
                          ),
                          value: exportSettings,
                          onChanged: (v) => setState(() => exportSettings = v),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Export Backup File'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AuroraColors.accent,
                            foregroundColor: AuroraColors.background,
                          ),
                          onPressed: (!exportFavorites &&
                                  !exportHistory &&
                                  !exportSavedPages &&
                                  !exportQueue &&
                                  !exportSettings)
                              ? null
                              : _exportBackup,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Import Backup',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AuroraColors.text),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Restore your bookmarks, history, settings, or tasks from a previously saved JSON or 1DMBak backup file.',
                          style: TextStyle(fontSize: 12, color: AuroraColors.mutedText),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.file_download_outlined),
                          label: const Text('Import Backup File'),
                          onPressed: _importBackup,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
