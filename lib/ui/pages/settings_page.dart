import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../downloader/downloader.dart';
import '../../downloader/download_rules.dart';
import '../../platform/public_downloads_service.dart';
import '../../platform/download_foreground_service.dart';
import '../../sniffer/browser_library.dart';
import '../../sniffer/idm_backup_parser.dart';
import '../../backup/auto_backup_service.dart';
import '../../backup/auto_backup_models.dart';

import '../../settings/download_settings.dart';
import '../../premium/pro_entitlement.dart';
import '../../premium/pro_features.dart';
import '../../premium/pro_upsell_sheet.dart';
import '../../premium/play_billing_service.dart';
import '../../premium/build_channel.dart';
import '../../sniffer/media_sniffer_engine.dart';
import '../../sniffer/models/site_profile.dart';
import '../../sniffer/models/sniffed_media.dart';
import '../../sync/sync.dart';
import '../../theme/aurora_palette.dart';
import '../notifications/aurora_snackbar.dart';
import '../widgets/dock_order_store.dart';
import '../widgets/media_type_chip.dart';
import '../widgets/panel.dart';
import 'diagnostics_page.dart';

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
  final AutoBackupService autoBackupService;
  final ProEntitlement proEntitlement;
  final PlayBillingService? playBilling;

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
    required this.autoBackupService,
    required this.proEntitlement,
    this.playBilling,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const List<int> _retryLimitSteps = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
    20, 50, 100, 200, 500, 1000, 5000, 20000, 100000, 999999
  ];

  int _getRetryLimitIndex(int limit) {
    final idx = _retryLimitSteps.indexOf(limit);
    if (idx != -1) return idx;
    int closestIndex = 0;
    int minDiff = (limit - _retryLimitSteps[0]).abs();
    for (int i = 1; i < _retryLimitSteps.length; i++) {
      final diff = (limit - _retryLimitSteps[i]).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closestIndex = i;
      }
    }
    return closestIndex;
  }

  String _getRetryLimitLabel(int limit) {
    if (limit >= 999999) {
      return 'Up to 999,999 retries';
    }
    return '$limit';
  }

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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _buildProfileHeader(),
            const SizedBox(height: 20),
            _buildSettingsHub(),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Profile header
  // ---------------------------------------------------------------------------

  Widget _buildProfileHeader() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openPage(_buildDrivePage()),
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.ac.glassSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.ac.glassBorder),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: context.ac.surfaceElevated,
                radius: 24,
                child: Icon(
                  Icons.cloud_outlined,
                  color: context.ac.textSecondary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Aurora Downloader',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                        color: context.ac.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Google Drive sync — upcoming',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.ac.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: context.ac.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Hub: grouped navigation rows (replaces uneven 2-col card grid)
  // ---------------------------------------------------------------------------

  Widget _buildSettingsHub() {
    return ListenableBuilder(
      listenable: widget.proEntitlement,
      builder: (context, _) {
        final isPro = widget.proEntitlement.isPro;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionTitle('Downloads'),
            _buildNavGroup([
              _NavItem(
                icon: Icons.download_rounded,
                title: 'Defaults',
                subtitle: 'Save location, concurrency, retries',
                onTap: () => _openPage(_buildDefaultsPage()),
              ),
              _NavItem(
                icon: Icons.wifi_rounded,
                title: 'Network',
                subtitle: 'Proxy and browser identity',
                onTap: () => _openPage(_buildNetworkPage()),
              ),
              _NavItem(
                icon: Icons.rule_rounded,
                title: 'Rules',
                subtitle: 'Auto-rename and organize',
                badge: isPro ? null : 'Pro',
                onTap: () => _openPage(_buildRulesPage()),
              ),
              _NavItem(
                icon: Icons.schedule_rounded,
                title: 'Schedule',
                subtitle: 'Download later / night mode',
                badge: isPro ? null : 'Pro',
                onTap: () => _openPage(_buildSchedulePage()),
              ),
            ]),
            const SizedBox(height: 18),
            _buildSectionTitle('Browser'),
            _buildNavGroup([
              _NavItem(
                icon: Icons.shield_rounded,
                title: 'Adblock',
                subtitle: 'Ads, popups, filter lists',
                onTap: () => _openPage(_buildAdblockPage()),
              ),
              _NavItem(
                icon: Icons.search_rounded,
                title: 'Search',
                subtitle: _settings.searchEngine.name,
                onTap: () => _openPage(_buildSearchPage()),
              ),
              _NavItem(
                icon: Icons.tune_rounded,
                title: 'Sniffer',
                subtitle: 'Media types and site player',
                onTap: () => _openPage(_buildSnifferPage()),
              ),
              _NavItem(
                icon: Icons.people_outline_rounded,
                title: 'Profiles',
                subtitle: 'Per-site browser settings',
                badge: isPro ? null : 'Pro',
                onTap: () => _openPage(_buildProfilesPage()),
              ),
            ]),
            const SizedBox(height: 18),
            _buildSectionTitle('Appearance'),
            _buildNavGroup([
              _NavItem(
                icon: Icons.palette_outlined,
                title: 'Theme',
                subtitle: 'Dark mode and display',
                onTap: () => _openPage(_buildAppearancePage()),
              ),
            ]),
            const SizedBox(height: 18),
            _buildSectionTitle('Data & account'),
            _buildNavGroup([
              _NavItem(
                icon: Icons.cloud_outlined,
                title: 'Google Drive',
                subtitle: _driveConnected
                    ? 'Linked · manage sync'
                    : 'Link account for backup sync',
                badge: isPro ? null : 'Pro',
                onTap: () => _openPage(_buildDrivePage()),
              ),
              _NavItem(
                icon: Icons.backup_rounded,
                title: 'Backup',
                subtitle: 'Save and restore app data',
                onTap: () => _openPage(_buildBackupPage()),
              ),
              _NavItem(
                icon: isPro
                    ? Icons.auto_awesome
                    : Icons.auto_awesome_outlined,
                title: 'Aurora Pro',
                subtitle: isPro
                    ? 'Premium features unlocked'
                    : 'Unlock premium features',
                onTap: () => _openPage(_buildProPage()),
              ),
            ]),
            const SizedBox(height: 18),
            _buildSectionTitle('About'),
            _buildNavGroup([
              _NavItem(
                icon: Icons.info_outline_rounded,
                title: 'About',
                subtitle: 'v1.1.9 · diagnostics · battery',
                onTap: () => _openPage(_buildAboutPage()),
              ),
            ]),
          ],
        );
      },
    );
  }

  Widget _buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: context.ac.textTertiary,
          letterSpacing: 0.9,
        ),
      ),
    );
  }

  Widget _buildNavGroup(List<_NavItem> items) {
    return Container(
      decoration: BoxDecoration(
        color: context.ac.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.ac.borderHairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 56,
                color: context.ac.borderHairline,
              ),
            _buildNavRow(items[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildNavRow(_NavItem item) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: context.ac.accentFrost.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  item.icon,
                  size: 20,
                  color: context.ac.accentFrost,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                              color: context.ac.textPrimary,
                            ),
                          ),
                        ),
                        if (item.badge != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: context.ac.accentPurple
                                  .withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              item.badge!,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                                color: context.ac.accentPurple,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.ac.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                color: context.ac.textTertiary,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openPage(Widget page) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.3, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            )),
            child: FadeTransition(
              opacity: animation,
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
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
              _label('Destination (under Downloads)'),
              const SizedBox(height: 6),
              _DownloadDestinationEditor(
                value: local.downloadDestination,
                autoClassifyEnabled: local.autoClassifyEnabled,
                onChanged: (dest) {
                  setLocal(
                    () => local = local.copyWith(downloadDestination: dest),
                  );
                  _update(local);
                },
              ),
              const SizedBox(height: 16),
              _label('Max concurrent downloads'),
              _slider(local.maxConcurrentDownloads.toDouble(), 1, 12, 11,
                  '${local.maxConcurrentDownloads}',
                  (v) {
                    setLocal(() => local = local.copyWith(maxConcurrentDownloads: v.round()));
                    _update(local);
                  }),
              const SizedBox(height: 16),
              _label('Chunks per download'),
              _slider(local.chunksPerTask.toDouble(), 1, 32, 31,
                  '${local.chunksPerTask}',
                  (v) {
                    setLocal(() => local = local.copyWith(chunksPerTask: v.round()));
                    _update(local);
                  }),
              const SizedBox(height: 16),
              SwitchListTile(
                  title: const Text('Auto-retry failed downloads'),
                  value: local.autoRetry,
                  onChanged: (v) {
                    setLocal(() => local = local.copyWith(autoRetry: v));
                    _update(local);
                  },
                  contentPadding: EdgeInsets.zero),
              if (local.autoRetry) ...[
                const SizedBox(height: 8),
                _label('Retry limit'),
                _slider(
                    _getRetryLimitIndex(local.retryLimit).toDouble(),
                    0,
                    (_retryLimitSteps.length - 1).toDouble(),
                    _retryLimitSteps.length - 1,
                    _getRetryLimitLabel(local.retryLimit),
                    (v) {
                      final selectedLimit = _retryLimitSteps[v.round()];
                      setLocal(() => local = local.copyWith(retryLimit: selectedLimit));
                      _update(local);
                    }),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Auto-classify downloads'),
                subtitle: const Text('Sort finished files into Videos, Audio, Images, Documents when they land in Downloads.'),
                value: local.autoClassifyEnabled,
                onChanged: (v) {
                  setLocal(() => local = local.copyWith(autoClassifyEnabled: v));
                  _update(local);
                },
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Convert .ts to .mp4'),
                subtitle: const Text('After download, Aurora remuxes MPEG-TS (.ts) — including HLS — to .mp4 so files play in any app. Turn off to keep the original .ts.'),
                value: local.remuxTsToMp4,
                onChanged: (v) {
                  setLocal(() => local = local.copyWith(remuxTsToMp4: v));
                  _update(local);
                },
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Include quality suffix'),
                subtitle: const Text('Appends " (720p)" etc. to filenames when a resolution is detected.'),
                value: local.includeQualitySuffix,
                onChanged: (v) {
                  setLocal(() => local = local.copyWith(includeQualitySuffix: v));
                  _update(local);
                },
                contentPadding: EdgeInsets.zero,
              ),
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
              const SizedBox(height: 20),
              _buildSpeedSection(local, setLocal),
              const Divider(height: 24),
              // Wi‑Fi only — Pro-gated
              SwitchListTile(
                title: const Text('Wi‑Fi only downloads'),
                subtitle: Text(
                  local.wifiOnly
                      ? 'Downloads only proceed on Wi‑Fi. Turn off to use mobile data.'
                      : 'Enable to restrict downloads to Wi‑Fi networks.',
                  style: TextStyle(
                      fontSize: 12, color: context.ac.textSecondary),
                ),
                value: local.wifiOnly,
                onChanged: (v) {
                  if (v && !widget.proEntitlement.isPro) {
                    showProUpsell(context, ProFeature.wifiOnly);
                    return;
                  }
                  setLocal(() => local = local.copyWith(wifiOnly: v));
                  _update(local);
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (widget.proEntitlement.isPro) ...[
                const SizedBox(height: 8),
                Text('Pro: Advanced stall controls',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: context.ac.accentFrost)),
                const SizedBox(height: 8),
                _label('Stall timeout (seconds)'),
                _slider(
                    local.stallTimeoutSeconds.toDouble(), 5, 120, 23,
                    '${local.stallTimeoutSeconds}s',
                    (v) {
                      setLocal(() =>
                          local = local.copyWith(stallTimeoutSeconds: v.round()));
                      _update(local);
                    }),
                const SizedBox(height: 8),
                _label('Min speed threshold (KB/s)'),
                _slider(
                    local.minSpeedThresholdKbps.toDouble(), 1, 500, 50,
                    '${local.minSpeedThresholdKbps} KB/s',
                    (v) {
                      setLocal(() => local =
                          local.copyWith(minSpeedThresholdKbps: v.round()));
                      _update(local);
                    }),
                const SizedBox(height: 8),
                _label('Partial download merge threshold'),
                _slider(
                    (local.partialDownloadThreshold * 100).roundToDouble(),
                    50, 100, 50,
                    '${(local.partialDownloadThreshold * 100).round()}%',
                    (v) {
                      setLocal(() => local = local.copyWith(
                          partialDownloadThreshold: v / 100));
                      _update(local);
                    }),
              ] else ...[
                const SizedBox(height: 8),
                ListTile(
                  leading: Icon(Icons.lock_outline,
                      size: 18, color: context.ac.textTertiary),
                  title: Text('Advanced stall controls',
                      style: TextStyle(
                          fontSize: 13, color: context.ac.textSecondary)),
                  subtitle: Text(
                      'Stall timeout, speed threshold, and partial merge (Pro)',
                      style: TextStyle(
                          fontSize: 12, color: context.ac.textTertiary)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onTap: () =>
                      showProUpsell(context, ProFeature.advancedStall),
                ),
              ],
            ])),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Speed limit — exponential slider embedded in Defaults page
  // ---------------------------------------------------------------------------

  /// Convert MB/s to slider position (0–100).
  /// 0 = unlimited, 1–20 = 1–20 MB/s (linear), 21–100 = exponential to 500 MB/s.
  int _speedMbpsToPosition(double mbps) {
    if (mbps <= 0) return 0;
    if (mbps <= 20) return mbps.round().clamp(1, 20);
    final t = math.log(mbps / 20.0) / math.log(500.0 / 20.0);
    return (21 + t * 80).round().clamp(21, 100);
  }

  /// Convert slider position (0–100) back to MB/s.
  double _speedPositionToMbps(int pos) {
    if (pos <= 0) return 0;
    if (pos <= 20) return pos.toDouble();
    final t = (pos - 20) / 80.0;
    return 20.0 * math.pow(500.0 / 20.0, t);
  }

  /// Human-readable label for a slider position.
  String _speedPositionLabel(int pos) {
    if (pos <= 0) return 'Unlimited';
    final mbps = _speedPositionToMbps(pos);
    if (mbps < 1000) return '${mbps.toStringAsFixed(1)} MB/s';
    return '${(mbps / 1000).toStringAsFixed(1)} GB/s';
  }

  Widget _buildSpeedSection(DownloadSettings local, StateSetter setLocal) {
    // _speedLimitKbps is in KB/s — convert to MB/s for the slider
    final speedMbps = _speedLimitKbps / 1024;
    final sliderPos = _speedMbpsToPosition(speedMbps).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('Speed limit'),
      Row(children: [
        Icon(Icons.speed, color: context.ac.accentFrost, size: 22),
        const SizedBox(width: 8),
        Text(_speedPositionLabel(sliderPos.toInt()),
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.ac.accentFrost)),
      ]),
      const SizedBox(height: 8),
      SliderTheme(
          data: SliderThemeData(
              activeTrackColor: context.ac.accentFrost,
              inactiveTrackColor: context.ac.surfaceElevated,
              thumbColor: context.ac.accentFrost,
              overlayColor: context.ac.accentFrost.withValues(alpha: 0.14)),
          child: Slider(
              value: sliderPos.clamp(0, 100),
              min: 0,
              max: 100,
              divisions: 100,
              label: _speedPositionLabel(sliderPos.toInt()),
              onChanged: (v) {
                final pos = v.round();
                final mbps = _speedPositionToMbps(pos);
                // Upstream expects KB/s
                widget.onSpeedLimitChanged(mbps * 1024);
                setLocal(() {});
              })),
      Text('Set to 0 for no limit, or drag right to cap speed (up to 500 MB/s)',
          style: TextStyle(fontSize: 10, color: context.ac.textTertiary)),
    ]);
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
                          ? 'Block popups Aurora didn\'t expect. Turn off to allow sites to open popups.'
                          : 'Let sites open popups when you tap a link. Turn on to block unexpected ones.',
                      style: TextStyle(fontSize: 12, color: context.ac.textSecondary)),
                  value: local.popupBlockingEnabled,
                  onChanged: (v) {
                    setLocal(() => local = local.copyWith(popupBlockingEnabled: v));
                    _update(local);
                  },
                  contentPadding: EdgeInsets.zero),
              SwitchListTile(
                  title: const Text('Block invisible redirects'),
                  subtitle: Text(
                      local.invisibleRedirectBlockingEnabled
                          ? 'Intercept redirects and ask before navigating. Use this to avoid being sent to unexpected pages.'
                          : 'Let redirects navigate without asking. Turn on if a site keeps sending you away.',
                      style: TextStyle(fontSize: 12, color: context.ac.textSecondary)),
                  value: local.invisibleRedirectBlockingEnabled,
                  onChanged: (v) {
                    setLocal(() => local = local.copyWith(invisibleRedirectBlockingEnabled: v));
                    _update(local);
                  },
                  contentPadding: EdgeInsets.zero),
              // Tracker blocking (Pro-gated)
              SwitchListTile(
                  title: const Text('Block trackers (Pro)'),
                  subtitle: Text(
                      local.trackerBlockingEnabled
                          ? 'Block known tracker domains and analytics scripts. '
                              'Requires Aurora Pro.'
                          : 'Block known tracker domains. Pro feature.',
                      style: TextStyle(fontSize: 12, color: context.ac.textSecondary)),
                  value: local.trackerBlockingEnabled,
                  onChanged: (v) {
                    if (v && !widget.proEntitlement.isPro) {
                      showProUpsell(context, ProFeature.trackerPack);
                      return;
                    }
                    setLocal(() => local = local.copyWith(trackerBlockingEnabled: v));
                    _update(local);
                  },
                  contentPadding: EdgeInsets.zero),
              ListTile(
                title: const Text('Per-site allowlist'),
                subtitle: Text(
                    local.adblockAllowlist.isEmpty
                        ? 'No sites are allowlisted. Tap the shield in the browser toolbar to allowlist a site.'
                        : '${local.adblockAllowlist.length} site${local.adblockAllowlist.length == 1 ? "" : "s"} allowlisted',
                    style: TextStyle(fontSize: 12, color: context.ac.textSecondary)),
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
                      style: TextStyle(fontWeight: FontWeight.w600, color: context.ac.textPrimary)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          final isPro = widget.proEntitlement.isPro;
                          final totalCount = local.adblockFilterSources.length;
                          if (!isPro &&
                              totalCount > ProFeatures.freeFilterListSlots) {
                            showProUpsell(context, ProFeature.extraFilterLists);
                            return;
                          }
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
              ..._buildAdblockSourceTiles(local, setLocal, widget.proEntitlement.isPro),
              const SizedBox(height: 12),
              TextField(
                  controller: widget.adblockSourceController,
                  decoration: InputDecoration(
                    hintText: widget.proEntitlement.isPro
                        ? 'Add custom filter URL'
                        : 'Custom filter URLs (Pro only)',
                    suffixIcon: IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () {
                          if (!widget.proEntitlement.isPro) {
                            showProUpsell(context, ProFeature.customFilterListUrl);
                            return;
                          }
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
                  'Custom rules: ${local.manualAdBlockRules.length} network filters, '
                  '${local.manualCosmeticRules.length} cosmetic filters',
                  style: TextStyle(fontSize: 12, color: context.ac.textSecondary)),
            ])),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildAdblockSourceTiles(
      DownloadSettings local, void Function(void Function()) setLocal, bool isPro) {
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
              if (v == true && !isPro) {
                // User is enabling a new source — count enabled.
                final enabledCount = local.adblockFilterSources
                    .where((s) => s.enabled)
                    .length;
                if (enabledCount >= ProFeatures.freeFilterListSlots &&
                    !source.enabled) {
                  // Would exceed free cap.
                  showProUpsell(context, ProFeature.extraFilterLists);
                  return;
                }
              }
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
    var localReplacePlayer = _settings.replaceSitePlayer;
    return Scaffold(
      appBar: AppBar(title: const Text('Media Sniffer')),
      body: StatefulBuilder(
        builder: (context, setLocal) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PanelHeader(icon: Icons.play_circle_outline_rounded, title: 'In-app player'),
            const SizedBox(height: 8),
            Panel(
              child: SwitchListTile(
                title: const Text('Replace site player with Aurora'),
                subtitle: Text(
                  localReplacePlayer
                      ? 'When a page plays video or audio, Aurora opens its own player with the page session (cookies). Turn off to use the site\'s player.'
                      : 'Site players run normally. Turn on to auto-open Aurora\'s player (like UC Browser) with cookies and headers.',
                  style: TextStyle(fontSize: 12, color: context.ac.textSecondary),
                ),
                value: localReplacePlayer,
                onChanged: (v) {
                  setLocal(() => localReplacePlayer = v);
                  _update(_settings.copyWith(replaceSitePlayer: v));
                },
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 16),
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
      proEntitlement: widget.proEntitlement,
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
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('In-app snackbar alerts'),
                subtitle: const Text(
                  'Show slide-up alerts for queue events. Use this when you want to glance at progress without leaving the browser.',
                ),
                value: _settings.showSnackbars,
                onChanged: (v) {
                  setLocal(() {});
                  _update(_settings.copyWith(showSnackbars: v));
                },
                contentPadding: EdgeInsets.zero,
              ),
            ])),
            const SizedBox(height: 20),
            PanelHeader(
              icon: Icons.view_carousel_outlined,
              title: 'Bottom dock',
            ),
            const SizedBox(height: 8),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Drag to reorder icons on each dock slide. '
                    'Add or remove actions (up to $kMaxDockItemsPerSlide per slide). '
                    'Swipe the browser dock left/right to switch slides.',
                    style: TextStyle(
                      fontSize: 13,
                      color: context.ac.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const _DockReorderEditor(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkPage() {
    var localProxyType = _settings.proxyType;
    var localProxyHost = _settings.proxyHost;
    var localProxyPort = _settings.proxyPort;
    var localProxyUser = _settings.proxyUsername;
    var localProxyPass = _settings.proxyPassword;
    var localUaProfile = _settings.userAgentProfile;
    // Mutable copy of per-site UA overrides for the list editor.
    final localSiteUas = Map<String, String>.from(_settings.siteUserAgents);

    return Scaffold(
      appBar: AppBar(title: const Text('Network')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Proxy section ──
          PanelHeader(icon: Icons.wifi_rounded, title: 'Proxy'),
          const SizedBox(height: 8),
          Panel(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<ProxyType>(
                value: localProxyType,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Proxy type',
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(
                    value: ProxyType.none,
                    child: Text('None'),
                  ),
                  const DropdownMenuItem(
                    value: ProxyType.http,
                    child: Text('HTTP / HTTPS'),
                  ),
                  const DropdownMenuItem(
                    value: ProxyType.socks5,
                    child: Text('SOCKS5'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null && v != ProxyType.none &&
                      !widget.proEntitlement.isPro) {
                    showProUpsell(context, ProFeature.proxy);
                    return;
                  }
                  localProxyType = v ?? ProxyType.none;
                  _update(_settings.copyWith(
                    proxyType: localProxyType,
                  ));
                },
              ),
              if (localProxyType != ProxyType.none) ...[
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: localProxyHost,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    hintText: '192.168.1.1 or proxy.example.com',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    localProxyHost = v;
                    _update(_settings.copyWith(
                      proxyType: localProxyType,
                      proxyHost: localProxyHost,
                    ));
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: localProxyPort.toString(),
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    hintText: '8080',
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    localProxyPort = int.tryParse(v) ?? 0;
                    _update(_settings.copyWith(
                      proxyType: localProxyType,
                      proxyHost: localProxyHost,
                      proxyPort: localProxyPort,
                    ));
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: localProxyUser,
                  decoration: const InputDecoration(
                    labelText: 'Username (optional)',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    localProxyUser = v;
                    _update(_settings.copyWith(
                      proxyType: localProxyType,
                      proxyHost: localProxyHost,
                      proxyPort: localProxyPort,
                      proxyUsername: localProxyUser,
                      proxyPassword: localProxyPass,
                    ));
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: localProxyPass,
                  decoration: const InputDecoration(
                    labelText: 'Password (optional)',
                    isDense: true,
                  ),
                  obscureText: true,
                  onChanged: (v) {
                    localProxyPass = v;
                    _update(_settings.copyWith(
                      proxyType: localProxyType,
                      proxyHost: localProxyHost,
                      proxyPort: localProxyPort,
                      proxyUsername: localProxyUser,
                      proxyPassword: localProxyPass,
                    ));
                  },
                ),
              ],
            ],
          )),
          const SizedBox(height: 24),

          // ── User-Agent section ──
          PanelHeader(icon: Icons.devices_rounded, title: 'User-Agent'),
          const SizedBox(height: 8),
          Panel(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                value: localUaProfile,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Global User-Agent profile',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 'mobile', child: Text('Mobile (default)')),
                  DropdownMenuItem(value: 'desktop_chrome', child: Text('Desktop Chrome')),
                  DropdownMenuItem(value: 'desktop_firefox', child: Text('Desktop Firefox')),
                  DropdownMenuItem(value: 'safari', child: Text('Safari')),
                ],
                onChanged: (v) {
                  localUaProfile = v ?? 'mobile';
                  _update(_settings.copyWith(
                    userAgentProfile: localUaProfile,
                  ));
                },
              ),
              const SizedBox(height: 16),
              // Per-site UA overrides — Pro feature
              _buildPerSiteUaSection(localSiteUas),
            ],
          )),
        ],
      ),
    );
  }

  Widget _buildPerSiteUaSection(Map<String, String> localSiteUas) {
    final isPro = widget.proEntitlement.isPro;
    if (!isPro) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Per-site browser identity overrides',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.ac.textTertiary)),
          const SizedBox(height: 6),
          ListTile(
            leading: Icon(Icons.lock_outline,
                size: 18, color: context.ac.textTertiary),
            title: Text('Per-site User‑Agent (Pro)',
                style: TextStyle(
                    fontSize: 13, color: context.ac.textSecondary)),
            subtitle: Text(
                'Set different browser identities per site',
                style: TextStyle(
                    fontSize: 12, color: context.ac.textTertiary)),
            dense: true,
            contentPadding: EdgeInsets.zero,
            onTap: () => showProUpsell(context, ProFeature.perSiteUA),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Per-site browser identity overrides',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.ac.accentFrost)),
        const SizedBox(height: 8),
        if (localSiteUas.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
                'No site-specific overrides yet. '
                    'Tap "Add override" to create one.',
                style: TextStyle(
                    fontSize: 13, color: context.ac.textSecondary)),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: localSiteUas.entries.length,
            itemBuilder: (context, index) {
              final entry = localSiteUas.entries.elementAt(index);
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(entry.key,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              color: context.ac.textPrimary)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 2,
                      child: Text(': ${entry.value}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: context.ac.textSecondary)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 28, minHeight: 28),
                      onPressed: () {
                        localSiteUas.remove(entry.key);
                        _update(_settings.copyWith(
                          siteUserAgents:
                              Map<String, String>.from(localSiteUas),
                        ));
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: 8),
        TextButton.icon(
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add override'),
          onPressed: () => _showAddSiteUaDialog(localSiteUas),
        ),
      ],
    );
  }

  void _showAddSiteUaDialog(Map<String, String> currentOverrides) {
    var host = '';
    var profile = 'mobile';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add browser identity override'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(labelText: 'Host (e.g. example.com)'),
              onChanged: (v) => host = v.trim(),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: profile,
              decoration: const InputDecoration(
                labelText: 'User-Agent',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'mobile', child: Text('Mobile')),
                DropdownMenuItem(value: 'desktop_chrome', child: Text('Desktop Chrome')),
                DropdownMenuItem(value: 'desktop_firefox', child: Text('Desktop Firefox')),
                DropdownMenuItem(value: 'safari', child: Text('Safari')),
              ],
              onChanged: (v) => profile = v ?? 'mobile',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (host.isEmpty) return;
              currentOverrides[host] = profile;
              _update(_settings.copyWith(
                siteUserAgents: Map<String, String>.from(currentOverrides),
              ));
              Navigator.of(ctx).pop();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Profiles page
  // ---------------------------------------------------------------------------

  Widget _buildProfilesPage() {
    return ListenableBuilder(
      listenable: widget.proEntitlement,
      builder: (context, _) {
        if (!widget.proEntitlement.isPro) {
          return _buildProfilesLockedPage();
        }
        return _ProfilesPageContent(proEntitlement: widget.proEntitlement);
      },
    );
  }

  Widget _buildProfilesLockedPage() {
    return Scaffold(
      appBar: AppBar(title: const Text('Profiles')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.people_outline,
                  size: 64, color: context.ac.textTertiary),
              const SizedBox(height: 16),
              Text('Per-site Profiles',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: context.ac.textPrimary)),
              const SizedBox(height: 8),
              Text(
                'Create custom browser and download settings for '
                'individual sites. This is a Pro feature.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, color: context.ac.textSecondary),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Unlock with Pro'),
                onPressed: () =>
                    showProUpsell(context, ProFeature.siteProfiles),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSchedulePage() {
    return ListenableBuilder(
      listenable: widget.proEntitlement,
      builder: (context, _) {
        if (!widget.proEntitlement.isPro) {
          return _buildScheduleLockedPage();
        }
        return _SchedulePageContent(downloadQueue: widget.downloadQueue);
      },
    );
  }

  Widget _buildScheduleLockedPage() {
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.schedule,
                  size: 64, color: context.ac.textTertiary),
              const SizedBox(height: 16),
              Text('Scheduled Downloads',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: context.ac.textPrimary)),
              const SizedBox(height: 8),
              Text(
                'Schedule downloads to start later — perfect for '
                'night-time queuing. This is a Pro feature.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, color: context.ac.textSecondary),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Unlock with Pro'),
                onPressed: () =>
                    showProUpsell(context, ProFeature.scheduledDownloads),
              ),
            ],
          ),
        ),
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
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: context.ac.textPrimary)),
              const SizedBox(height: 4),
              Text('v1.1.9', style: TextStyle(fontSize: 13, color: context.ac.textSecondary)),
              const SizedBox(height: 16),
              Text('Android download manager with segmented downloads, streaming video, torrents, in-browser media detection, and Google Drive sync.',
                  style: TextStyle(fontSize: 13, color: context.ac.textSecondary)),
              const SizedBox(height: 24),
              Text('Built with Flutter and the Nord color palette.',
                  style: TextStyle(fontSize: 12, color: context.ac.textTertiary)),
            ],
          )),
          const SizedBox(height: 16),
          Panel(child: Column(
            children: [
              const BatteryOptimizationTile(),
              const Divider(height: 1, indent: 56),
              SwitchListTile(
                secondary: Icon(Icons.power_settings_new_rounded, color: context.ac.accentFrost),
                title: const Text('Check battery optimization on launch'),
                subtitle: const Text('Notify if background download optimizations are not configured'),
                value: !_settings.neverAskBatteryOpt,
                onChanged: (val) {
                  _update(_settings.copyWith(
                    neverAskBatteryOpt: !val,
                  ));
                },
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: Icon(Icons.monitor_heart_outlined, color: context.ac.accentFrost),
                title: const Text('Diagnostics'),
                subtitle: const Text('View, filter, and export app logs'),
                trailing: Icon(Icons.chevron_right, color: context.ac.textSecondary),
                onTap: () => _openPage(const DiagnosticsPage()),
              ),
            ],
          )),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Aurora Pro page
  // ---------------------------------------------------------------------------

  Widget _buildProPage() {
    return Scaffold(
      appBar: AppBar(title: const Text('Aurora Pro')),
      body: ListenableBuilder(
        listenable: widget.proEntitlement,
        builder: (context, _) {
          final isPro = widget.proEntitlement.isPro;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Status header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: isPro
                      ? context.ac.statusSuccess.withOpacity(0.12)
                      : context.ac.accentFrost.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isPro
                        ? context.ac.statusSuccess.withOpacity(0.3)
                        : context.ac.accentFrost.withOpacity(0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isPro ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                      color: isPro ? context.ac.statusSuccess : context.ac.accentFrost,
                      size: 36,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isPro ? 'Aurora Pro — Active' : 'Aurora Pro',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: context.ac.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isPro
                                ? 'All premium features are unlocked.'
                                : 'Unlock premium features with a one-time purchase.',
                            style: TextStyle(
                              fontSize: 13,
                              color: context.ac.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Feature comparison
              PanelHeader(icon: Icons.list_alt, title: 'Features'),
              const SizedBox(height: 8),
              Panel(
                child: Column(
                  children: _buildFeatureRows(isPro),
                ),
              ),

              // Debug toggle (only in debug/profile builds)
              if (!kReleaseMode) ...[
                const SizedBox(height: 20),
                PanelHeader(
                    icon: Icons.bug_report_outlined, title: 'Debug'),
                const SizedBox(height: 8),
                Panel(
                  child: SwitchListTile(
                    secondary: Icon(
                      Icons.developer_mode,
                      color: context.ac.accentFrost,
                    ),
                    title: const Text('Debug: Force Pro'),
                    subtitle: const Text(
                        'Treat this device as Pro (resets on restart)'),
                    value: widget.proEntitlement.isPro,
                    onChanged: (val) {
                      widget.proEntitlement.setDebugPro(val);
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],

              // Buy / restore (Play channel only for real purchases)
              if (!isPro) ...[
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _onGetProPressed(context),
                    icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                    label: Text(
                      BuildChannel.isPlay
                          ? (widget.playBilling?.localizedPrice != null
                              ? 'Get Aurora Pro — ${widget.playBilling!.localizedPrice}'
                              : 'Get Aurora Pro')
                          : 'Get Aurora Pro on Google Play',
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (BuildChannel.isPlay) ...[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: () => _onRestoreProPressed(context),
                      child: Text(
                        'Restore purchase',
                        style: TextStyle(
                          fontSize: 13,
                          color: context.ac.accentFrost,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    BuildChannel.isPlay
                        ? 'One-time purchase via Google Play — no subscription.'
                        : 'Pro unlock is sold only in the Google Play edition. '
                            'This build has no external checkout.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.ac.textTertiary,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _onGetProPressed(BuildContext context) async {
    final billing = widget.playBilling;
    if (!BuildChannel.isPlay || billing == null) {
      if (!context.mounted) return;
      AuroraSnackbar.show(
        context,
        'Aurora Pro is available as a one-time unlock in the Google Play edition of this app.',
      );
      return;
    }
    final ok = await billing.buyPro();
    if (!context.mounted) return;
    if (!ok) {
      AuroraSnackbar.show(
        context,
        billing.lastError ?? 'Could not start purchase.',
      );
    }
  }

  Future<void> _onRestoreProPressed(BuildContext context) async {
    final billing = widget.playBilling;
    if (!BuildChannel.isPlay || billing == null) return;
    await billing.restorePurchases();
    if (!context.mounted) return;
    if (widget.proEntitlement.isPro) {
      AuroraSnackbar.show(context, 'Aurora Pro restored.');
    } else {
      AuroraSnackbar.show(
        context,
        billing.lastError ?? 'No previous Pro purchase found for this account.',
      );
    }
  }

  List<Widget> _buildFeatureRows(bool isPro) {
    final features = [
      (ProFeature.extraFilterLists, 'Extra filter lists', '2 free'),
      (ProFeature.trackerPack, 'Tracker blocking pack', 'Pro only'),
      (ProFeature.higherConcurrency, 'Concurrent downloads',
          '${ProFeatures.maxConcurrentFree} free / ${ProFeatures.maxConcurrentPro} Pro'),
      (ProFeature.higherChunks, 'Chunks per task',
          '${ProFeatures.chunksPerTaskFree} free / ${ProFeatures.chunksPerTaskPro} Pro'),
      (ProFeature.unlimitedTabGroups, 'Tab groups',
          '${ProFeatures.maxFreeTabGroups} free / unlimited Pro'),
      (ProFeature.autoHostGroups, 'Auto-host groups', 'Pro only'),
      (ProFeature.unlimitedCosmeticRules, 'Cosmetic rules',
          '${ProFeatures.maxFreeCosmeticRules} free / unlimited Pro'),
      (ProFeature.driveSync, 'Google Drive sync', 'Pro only'),
      (ProFeature.scheduledAutoBackup, 'Scheduled auto-backup', 'Pro only'),
      (ProFeature.proxy, 'HTTP/SOCKS5 proxy', 'Pro only'),
      (ProFeature.wifiOnly, 'Wi‑Fi only & advanced stall', 'Pro only'),
      (ProFeature.perSiteUA, 'Per-site User‑Agent', 'Pro only'),
    ];

    final widgets = <Widget>[];
    for (int i = 0; i < features.length; i++) {
      final (feature, name, detail) = features[i];
      final allowed = ProFeatures.allows(feature, isPro);
      widgets.add(
        ListTile(
          leading: Icon(
            allowed ? Icons.check_circle : Icons.lock_outline,
            color: allowed
                ? context.ac.statusSuccess
                : context.ac.textTertiary,
            size: 20,
          ),
          title: Text(
            name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: context.ac.textPrimary,
            ),
          ),
          trailing: Text(
            detail,
            style: TextStyle(
              fontSize: 11,
              color: allowed
                  ? context.ac.statusSuccess
                  : context.ac.textTertiary,
            ),
          ),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      );
      if (i < features.length - 1) {
        widgets.add(
          Divider(height: 1, indent: 40, color: context.ac.glassBorder),
        );
      }
    }
    return widgets;
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
        color: context.ac.glassSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.ac.glassBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<DownloadLinkBehavior>(
          value: local.downloadLinkBehavior,
          isExpanded: true,
          icon: Icon(Icons.expand_more, color: context.ac.textSecondary),
          items: const [
            DropdownMenuItem(
              value: DownloadLinkBehavior.capture,
              child: Text('Save to tray. Aurora keeps a list so you can pick which to download later.'),
            ),
            DropdownMenuItem(
              value: DownloadLinkBehavior.autoDownload,
              child: Text('Download right away. Skip the tray and start fetching immediately.'),
            ),
            DropdownMenuItem(
              value: DownloadLinkBehavior.ask,
              child: Text('Ask each time Aurora spots media. Best when you download a mix of stuff.'),
            ),
            DropdownMenuItem(
              value: DownloadLinkBehavior.block,
              child: Text('Block downloads from this site. Aurora will ignore every media URL.'),
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
              color: context.ac.textPrimary)),
    );
  }

  Widget _slider(double value, double min, double max, int divisions,
      String label, ValueChanged<double> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SliderTheme(
          data: SliderThemeData(
              activeTrackColor: context.ac.accentFrost,
              inactiveTrackColor: context.ac.surfaceElevated,
              thumbColor: context.ac.accentFrost,
              overlayColor: context.ac.accentFrost.withValues(alpha: 0.14)),
          child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: label,
              onChanged: onChanged)),
      Text(label,
          style: TextStyle(
              fontSize: 12,
              color: context.ac.accentFrost,
              fontFamily: 'JetBrainsMono')),
    ]);
  }

  Widget _buildBackupPage() {
    return BackupPage(
      downloadQueue: widget.downloadQueue,
      settings: _settings,
      onSettingsChanged: _update,
      libraryUpdateNotifier: widget.libraryUpdateNotifier,
      autoBackupService: widget.autoBackupService,
      proEntitlement: widget.proEntitlement,
    );
  }

  Widget _buildRulesPage() {
    return _RulesPage(proEntitlement: widget.proEntitlement);
  }
}

/// One row in the Settings hub navigation list.
class _NavItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });
}

/// Detail page for Drive Sync settings with live state subscription.
class _DriveSyncPageContent extends StatefulWidget {
  final DriveSyncService driveSyncService;
  final TextEditingController folderController;
  final DriveSyncState initialState;
  final bool initialConnected;
  final ProEntitlement proEntitlement;

  const _DriveSyncPageContent({
    required this.driveSyncService,
    required this.folderController,
    required this.initialState,
    required this.initialConnected,
    required this.proEntitlement,
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
                      : !widget.proEntitlement.isPro
                          ? () => showProUpsell(context, ProFeature.driveSync)
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
                                color: context.ac.accentFrost, fontSize: 13)),
                        if (_state.errorMessage != null) ...[
                          const SizedBox(height: 8),
                          Text(_state.errorMessage!,
                              style: TextStyle(
                                  color: context.ac.statusError,
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
                              child: const Text('Set folder')),
                        ]),
                        const SizedBox(height: 12),
                        SwitchListTile(
                            title: const Text('Auto upload completed files'),
                            value: _state.autoSyncEnabled,
                            onChanged: (v) {
                              if (v && !widget.proEntitlement.isPro) {
                                showProUpsell(context, ProFeature.driveSync);
                              } else {
                                widget.driveSyncService.setAutoSyncEnabled(v);
                              }
                            },
                            contentPadding: EdgeInsets.zero),
                      ],
                    )
                  : Column(children: [
                      Text('Link Google Drive to auto-upload completed downloads.',
                          style: TextStyle(
                              color: context.ac.textSecondary, fontSize: 13)),
                      const SizedBox(height: 16),
                          SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                  icon: const Icon(Icons.link),
                                  label: const Text('Link Google Drive'),
                                  onPressed: () {
                                    if (!widget.proEntitlement.isPro) {
                                      showProUpsell(context, ProFeature.driveSync);
                                    } else {
                                      widget.driveSyncService.connect();
                                    }
                                  })),
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
  final AutoBackupService autoBackupService;
  final ProEntitlement proEntitlement;

  const BackupPage({
    super.key,
    required this.downloadQueue,
    required this.settings,
    required this.onSettingsChanged,
    required this.libraryUpdateNotifier,
    required this.autoBackupService,
    required this.proEntitlement,
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

  List<Map<String, dynamic>> _localBackups = [];

  @override
  void initState() {
    super.initState();
    _loadLibrary();
    _loadLocalBackups();
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

  Future<void> _loadLocalBackups() async {
    try {
      final root = DownloadSettings.mediaStoreRelativeFromDisplay(
        widget.settings.downloadDestination,
      );
      // Primary + legacy roots so old backups remain restorable.
      final primary = await PublicDownloadsService.listBackupFiles(
        relativePath: '$root/Backup',
      );
      final legacyDefault = await PublicDownloadsService.listBackupFiles(
        relativePath: 'Download/Aurora Downloader/Backup',
      );
      final legacyOldName = await PublicDownloadsService.listBackupFiles(
        relativePath: 'Download/Aurora Downloads/Backups',
      );
      final seen = <String>{};
      final files = <Map<String, dynamic>>[];
      for (final item in [...primary, ...legacyDefault, ...legacyOldName]) {
        final key = (item['uri'] ?? item['displayName'] ?? item).toString();
        if (seen.add(key)) files.add(item);
      }
      if (mounted) {
        setState(() {
          _localBackups = files;
        });
      }
    } catch (_) {}
  }

  void _showSnack(String message) {
    AuroraSnackbar.show(
      context,
      message,
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

      final root = DownloadSettings.mediaStoreRelativeFromDisplay(
        widget.settings.downloadDestination,
      );
      // Public folder: Downloads/<your folder>/Backup/
      await const MethodChannel('aurora_downloader/public_downloads')
          .invokeMapMethod<String, Object?>('publishFile', {
        'sourcePath': file.path,
        'displayName': p.basename(file.path),
        'mimeType': 'application/json',
        'relativePath': '$root/Backup',
      });

      // Delete the private temporary file
      try {
        await file.delete();
      } catch (_) {}

      final now = DateTime.now().millisecondsSinceEpoch;
      widget.onSettingsChanged(widget.settings.copyWith(lastBackupTimestamp: now));

      await _loadLocalBackups();
      _showSnack('Done \u2014 backup saved as ${p.basename(file.path)}');
    } catch (error) {
      _showSnack('Couldn\'t export backup. $error. Check storage and try again.');
    }
  }

  Future<void> _importBackup({String? filePath}) async {
    try {
      final actualPath = filePath ?? await PublicDownloadsService.pickImportFile();
      if (actualPath == null) return;

      final Map<String, dynamic> decoded;
      if (actualPath.toLowerCase().endsWith('.1dmbak')) {
        decoded = await IdmBackupParser.parse(actualPath);
      } else {
        decoded = await const BrowserLibraryStore().readImportMap(actualPath);
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
                      Row(
                        children: [
                          Icon(
                            Icons.file_download_outlined,
                            color: context.ac.accentFrost,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Import from backup',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: context.ac.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text('Favorites / Bookmarks', style: TextStyle(color: context.ac.textPrimary)),
                        value: importFavorites,
                        onChanged: (hasFavorites || isLegacy)
                            ? (val) => setModalState(() => importFavorites = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text('Web History', style: TextStyle(color: context.ac.textPrimary)),
                        value: importHistory,
                        onChanged: (hasHistory || isLegacy)
                            ? (val) => setModalState(() => importHistory = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text('Saved Pages', style: TextStyle(color: context.ac.textPrimary)),
                        value: importSavedPages,
                        onChanged: (hasSavedPages || isLegacy)
                            ? (val) => setModalState(() => importSavedPages = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text('Download History (Queue)', style: TextStyle(color: context.ac.textPrimary)),
                        value: importQueue,
                        onChanged: hasQueue
                            ? (val) => setModalState(() => importQueue = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text('App Settings', style: TextStyle(color: context.ac.textPrimary)),
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
                            child: Text('Cancel', style: TextStyle(color: context.ac.textSecondary)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: context.ac.accentFrost,
                              foregroundColor: context.ac.surfaceField,
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
      final downloadsTmpDir = Directory('$baseDir/downloads_tmp');
      if (!await downloadsTmpDir.exists()) {
        await downloadsTmpDir.create(recursive: true);
      }
      final baseTemp = downloadsTmpDir.path;
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

              taskMap['isBackupImport'] = true;
              final task = DownloadTask.fromJson(taskMap);
              if (task.state != DownloadState.completed) {
                task.state = DownloadState.paused;
              }
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

        final folderMap = {for (final f in updatedLibrary.folders) f.id: f};
        for (final f in importedFolders) {
          if (!folderMap.containsKey(f.id)) {
            folderMap[f.id] = f;
          }
        }
        final mergedFolders = folderMap.values.toList();
        final known = {for (final folder in mergedFolders) folder.id};

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

        final favMap = {for (final f in updatedLibrary.favorites) f.url: f};
        var addedFavoritesCount = 0;
        for (final f in importedFavorites) {
          if (!favMap.containsKey(f.url)) {
            favMap[f.url] = f;
            addedFavoritesCount++;
          }
        }
        final mergedFavorites = favMap.values.toList();

        updatedLibrary = updatedLibrary.copyWith(
          favorites: mergedFavorites,
          folders: mergedFolders,
        );
        importedFavoritesCount = addedFavoritesCount;
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

        final historyMap = {for (final h in updatedLibrary.history) h.url: h};
        var addedHistoryCount = 0;
        for (final h in importedHistory) {
          final existing = historyMap[h.url];
          if (existing == null) {
            historyMap[h.url] = h;
            addedHistoryCount++;
          } else if (h.visitedAt.isAfter(existing.visitedAt)) {
            historyMap[h.url] = h;
          }
        }
        final mergedHistory = historyMap.values.toList();

        updatedLibrary = updatedLibrary.copyWith(history: mergedHistory);
        importedHistoryCount = addedHistoryCount;
      }

      // 5. Browser Library - Saved Pages
      if (importSavedPages && decoded.containsKey('savedPages')) {
        final importedSavedPages = (decoded['savedPages'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => SavedPage.fromJson(Map<String, dynamic>.from(item)))
            .toList();

        final savedPagesMap = {for (final p in updatedLibrary.savedPages) p.sourceUrl: p};
        var addedSavedPagesCount = 0;
        for (final p in importedSavedPages) {
          if (!savedPagesMap.containsKey(p.sourceUrl)) {
            savedPagesMap[p.sourceUrl] = p;
            addedSavedPagesCount++;
          }
        }
        final mergedSavedPages = savedPagesMap.values.toList();

        updatedLibrary = updatedLibrary.copyWith(
          savedPages: mergedSavedPages,
        );
        importedSavedPagesCount = addedSavedPagesCount;
      }

      if (importFavorites || importHistory || importSavedPages) {
        if (!decoded.containsKey('favorites') &&
            !decoded.containsKey('history') &&
            !decoded.containsKey('savedPages')) {
          final legacyLib = BrowserLibrary.fromJson(decoded);

          List<BrowserFavorite>? mergedFavs;
          List<BookmarkFolder>? mergedFolders;
          List<BrowserHistoryEntry>? mergedHist;
          List<SavedPage>? mergedSaved;

          if (importFavorites) {
            final folderMap = {for (final f in updatedLibrary.folders) f.id: f};
            for (final f in legacyLib.folders) {
              if (!folderMap.containsKey(f.id)) {
                folderMap[f.id] = f;
              }
            }
            mergedFolders = folderMap.values.toList();
            final known = {for (final folder in mergedFolders) folder.id};

            final favMap = {for (final f in updatedLibrary.favorites) f.url: f};
            var addedFavoritesCount = 0;
            for (final f in legacyLib.favorites) {
              if (!favMap.containsKey(f.url)) {
                final cleaned = f.folderId != null && !known.contains(f.folderId)
                    ? f.copyWith(clearFolder: true)
                    : f;
                favMap[f.url] = cleaned;
                addedFavoritesCount++;
              }
            }
            mergedFavs = favMap.values.toList();
            importedFavoritesCount = addedFavoritesCount;
          }

          if (importHistory) {
            final historyMap = {for (final h in updatedLibrary.history) h.url: h};
            var addedHistoryCount = 0;
            for (final h in legacyLib.history) {
              final existing = historyMap[h.url];
              if (existing == null) {
                historyMap[h.url] = h;
                addedHistoryCount++;
              } else if (h.visitedAt.isAfter(existing.visitedAt)) {
                historyMap[h.url] = h;
              }
            }
            mergedHist = historyMap.values.toList();
            importedHistoryCount = addedHistoryCount;
          }

          if (importSavedPages) {
            final savedPagesMap = {for (final p in updatedLibrary.savedPages) p.sourceUrl: p};
            var addedSavedPagesCount = 0;
            for (final p in legacyLib.savedPages) {
              if (!savedPagesMap.containsKey(p.sourceUrl)) {
                savedPagesMap[p.sourceUrl] = p;
                addedSavedPagesCount++;
              }
            }
            mergedSaved = savedPagesMap.values.toList();
            importedSavedPagesCount = addedSavedPagesCount;
          }

          updatedLibrary = updatedLibrary.copyWith(
            favorites: mergedFavs,
            folders: mergedFolders,
            history: mergedHist,
            savedPages: mergedSaved,
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
        _showSnack('Done \u2014 import completed. No new items found.');
      } else {
        _showSnack('Done \u2014 imported ${summary.join(", ")}.');
      }

      widget.libraryUpdateNotifier.value++;
      await _loadLibrary();
    } catch (error) {
      _showSnack('Couldn\'t import backup. $error. Make sure the file is a valid backup.');
    }
  }

  Future<void> _deleteBackup(String uri) async {
    try {
      await PublicDownloadsService.deleteBackupFile(uri);
      await _loadLocalBackups();
      _showSnack('Done \u2014 backup deleted.');
    } catch (e) {
      _showSnack('Couldn\'t delete backup. $e. Try again.');
    }
  }

  Future<void> _shareBackup(String uri, String displayName) async {
    try {
      final tempPath = await PublicDownloadsService.readBackupFile(uri);
      if (tempPath != null) {
        final file = File(tempPath);
        final renamedFile = await file.rename(
          p.join(p.dirname(tempPath), displayName),
        );
        await PublicDownloadsService.shareFile(renamedFile.path);
        try {
          await renamedFile.delete();
        } catch (_) {}
      }
    } catch (e) {
      _showSnack('Couldn\'t share backup. $e. Try again.');
    }
  }

  Future<void> _importLocalBackup(String uri) async {
    try {
      final tempPath = await PublicDownloadsService.readBackupFile(uri);
      if (tempPath != null) {
        await _importBackup(filePath: tempPath);
        try {
          await File(tempPath).delete();
        } catch (_) {}
      }
    } catch (error) {
      _showSnack('Couldn\'t restore backup. $error. The file may be corrupted.');
    }
  }

  String _formatDateTime(int timestamp) {
    if (timestamp == 0) return 'Never';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}';
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
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
                        Text(
                          'Export your data',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.ac.textPrimary),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Pick what to include in the backup file:',
                          style: TextStyle(fontSize: 12, color: context.ac.textSecondary),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          activeColor: context.ac.accentFrost,
                          title: Text('Favorites / Bookmarks', style: TextStyle(color: context.ac.textPrimary, fontSize: 13)),
                          subtitle: Text(
                            '${_library?.favorites.length ?? 0} favorites, ${_library?.folders.length ?? 0} folders',
                            style: TextStyle(color: context.ac.textTertiary, fontSize: 11),
                          ),
                          value: exportFavorites,
                          onChanged: (v) => setState(() => exportFavorites = v),
                        ),
                        SwitchListTile(
                          activeColor: context.ac.accentFrost,
                          title: Text('Web History', style: TextStyle(color: context.ac.textPrimary, fontSize: 13)),
                          subtitle: Text(
                            '${_library?.history.length ?? 0} entries',
                            style: TextStyle(color: context.ac.textTertiary, fontSize: 11),
                          ),
                          value: exportHistory,
                          onChanged: (v) => setState(() => exportHistory = v),
                        ),
                        SwitchListTile(
                          activeColor: context.ac.accentFrost,
                          title: Text('Saved Pages', style: TextStyle(color: context.ac.textPrimary, fontSize: 13)),
                          subtitle: Text(
                            '${_library?.savedPages.length ?? 0} pages',
                            style: TextStyle(color: context.ac.textTertiary, fontSize: 11),
                          ),
                          value: exportSavedPages,
                          onChanged: (v) => setState(() => exportSavedPages = v),
                        ),
                        SwitchListTile(
                          activeColor: context.ac.accentFrost,
                          title: Text('Download History (Queue)', style: TextStyle(color: context.ac.textPrimary, fontSize: 13)),
                          subtitle: Text(
                            '${widget.downloadQueue.allTasks.length} tasks',
                            style: TextStyle(color: context.ac.textTertiary, fontSize: 11),
                          ),
                          value: exportQueue,
                          onChanged: (v) => setState(() => exportQueue = v),
                        ),
                        SwitchListTile(
                          activeColor: context.ac.accentFrost,
                          title: Text('App Settings', style: TextStyle(color: context.ac.textPrimary, fontSize: 13)),
                          subtitle: Text(
                            'Download defaults, search engine, adblock settings, and more',
                            style: TextStyle(color: context.ac.textTertiary, fontSize: 11),
                          ),
                          value: exportSettings,
                          onChanged: (v) => setState(() => exportSettings = v),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Export backup file'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: context.ac.accentFrost,
                            foregroundColor: context.ac.surfaceField,
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
                        Text(
                          'Import your data',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.ac.textPrimary),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Restore bookmarks, history, settings, or downloads from a backup file.',
                          style: TextStyle(fontSize: 12, color: context.ac.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.file_download_outlined),
                          label: const Text('Choose backup file'),
                          onPressed: _importBackup,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  PanelHeader(icon: Icons.schedule_rounded, title: 'Auto Backup'),
                  const SizedBox(height: 8),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          activeColor: context.ac.accentFrost,
                          title: Text('Enable auto backup', style: TextStyle(color: context.ac.textPrimary, fontSize: 13)),
                          subtitle: Text(
                            'Aurora saves your data to your Downloads folder automatically.',
                            style: TextStyle(fontSize: 11, color: context.ac.textSecondary),
                          ),
                          value: widget.settings.autoBackupEnabled,
                          onChanged: (enabled) {
                            if (enabled && !widget.proEntitlement.isPro) {
                              showProUpsell(context, ProFeature.scheduledAutoBackup);
                              return;
                            }
                            setState(() {
                              widget.onSettingsChanged(
                                widget.settings.copyWith(autoBackupEnabled: enabled),
                              );
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<AutoBackupInterval>(
                          value: widget.settings.autoBackupInterval,
                          dropdownColor: context.ac.surfaceElevated,
                          decoration: InputDecoration(
                            labelText: 'Backup frequency',
                            labelStyle: TextStyle(
                              color: widget.proEntitlement.isPro
                                  ? context.ac.textSecondary
                                  : context.ac.textTertiary,
                              fontSize: 12,
                            ),
                          ),
                          items: AutoBackupInterval.values
                              .map((interval) => DropdownMenuItem(
                                    value: interval,
                                    child: Text(interval.label, style: TextStyle(color: context.ac.textPrimary, fontSize: 13)),
                                  ))
                              .toList(),
                          onChanged: widget.proEntitlement.isPro
                              ? (interval) {
                                  if (interval == null) return;
                                  setState(() {
                                    widget.onSettingsChanged(
                                      widget.settings.copyWith(autoBackupInterval: interval),
                                    );
                                  });
                                }
                              : null,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.save_rounded, size: 16),
                                label: const Text('Back up now', style: TextStyle(fontSize: 12)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: context.ac.accentFrost,
                                  foregroundColor: context.ac.surfaceField,
                                ),
                                onPressed: () async {
                                  final result = await widget.autoBackupService.performBackup();
                                  _showSnack(result.message);
                                  await _loadLocalBackups();
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.restore_rounded, size: 16),
                                label: const Text('Restore', style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: context.ac.accentFrost,
                                  side: BorderSide(color: context.ac.accentFrost),
                                ),
                                onPressed: () async {
                                  await _showRestoreDialog();
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Local Backups List Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Local Backups',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: context.ac.textPrimary,
                        ),
                      ),
                      TextButton.icon(
                        icon: Icon(Icons.refresh, size: 16, color: context.ac.accentFrost),
                        label: Text('Scan', style: TextStyle(color: context.ac.accentFrost, fontSize: 12)),
                        onPressed: _loadLocalBackups,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (_localBackups.isEmpty)
                    Card(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
                        alignment: Alignment.center,
                        child: Column(
                          children: [
                            Icon(
                              Icons.folder_open_outlined,
                              size: 40,
                              color: context.ac.textTertiary,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'No backups found yet. Export one first from the panel above.',
                              style: TextStyle(
                                fontSize: 13,
                                color: context.ac.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Column(
                      children: _localBackups.map((item) {
                        final name = item['displayName'] as String? ?? 'backup.json';
                        final isAuto = name.startsWith('aurora_auto_backup_');
                        final timestamp = item['dateModified'] as int? ?? 0;
                        final formattedTime = timestamp > 0 ? _formatDateTime(timestamp) : 'Unknown Date';
                        final size = item['size'] as int? ?? 0;
                        final uri = item['uri'] as String? ?? '';

                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          color: isAuto
                              ? context.ac.surfaceElevated.withOpacity(0.3)
                              : context.ac.surfacePanel,
                          child: ListTile(
                            leading: Icon(
                              isAuto ? Icons.auto_mode_rounded : Icons.backup_rounded,
                              color: isAuto ? Colors.cyanAccent : context.ac.accentFrost,
                            ),
                            title: Text(
                              isAuto ? 'Auto Backup' : 'Manual Backup',
                              style: TextStyle(
                                color: context.ac.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              '$formattedTime • ${_formatFileSize(size)}',
                              style: TextStyle(
                                color: context.ac.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.share_rounded, size: 18, color: context.ac.textSecondary),
                                  onPressed: () => _shareBackup(uri, name),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.settings_backup_restore_rounded, size: 18, color: Colors.green),
                                  onPressed: () => _importLocalBackup(uri),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                                  onPressed: () => _deleteBackup(uri),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
    );
  }

  Future<void> _showRestoreDialog() async {
    final backups = await widget.autoBackupService.listBackups();
    if (!mounted) return;
    if (backups.isEmpty) {
      _showSnack('No backups found.');
      return;
    }
    // Group files by snapshot timestamp.
    final byTimestamp = <String, List<AutoBackupFile>>{};
    for (final file in backups) {
      byTimestamp.putIfAbsent(file.timestamp, () => []).add(file);
    }
    final timestamps = byTimestamp.keys.toList()
      ..sort((a, b) => b.compareTo(a)); // newest first

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore from backup'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: timestamps.length,
            itemBuilder: (_, index) {
              final ts = timestamps[index];
              final count = byTimestamp[ts]!.length;
              return ListTile(
                title: Text(ts.replaceAll('_', ' ')),
                subtitle: Text(count == 1
                    ? '1 consolidated backup file'
                    : '$count files'),
                onTap: () async {
                  Navigator.of(dialogContext).pop();
                  final restored =
                      await widget.autoBackupService.restoreBackup(ts);
                  if (mounted) {
                    setState(() {});
                    _showSnack(restored > 0
                        ? 'Done \u2014 restored $restored files. Restart the app to apply.'
                        : 'Couldn\'t restore backup. It may be corrupted. Try a different snapshot.');
                    await _loadLocalBackups();
                  }
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

class BatteryOptimizationTile extends StatefulWidget {
  const BatteryOptimizationTile({super.key});

  @override
  State<BatteryOptimizationTile> createState() => _BatteryOptimizationTileState();
}

class _BatteryOptimizationTileState extends State<BatteryOptimizationTile> {
  bool? _isExempt;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    final exempt =
        await DownloadForegroundService.isIgnoringBatteryOptimizations();
    if (mounted) {
      setState(() {
        _isExempt = exempt;
      });
    }
  }

  void _showOemGuidanceDialog(String oem) {
    final label = DownloadForegroundService.oemLabel(oem);
    final name = DownloadForegroundService.oemName(oem);
    if (label == null || name == null) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Background downloads on $name'),
        content: Text(
          'Some $name devices also require enabling "$label" for Aurora '
          'to keep downloading in the background.\n\n'
          'Do you want to open the system settings?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              unawaited(DownloadForegroundService.openOemAutostartPage());
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Loading state — check in progress
    if (_isExempt == null) {
      return ListTile(
        leading: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2, color: context.ac.accentFrost),
        ),
        title: const Text('Battery Optimization'),
        subtitle: const Text('Checking status\u2026'),
      );
    }

    if (_isExempt == true) {
      return ListTile(
        leading: Icon(Icons.battery_saver_rounded, color: context.ac.accentFrost),
        title: const Text('Battery Optimization'),
        subtitle: const Text('Aurora is optimized for background downloads'),
        trailing: Icon(Icons.check_circle_outline, color: context.ac.accentFrost),
      );
    }

    return ListTile(
      leading: Icon(Icons.battery_alert_rounded, color: context.ac.accentAmber),
      title: const Text('Allow background downloads'),
      subtitle: const Text('Aurora may pause downloads in the background. Tap to request an exception.'),
      trailing: Icon(Icons.warning_amber_rounded, color: context.ac.accentAmber),
      onTap: () async {
        final oemInfo =
            await DownloadForegroundService.requestBatteryOptimizationExemption();
        // Check again after a delay in case the user approved it
        await Future.delayed(const Duration(seconds: 1));
        await _checkStatus();

        final oem = oemInfo['oem'] as String?;
        if (oem != null && mounted) {
          _showOemGuidanceDialog(oem);
        }
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Download Rules Page
// ---------------------------------------------------------------------------

/// Settings sub-page for managing download rules (Pro feature).
class _RulesPage extends StatefulWidget {
  final ProEntitlement proEntitlement;

  const _RulesPage({required this.proEntitlement});

  @override
  State<_RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<_RulesPage> {
  final DownloadRulesStore _store = const DownloadRulesStore();
  List<DownloadRule> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    final rules = await _store.load();
    if (mounted) {
      setState(() {
        _rules = rules;
        _loading = false;
      });
    }
  }

  Future<void> _saveRules() async {
    await _store.save(_rules);
  }

  void _addRule(DownloadRule rule) {
    setState(() => _rules.add(rule));
    _saveRules();
  }

  void _updateRule(int index, DownloadRule rule) {
    setState(() => _rules[index] = rule);
    _saveRules();
  }

  void _deleteRule(int index) {
    setState(() => _rules.removeAt(index));
    _saveRules();
  }

  String _hostLabel(DownloadRule rule) {
    if (rule.hostPattern == null || rule.hostPattern!.isEmpty) {
      return 'All hosts';
    }
    return rule.hostPattern!;
  }

  String _typeLabel(DownloadRule rule) {
    if (rule.typeFilter == null || rule.typeFilter!.isEmpty) {
      return 'All types';
    }
    return rule.typeFilter!.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final isPro = widget.proEntitlement.isPro;

    if (!isPro) {
      return _buildLockedPage();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Download Rules'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Rule'),
            onPressed: () => _showRuleDialog(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rules.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.rule_rounded,
                            size: 56, color: context.ac.textTertiary),
                        const SizedBox(height: 16),
                        Text(
                          'No download rules yet',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: context.ac.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Rules let you auto-rename files, route downloads '
                          'to custom folders, and set conditions like Wi‑Fi only.',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.ac.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Create your first rule'),
                          onPressed: () => _showRuleDialog(),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _rules.length,
                  itemBuilder: (context, index) {
                    final rule = _rules[index];
                    return _buildRuleCard(rule, index);
                  },
                ),
    );
  }

  Widget _buildLockedPage() {
    return Scaffold(
      appBar: AppBar(title: const Text('Download Rules')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline,
                  size: 56, color: context.ac.textTertiary),
              const SizedBox(height: 16),
              Text(
                'Pro Feature',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.ac.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Download rules let you auto-rename files, organize by host, '
                'and set download conditions like Wi‑Fi or time windows.',
                style: TextStyle(
                  fontSize: 13,
                  color: context.ac.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Unlock with Pro'),
                onPressed: () =>
                    showProUpsell(context, ProFeature.downloadRules),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRuleCard(DownloadRule rule, int index) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _showRuleDialog(rule: rule, index: index),
        onLongPress: () => _confirmDelete(index),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.ac.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _hostLabel(rule),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.ac.accentFrost,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _typeLabel(rule),
                      style: TextStyle(
                        fontSize: 11,
                        color: context.ac.textTertiary,
                      ),
                    ),
                    if (rule.destinationFolder != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        '→ ${rule.destinationFolder}',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.ac.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(
                value: rule.enabled,
                onChanged: (v) {
                  _updateRule(index, rule.copyWith(enabled: v));
                },
                activeColor: context.ac.accentFrost,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRuleDialog({DownloadRule? rule, int? index}) async {
    final isEditing = rule != null;
    final nameController = TextEditingController(text: rule?.name ?? '');
    final hostController =
        TextEditingController(text: rule?.hostPattern ?? '');
    final renameController =
        TextEditingController(text: rule?.renameTemplate ?? '');
    final destController =
        TextEditingController(text: rule?.destinationFolder ?? '');

    var typeVideo = rule?.typeFilter?.contains('video') ?? false;
    var typeAudio = rule?.typeFilter?.contains('audio') ?? false;
    var typeHls = rule?.typeFilter?.contains('hls') ?? false;
    var typeImage = rule?.typeFilter?.contains('image') ?? false;
    var requireWifi = rule?.requireWifi ?? false;
    var requireCharging = rule?.requireCharging ?? false;
    var timeWindowStart = rule?.timeWindowStartHour;
    var timeWindowEnd = rule?.timeWindowEndHour;
    var timeWindowEnabled =
        timeWindowStart != null || timeWindowEnd != null;

    if (timeWindowEnabled) {
      timeWindowStart ??= 0;
      timeWindowEnd ??= 23;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(isEditing ? 'Edit Rule' : 'Add Rule'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Rule name',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: hostController,
                      decoration: const InputDecoration(
                        labelText: 'Host pattern (glob)',
                        hintText: 'e.g. *.example.com',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Match media types',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: context.ac.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        FilterChip(
                          label: const Text('Video'),
                          selected: typeVideo,
                          onSelected: (v) =>
                              setDialogState(() => typeVideo = v),
                        ),
                        FilterChip(
                          label: const Text('Audio'),
                          selected: typeAudio,
                          onSelected: (v) =>
                              setDialogState(() => typeAudio = v),
                        ),
                        FilterChip(
                          label: const Text('HLS'),
                          selected: typeHls,
                          onSelected: (v) =>
                              setDialogState(() => typeHls = v),
                        ),
                        FilterChip(
                          label: const Text('Image'),
                          selected: typeImage,
                          onSelected: (v) =>
                              setDialogState(() => typeImage = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: renameController,
                      decoration: const InputDecoration(
                        labelText: 'Rename template (optional)',
                        hintText: '{host}_{quality}_{title}.{ext}',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tokens: {host} {ext} {quality} {title} {date}',
                      style: TextStyle(
                        fontSize: 10,
                        color: context.ac.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: destController,
                      decoration: const InputDecoration(
                        labelText: 'Destination folder (optional)',
                        hintText: 'e.g. Direct video site',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text('Require Wi‑Fi'),
                      value: requireWifi,
                      onChanged: (v) =>
                          setDialogState(() => requireWifi = v),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    SwitchListTile(
                      title: const Text('Require charging'),
                      value: requireCharging,
                      onChanged: (v) =>
                          setDialogState(() => requireCharging = v),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    SwitchListTile(
                      title: const Text('Time window'),
                      subtitle: timeWindowEnabled
                          ? Text(
                              '$timeWindowStart:00 – $timeWindowEnd:00',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.ac.accentFrost,
                              ),
                            )
                          : null,
                      value: timeWindowEnabled,
                      onChanged: (v) {
                        setDialogState(() {
                          timeWindowEnabled = v;
                          if (v) {
                            timeWindowStart ??= 0;
                            timeWindowEnd ??= 6;
                          } else {
                            timeWindowStart = null;
                            timeWindowEnd = null;
                          }
                        });
                      },
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    if (timeWindowEnabled) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Start hour',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.ac.textSecondary,
                                  ),
                                ),
                                DropdownButtonFormField<int>(
                                  value: timeWindowStart ?? 0,
                                  isDense: true,
                                  items: List.generate(
                                    24,
                                    (i) => DropdownMenuItem(
                                      value: i,
                                      child: Text('${i.toString().padLeft(2, '0')}:00'),
                                    ),
                                  ),
                                  onChanged: (v) {
                                    if (v != null) {
                                      setDialogState(
                                          () => timeWindowStart = v);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'End hour',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.ac.textSecondary,
                                  ),
                                ),
                                DropdownButtonFormField<int>(
                                  value: timeWindowEnd ?? 23,
                                  isDense: true,
                                  items: List.generate(
                                    24,
                                    (i) => DropdownMenuItem(
                                      value: i,
                                      child: Text('${i.toString().padLeft(2, '0')}:00'),
                                    ),
                                  ),
                                  onChanged: (v) {
                                    if (v != null) {
                                      setDialogState(
                                          () => timeWindowEnd = v);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                if (isEditing)
                  TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _confirmDelete(index!);
                    },
                    child: Text(
                      'Delete',
                      style: TextStyle(color: context.ac.statusError),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final name = nameController.text.trim();
                    if (name.isEmpty) return;

                    final typeFilter = <String>{};
                    if (typeVideo) typeFilter.add('video');
                    if (typeAudio) typeFilter.add('audio');
                    if (typeHls) typeFilter.add('hls');
                    if (typeImage) typeFilter.add('image');

                    final now = DateTime.now();
                    final newRule = DownloadRule(
                      id: isEditing
                          ? rule!.id
                          : now.microsecondsSinceEpoch.toString(),
                      name: name,
                      enabled: isEditing ? rule!.enabled : true,
                      hostPattern: hostController.text.trim().isEmpty
                          ? null
                          : hostController.text.trim(),
                      typeFilter: typeFilter.isEmpty ? null : typeFilter,
                      renameTemplate: renameController.text.trim().isEmpty
                          ? null
                          : renameController.text.trim(),
                      destinationFolder: destController.text.trim().isEmpty
                          ? null
                          : destController.text.trim(),
                      requireWifi: requireWifi ? true : null,
                      requireCharging: requireCharging ? true : null,
                      timeWindowStartHour: timeWindowStart,
                      timeWindowEndHour: timeWindowEnd,
                      createdAt: isEditing ? rule!.createdAt : now,
                    );

                    if (isEditing) {
                      _updateRule(index!, newRule);
                    } else {
                      _addRule(newRule);
                    }

                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  child: Text(isEditing ? 'Save' : 'Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(int index) async {
    final rule = _rules[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Rule'),
        content: Text('Delete "${rule.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: context.ac.statusError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _deleteRule(index);
    }
  }
}

// -----------------------------------------------------------------------------
// Profiles page content — Pro-only live-editable list of SiteProfiles.
// -----------------------------------------------------------------------------

class _ProfilesPageContent extends StatefulWidget {
  final ProEntitlement proEntitlement;

  const _ProfilesPageContent({required this.proEntitlement});

  @override
  State<_ProfilesPageContent> createState() => _ProfilesPageContentState();
}

class _ProfilesPageContentState extends State<_ProfilesPageContent> {
  final SiteProfileStore _store = const SiteProfileStore();
  List<SiteProfile> _profiles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await _store.load();
    if (mounted) {
      setState(() {
        _profiles = profiles;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    await _store.save(_profiles);
  }

  void _addProfile() {
    _showProfileDialog();
  }

  void _editProfile(SiteProfile profile) {
    _showProfileDialog(existing: profile);
  }

  Future<void> _deleteProfile(SiteProfile profile) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete profile'),
        content: Text(
            'Remove "${profile.name}" (${profile.hostPattern})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete',
                style: TextStyle(color: context.ac.statusError)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _profiles.removeWhere((p) => p.id == profile.id));
    await _save();
  }

  Future<void> _showProfileDialog({SiteProfile? existing}) async {
    final isNew = existing == null;
    var name = existing?.name ?? '';
    var hostPattern = existing?.hostPattern ?? '';
    var enabled = existing?.enabled ?? true;

    // Tri-state fields: null = "Use global", true = "On", false = "Off"
    var desktopMode = existing?.desktopMode;
    var userAgentProfile = existing?.userAgentProfile;
    var adblockEnabled = existing?.adblockEnabled;
    var replaceSitePlayer = existing?.replaceSitePlayer;
    var downloadFolder = existing?.downloadFolder ?? '';

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final ac = context.ac;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(isNew ? 'Add Profile' : 'Edit Profile'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    decoration: const InputDecoration(
                        labelText: 'Name', hintText: 'e.g. News site'),
                    controller: TextEditingController(text: name),
                    onChanged: (v) => name = v.trim(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: const InputDecoration(
                        labelText: 'Host pattern',
                        hintText: 'e.g. *.example.com'),
                    controller: TextEditingController(text: hostPattern),
                    onChanged: (v) => hostPattern = v.trim(),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    title: const Text('Enabled'),
                    value: enabled,
                    onChanged: (v) =>
                        setDialogState(() => enabled = v),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  const Divider(height: 24),
                  Text('Browser overrides',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: ac.textSecondary)),
                  const SizedBox(height: 8),
                  _buildTriStateDropdown<String>(
                    context: context,
                    label: 'Desktop mode',
                    value: _triStateBool(desktopMode),
                    items: const [
                      DropdownMenuItem(
                          value: '',
                          child: Text('Use global setting')),
                      DropdownMenuItem(
                          value: 'true',
                          child: Text('Force desktop')),
                      DropdownMenuItem(
                          value: 'false',
                          child: Text('Force mobile')),
                    ],
                    onChanged: (v) => setDialogState(() {
                      if (v == '') {
                        desktopMode = null;
                      } else {
                        desktopMode = v == 'true';
                      }
                    }),
                  ),
                  const SizedBox(height: 8),
                  _buildTriStateDropdown<String>(
                    context: context,
                    label: 'User-Agent',
                    value: userAgentProfile ?? '',
                    items: const [
                      DropdownMenuItem(
                          value: '', child: Text('Use global setting')),
                      DropdownMenuItem(
                          value: 'mobile', child: Text('Mobile')),
                      DropdownMenuItem(
                          value: 'desktop_chrome',
                          child: Text('Desktop Chrome')),
                      DropdownMenuItem(
                          value: 'desktop_firefox',
                          child: Text('Desktop Firefox')),
                      DropdownMenuItem(
                          value: 'safari', child: Text('Safari')),
                    ],
                    onChanged: (v) => setDialogState(() {
                      userAgentProfile =
                          (v == null || v.isEmpty) ? null : v;
                    }),
                  ),
                  const SizedBox(height: 8),
                  _buildTriStateDropdown<String>(
                    context: context,
                    label: 'Adblock',
                    value: _triStateBool(adblockEnabled),
                    items: const [
                      DropdownMenuItem(
                          value: '',
                          child: Text('Use global setting')),
                      DropdownMenuItem(
                          value: 'true', child: Text('Enabled')),
                      DropdownMenuItem(
                          value: 'false', child: Text('Disabled')),
                    ],
                    onChanged: (v) => setDialogState(() {
                      if (v == '') {
                        adblockEnabled = null;
                      } else {
                        adblockEnabled = v == 'true';
                      }
                    }),
                  ),
                  const SizedBox(height: 8),
                  _buildTriStateDropdown<String>(
                    context: context,
                    label: 'Replace site player',
                    value: _triStateBool(replaceSitePlayer),
                    items: const [
                      DropdownMenuItem(
                          value: '',
                          child: Text('Use global setting')),
                      DropdownMenuItem(
                          value: 'true', child: Text('Enabled')),
                      DropdownMenuItem(
                          value: 'false', child: Text('Disabled')),
                    ],
                    onChanged: (v) => setDialogState(() {
                      if (v == '') {
                        replaceSitePlayer = null;
                      } else {
                        replaceSitePlayer = v == 'true';
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  Text('Download overrides',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: ac.textSecondary)),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: const InputDecoration(
                        labelText: 'Download folder (optional)',
                        hintText: 'Leave empty for global default'),
                    controller:
                        TextEditingController(text: downloadFolder),
                    onChanged: (v) => downloadFolder = v.trim(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  if (name.isEmpty || hostPattern.isEmpty) return;
                  final now = DateTime.now();
                  final profile = SiteProfile(
                    id: existing?.id ??
                        now.millisecondsSinceEpoch.toString(),
                    name: name,
                    hostPattern: hostPattern,
                    enabled: enabled,
                    desktopMode: desktopMode,
                    userAgentProfile: userAgentProfile,
                    adblockEnabled: adblockEnabled,
                    replaceSitePlayer: replaceSitePlayer,
                    downloadFolder: downloadFolder.isNotEmpty
                        ? downloadFolder
                        : null,
                    createdAt: existing?.createdAt ?? now,
                    updatedAt: now,
                  );
                  setState(() {
                    if (isNew) {
                      _profiles.add(profile);
                    } else {
                      final idx =
                          _profiles.indexWhere((p) => p.id == profile.id);
                      if (idx >= 0) {
                        _profiles[idx] = profile;
                      }
                    }
                  });
                  await _save();
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                child: Text(isNew ? 'Add' : 'Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Convert a nullable bool to a tri-state string: `''` = null, `'true'` = true,
  /// `'false'` = false.
  String _triStateBool(bool? value) {
    if (value == null) return '';
    return value.toString();
  }

  Widget _buildTriStateDropdown<T>({
    required BuildContext context,
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8)),
      ),
      items: items,
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profiles'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
            onPressed: _addProfile,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profiles.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_outline,
                            size: 56, color: context.ac.textTertiary),
                        const SizedBox(height: 12),
                        Text('No profiles yet',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: context.ac.textPrimary)),
                        const SizedBox(height: 6),
                        Text(
                          'Create a profile to override browser and '
                          'download settings for a specific site.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13,
                              color: context.ac.textSecondary),
                        ),
                        const SizedBox(height: 20),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add your first profile'),
                          onPressed: _addProfile,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    PanelHeader(
                        icon: Icons.people_outline,
                        title:
                            '${_profiles.length} profile${_profiles.length == 1 ? '' : 's'}'),
                    const SizedBox(height: 8),
                    Panel(
                      child: Column(
                        children: [
                          for (int i = 0; i < _profiles.length; i++)
                            _buildProfileTile(_profiles[i],
                                isLast: i == _profiles.length - 1),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildProfileTile(SiteProfile profile, {bool isLast = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(
            profile.enabled
                ? Icons.web_asset_rounded
                : Icons.web_asset_outlined,
            color: profile.enabled
                ? context.ac.accentFrost
                : context.ac.textTertiary,
          ),
          title: Text(profile.name,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.ac.textPrimary)),
          subtitle: Text(profile.hostPattern,
              style: TextStyle(
                  fontSize: 12,
                  color: profile.enabled
                      ? context.ac.textSecondary
                      : context.ac.textTertiary,
                  fontFamily: 'JetBrainsMono')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  profile.enabled
                      ? Icons.toggle_on
                      : Icons.toggle_off_outlined,
                  color: profile.enabled
                      ? context.ac.statusSuccess
                      : context.ac.textTertiary,
                ),
                tooltip: profile.enabled ? 'Enabled' : 'Disabled',
                onPressed: () async {
                  final updated = profile.copyWith(
                      enabled: !profile.enabled, updatedAt: DateTime.now());
                  setState(() {
                    final idx =
                        _profiles.indexWhere((p) => p.id == profile.id);
                    if (idx >= 0) _profiles[idx] = updated;
                  });
                  await _save();
                },
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                tooltip: 'Edit',
                onPressed: () => _editProfile(profile),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 18, color: context.ac.statusError),
                tooltip: 'Delete',
                onPressed: () => _deleteProfile(profile),
              ),
            ],
          ),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        if (!isLast)
          Divider(
              height: 1, indent: 48, color: context.ac.glassBorder),
      ],
    );
  }
}

/// Detail page for Scheduled / Night queue settings.
class _SchedulePageContent extends StatefulWidget {
  final DownloadQueue downloadQueue;

  const _SchedulePageContent({required this.downloadQueue});

  @override
  State<_SchedulePageContent> createState() => _SchedulePageContentState();
}

class _SchedulePageContentState extends State<_SchedulePageContent> {
  StreamSubscription<DownloadTask>? _sub;
  List<DownloadTask> _scheduledTasks = [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = widget.downloadQueue.onTaskUpdated.listen((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _scheduledTasks = widget.downloadQueue.queryTasks(
        states: {DownloadState.scheduled},
        sortBy: TaskSortField.date,
        sortDescending: false,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PanelHeader(icon: Icons.schedule, title: 'Scheduled Downloads'),
          const SizedBox(height: 8),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Schedule downloads to start at a specific time. '
                  'New downloads can be scheduled directly from the Queue page '
                  'by tapping the clock icon.',
                  style: TextStyle(
                      fontSize: 13, color: context.ac.textSecondary),
                ),
                const SizedBox(height: 16),
                if (_scheduledTasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.schedule_send_outlined,
                              size: 48, color: context.ac.textTertiary),
                          const SizedBox(height: 12),
                          Text(
                            'No scheduled downloads',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: context.ac.textPrimary),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Add a download and choose "Download later" '
                            'to schedule it here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12,
                                color: context.ac.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ..._scheduledTasks.map(
                    (task) => ListTile(
                      leading: Icon(Icons.schedule,
                          color: context.ac.accentFrost, size: 20),
                      title: Text(
                        task.savePath.split('/').last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: context.ac.textPrimary),
                      ),
                      subtitle: Text(
                        task.scheduledStartAt != null
                            ? _formatScheduledTime(task.scheduledStartAt!)
                            : 'No time set',
                        style: TextStyle(
                            fontSize: 11, color: context.ac.textSecondary),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.cancel_outlined,
                            size: 18, color: context.ac.statusError),
                        tooltip: 'Cancel scheduled download',
                        onPressed: () {
                          widget.downloadQueue.cancelTask(task.id);
                        },
                      ),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatScheduledTime(DateTime dt) {
    final now = DateTime.now();
    final diff = dt.difference(now);
    String pad(int n) => n.toString().padLeft(2, '0');

    if (diff.isNegative) {
      return 'Starting now...';
    }
    if (diff.inDays > 0) {
      return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} '
          '${pad(dt.hour)}:${pad(dt.minute)} '
          '(${diff.inDays}d ${diff.inHours % 24}h remaining)';
    }
    if (diff.inHours > 0) {
      return '${pad(dt.hour)}:${pad(dt.minute)} '
          '(${diff.inHours}h ${diff.inMinutes % 60}m remaining)';
    }
    if (diff.inMinutes > 0) {
      return '${pad(dt.hour)}:${pad(dt.minute)} '
          '(${diff.inMinutes}m remaining)';
    }
    return '${pad(dt.hour)}:${pad(dt.minute)} (less than a minute)';
  }
}

// ---------------------------------------------------------------------------
// Bottom dock reorder editor (Settings → Appearance)
// ---------------------------------------------------------------------------

/// Drag-to-reorder UI for the two browser dock slides.
class _DockReorderEditor extends StatefulWidget {
  const _DockReorderEditor();

  @override
  State<_DockReorderEditor> createState() => _DockReorderEditorState();
}

class _DockReorderEditorState extends State<_DockReorderEditor> {
  late List<String> _slide1;
  late List<String> _slide2;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await dockOrderStore.load();
    if (!mounted) return;
    setState(() {
      _slide1 = List<String>.from(dockOrderStore.slide1Order);
      _slide2 = List<String>.from(dockOrderStore.slide2Order);
      _ready = true;
    });
  }

  Future<void> _persist() async {
    await dockOrderStore.update(slide1: _slide1, slide2: _slide2);
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    await dockOrderStore.reset();
    if (!mounted) return;
    setState(() {
      _slide1 = List<String>.from(kDefaultSlide1Order);
      _slide2 = List<String>.from(kDefaultSlide2Order);
    });
  }

  List<DockItem> get _available {
    final used = {..._slide1, ..._slide2};
    return kAllDockItems.where((i) => !used.contains(i.id)).toList();
  }

  Future<void> _addTo(int slide) async {
    final pool = _available;
    if (pool.isEmpty) {
      AuroraSnackbar.show(context, 'Every dock action is already assigned.');
      return;
    }
    final target = slide == 1 ? _slide1 : _slide2;
    if (target.length >= kMaxDockItemsPerSlide) {
      AuroraSnackbar.show(
        context,
        'This slide is full (max $kMaxDockItemsPerSlide). Remove one first.',
      );
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Add to slide $slide',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: ctx.ac.textPrimary,
                ),
              ),
            ),
            for (final item in pool)
              ListTile(
                leading: Icon(item.icon, color: ctx.ac.accentFrost),
                title: Text(item.label),
                onTap: () => Navigator.pop(ctx, item.id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (slide == 1) {
        _slide1 = [..._slide1, picked];
      } else {
        _slide2 = [..._slide2, picked];
      }
    });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSlideSection(
          title: 'Slide 1 (default)',
          slideIndex: 1,
          ids: _slide1,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex -= 1;
              final item = _slide1.removeAt(oldIndex);
              _slide1.insert(newIndex, item);
            });
            unawaited(_persist());
          },
          onRemove: (id) {
            setState(() => _slide1 = _slide1.where((x) => x != id).toList());
            unawaited(_persist());
          },
        ),
        const SizedBox(height: 16),
        _buildSlideSection(
          title: 'Slide 2 (swipe left)',
          slideIndex: 2,
          ids: _slide2,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex -= 1;
              final item = _slide2.removeAt(oldIndex);
              _slide2.insert(newIndex, item);
            });
            unawaited(_persist());
          },
          onRemove: (id) {
            setState(() => _slide2 = _slide2.where((x) => x != id).toList());
            unawaited(_persist());
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Reset dock to default'),
          ),
        ),
      ],
    );
  }

  Widget _buildSlideSection({
    required String title,
    required int slideIndex,
    required List<String> ids,
    required void Function(int oldIndex, int newIndex) onReorder,
    required void Function(String id) onRemove,
  }) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: ac.textPrimary,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => unawaited(_addTo(slideIndex)),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No icons on this slide. Tap Add.',
              style: TextStyle(fontSize: 13, color: ac.textSecondary),
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: ids.length,
            onReorder: onReorder,
            itemBuilder: (context, index) {
              final id = ids[index];
              final item = DockOrderStore.byId(id);
              if (item == null) {
                return SizedBox(key: ValueKey('missing_$id'));
              }
              return ListTile(
                key: ValueKey('$slideIndex-$id'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: ReorderableDragStartListener(
                  index: index,
                  child: Icon(Icons.drag_handle, color: ac.textSecondary),
                ),
                title: Row(
                  children: [
                    Icon(item.icon, size: 20, color: ac.accentFrost),
                    const SizedBox(width: 10),
                    Expanded(child: Text(item.label)),
                  ],
                ),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: Icon(Icons.close, size: 18, color: ac.textSecondary),
                  onPressed: ids.length <= 1
                      ? null
                      : () => onRemove(id),
                ),
              );
            },
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Download destination editor (Settings → Download Defaults)
// ---------------------------------------------------------------------------

/// Edits the folder under public Downloads. Android MediaStore only allows
/// publishing into the Downloads collection without a one-off SAF picker.
class _DownloadDestinationEditor extends StatefulWidget {
  final String value;
  final bool autoClassifyEnabled;
  final ValueChanged<String> onChanged;

  const _DownloadDestinationEditor({
    required this.value,
    required this.autoClassifyEnabled,
    required this.onChanged,
  });

  @override
  State<_DownloadDestinationEditor> createState() =>
      _DownloadDestinationEditorState();
}

class _DownloadDestinationEditorState
    extends State<_DownloadDestinationEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    final normalized =
        DownloadSettings.normalizeDownloadDestination(widget.value);
    final folder = normalized.startsWith('Downloads/')
        ? normalized.substring('Downloads/'.length)
        : normalized;
    _controller = TextEditingController(text: folder);
    _focus = FocusNode();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(covariant _DownloadDestinationEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focus.hasFocus) {
      final normalized =
          DownloadSettings.normalizeDownloadDestination(widget.value);
      final folder = normalized.startsWith('Downloads/')
          ? normalized.substring('Downloads/'.length)
          : normalized;
      if (_controller.text != folder) {
        _controller.text = folder;
      }
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final dest = DownloadSettings.normalizeDownloadDestination(
      'Downloads/${_controller.text.trim()}',
    );
    final folder = dest.startsWith('Downloads/')
        ? dest.substring('Downloads/'.length)
        : dest;
    if (_controller.text != folder) {
      _controller.text = folder;
    }
    if (dest !=
        DownloadSettings.normalizeDownloadDestination(widget.value)) {
      widget.onChanged(dest);
    }
  }

  void _reset() {
    _controller.text = 'Aurora Downloader';
    widget.onChanged(DownloadSettings.defaultDownloadDestination);
  }

  @override
  Widget build(BuildContext context) {
    final saved = DownloadSettings.normalizeDownloadDestination(widget.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
          decoration: InputDecoration(
            prefixText: 'Downloads/',
            prefixStyle: TextStyle(
              color: context.ac.textSecondary,
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
            ),
            hintText: 'Aurora Downloader',
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          style: TextStyle(
            fontSize: 13,
            color: context.ac.textPrimary,
            fontFamily: 'JetBrainsMono',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _commit(),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: context.ac.accentAmber.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: context.ac.accentAmber.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 18, color: context.ac.accentAmber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Android limits where apps can write. Aurora publishes into the '
                  'shared Downloads collection only (and subfolders you name here). '
                  'You cannot choose DCIM, arbitrary SD-card roots, or other apps\' '
                  'folders without using a one-time system folder picker for a single file. '
                  'With auto-classify on, files also go into Videos / Audio / Images / … '
                  'under this folder.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: context.ac.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton(
              onPressed: _reset,
              child: const Text('Reset to default'),
            ),
            const Spacer(),
          ],
        ),
        Text(
          'Publishes to: $saved'
          '${widget.autoClassifyEnabled ? '/Videos|Audio|…' : ''}',
          style: TextStyle(
            fontSize: 12,
            color: context.ac.textSecondary,
            fontFamily: 'JetBrainsMono',
          ),
        ),
      ],
    );
  }
}
