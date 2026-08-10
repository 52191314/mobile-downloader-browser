import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/aurora_palette.dart';
import '../../theme/aurora_tokens.dart';
import '../../settings/onboarding_experiment.dart';

/// User Guide & Documentation sub-page for Aurora Downloader.
/// Displays comprehensive guides, feature references, and troubleshooting.
class UserGuidePage extends StatefulWidget {
  const UserGuidePage({super.key});

  @override
  State<UserGuidePage> createState() => _UserGuidePageState();
}

class _UserGuidePageState extends State<UserGuidePage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final sections = _getGuideSections(context);
    final filteredSections = sections.where((section) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return section.title.toLowerCase().contains(q) ||
          section.content.toLowerCase().contains(q) ||
          section.keywords.any((k) => k.toLowerCase().contains(q));
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)?.lblUserGuideTitle ?? 'User Guide & Tutorial'),
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: AppLocalizations.of(context)!.guideSearchHint,
                prefixIcon: Icon(Icons.search, color: ac.accentFrost),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: ac.surfacePanel,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => _searchQuery = v.trim()),
            ),
          ),
          // User-facing re-entry to the interactive app tour.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: InkWell(
              onTap: () async {
                await OnboardingExperiment.resetOnboarding();
                if (context.mounted) {
                  Navigator.of(context, rootNavigator: true)
                      .popUntil((route) => route.isFirst);
                }
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: ac.accentFrost.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: ac.accentFrost.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.tour_outlined, color: ac.accentFrost, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Show app tour',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: ac.textPrimary,
                            ),
                          ),
                          Text(
                            'Walk through the main controls — browser, radar, menu, and queue.',
                            style: TextStyle(
                              fontSize: 12,
                              color: ac.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: ac.textTertiary),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Section List
          Expanded(
            child: filteredSections.isEmpty
                ? Center(
                    child: Text(
                      'No guide topics match "$_searchQuery"',
                      style: TextStyle(color: ac.textSecondary),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: filteredSections.length,
                    itemBuilder: (context, index) {
                      final section = filteredSections[index];
                      return _GuideSectionCard(section: section);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  List<_GuideSectionData> _getGuideSections(BuildContext context) {
    return [
      _GuideSectionData(
        number: 1,
        title: AppLocalizations.of(context)!.guideQuickStart,
        icon: Icons.rocket_launch_rounded,
        keywords: ['install', 'basic', 'workflow', 'manual', 'url', 'radar', 'sniffer'],
        badge: null,
        content: '''
### Basic Workflow
1. Browse — Use the built-in browser (middle tab) to navigate to any media or download page.
2. Sniff — When media is detected, a badge appears on the radar icon. Tap it to expand detected stream URLs.
3. Download — Select your preferred resolution or format to start downloading immediately.
4. Monitor — Switch to the Queue tab (left) to track download speeds, remaining time, and progress.
5. Open — Tap a completed download card to play or open in your preferred default app.

### Add a URL Manually
1. On the Queue page, paste any direct URL, HLS playlist (`.m3u8`), or magnet link into the top input field.
2. Tap the Add Download (+) button or Schedule (Clock) button.
3. The multi-protocol engine automatically probes filename, content length, and server chunk support.
''',
      ),
      _GuideSectionData(
        number: 2,
        title: AppLocalizations.of(context)!.guideEngineProtocols,
        icon: Icons.download_rounded,
        keywords: ['http', 'segmented', 'hls', 'm3u8', 'torrent', 'bittorrent', 'engine', 'chunk'],
        badge: null,
        content: '''
### Multi-Protocol Engines
• Segmented HTTP: Multi-threaded parallel chunk downloader for files (`.mp4`, `.zip`, `.apk`) with dynamic pause and resume.
• HLS Stream Engine (`.m3u8`): Parses HLS playlists, downloads `.ts` segments in parallel, decrypts AES-128 streams, and remuxes segments directly into MP4 files without re-encoding.
• BitTorrent Client: Native magnet link and `.torrent` file support with multi-file selection and peer discovery.

### Download Link Behaviors
• Save to tray: Enqueues task silently without interrupting active browsing.
• Download right away: Starts downloading immediately.
• Ask each time: Displays a prompt with resolution and folder options.
• Block link: Ignores unwanted download triggers.
''',
      ),
      _GuideSectionData(
        number: 3,
        title: AppLocalizations.of(context)!.guideQueueGestures,
        icon: Icons.queue_music_rounded,
        keywords: ['chips', 'filter', 'sort', 'swipe', 'bulk', 'actions', 'multi-select'],
        badge: null,
        content: '''
### Filters & Sorting
• Filter tasks by state: All, Active, Scheduled, Paused, Done, or Failed.
• Sort tasks in real time by Date, Name, Size, Priority, State, or Speed.

### Task Card Gestures
• Tap: Open completed file or Pause/Resume active task.
• Swipe Right: Contextual shortcut (Pause / Resume / Retry / Open).
• Swipe Left: Delete or Cancel task.
• Overflow Menu (⋮): Share, Send to PC, Move to Vault, Edit in FFmpeg Studio, Redownload, Force Merge, Refresh Link, and File Properties.
• Multi-Select Mode: Long-press any task card to enter bulk selection for batch pause, resume, or deletion.
''',
      ),
      _GuideSectionData(
        number: 4,
        title: AppLocalizations.of(context)!.guideBrowserSniffer,
        icon: Icons.language_rounded,
        keywords: ['browser', 'sniffer', 'radar', 'dock', 'tabs', 'reader', 'autofill', 'security'],
        badge: null,
        content: '''
### Address Bar & Security
• Address bar with live search engine suggestions and instant URL navigation.
• Lock Icon: View SSL certificate details, security status, and domain info.
• Purple Shield: Indicates active Private / Incognito mode.

### Browser Tools Menu
• Bookmarks, Saved Pages (offline HTML reader), Browsing History, Find in Page, Autofill, Reader Mode, Element Blocker, Adblocker, and Series Grabber.

### Dock Customization
• App primary tabs (`Queue` · `Browser` · `Settings`) remain anchored on the bottom navigation bar.
• Reorder up to 5 browser toolbar shortcut icons per slide in Settings → Appearance → Browser Toolbar.
''',
      ),
      _GuideSectionData(
        number: 5,
        title: AppLocalizations.of(context)!.guideSiteProfiles,
        icon: Icons.collections_bookmark_rounded,
        keywords: ['site profile', 'profile', 'series grab', 'batch', 'grabber', 'user-agent', 'freetaste'],
        badge: 'PRO',
        content: '''
### Custom Site Profiles
Create per-domain rules in Settings → Browser → Site Profiles to automatically apply custom User-Agent headers, referrers, cookie inheritance, auto-probe behavior, or custom subfolder routing.

### Series & Batch Grabber
Extract all video or media links from multi-episode pages, galleries, or playlist pages in one tap:
• Open Browser Tools → Series Grabber or tap Grab All in the media sniffer.
• Review, filter by quality or file type, and batch enqueue selected items.
• Free taste: Enqueue up to 5 items/episodes per grab action. Pro/Ultra: Unlimited batch downloads.
''',
      ),
      _GuideSectionData(
        number: 6,
        title: AppLocalizations.of(context)!.guideSendToPc,
        icon: Icons.qr_code_scanner_rounded,
        keywords: ['send to pc', 'lan', 'wifi', 'transfer', 'qr', 'http server', 'share'],
        badge: 'PRO',
        content: '''
### Local Network File Sharing
Transfer completed downloads directly to any PC, Mac, tablet, or secondary smartphone over Wi-Fi without cloud uploads or USB cables:
1. Tap Send to PC in the task overflow menu (⋮) on any completed download card.
2. Aurora starts a local HTTP server and displays a QR code and Web URL (e.g. `http://192.168.1.50:8080`).
3. Scan the QR code or type the URL into any browser on your computer to download the file directly.
• Free taste: Up to 20 Send to PC transfers per calendar day. Pro/Ultra: Unlimited LAN transfers.
''',
      ),
      _GuideSectionData(
        number: 7,
        title: AppLocalizations.of(context)!.guideRulesAutoNaming,
        icon: Icons.rule_rounded,
        keywords: ['rules', 'rename', 'template', 'destination', 'tokens', 'auto-route'],
        badge: 'PRO',
        content: '''
### Automated Route & Naming Rules
Configure rules in Settings → Downloads → Rules to automatically rename files, organize downloads into custom subfolders, or apply network rules based on domain or file extension.

### Dynamic Naming Tokens
• `{host}`: Source URL domain name (e.g. `youtube.com`)
• `{title}`: Video or webpage title without extension
• `{ext}`: File extension (`mp4`, `mkv`, `zip`)
• `{quality}`: Extracted media resolution string (`1080p`, `4k`)
• `{date}`: Current date (`YYYY-MM-DD`)

Example: `{host}_{title}_{quality}.{ext}` -> `site.com_Tutorial_1080p.mp4`
''',
      ),
      _GuideSectionData(
        number: 8,
        title: AppLocalizations.of(context)!.guideScheduleNight,
        icon: Icons.schedule_rounded,
        keywords: ['schedule', 'clock', 'night mode', 'timer', 'off-peak'],
        badge: 'PRO',
        content: '''
### Scheduling Downloads
Queue downloads to run automatically during off-peak hours or night-time Wi-Fi windows:
1. Tap the Clock icon next to the Add Download button, or select Schedule download from any task card menu.
2. Select your desired start date and time.
3. The task enters the Scheduled section (purple badge) and begins automatically when the start time arrives.
''',
      ),
      _GuideSectionData(
        number: 9,
        title: AppLocalizations.of(context)!.guideAdblockPrivacy,
        icon: Icons.shield_rounded,
        keywords: ['adblock', 'ublock', 'aho-corasick', 'popups', 'element blocker', 'cosmetic'],
        badge: null,
        content: '''
### High-Performance Ad Blocker
• Uses a native C++ Aho-Corasick pattern matcher for fast ad, tracker, and popup blocking with minimal CPU overhead.
• Built-in uBlock Origin filter list packs (uBlock Filters, Privacy, Badware, Quick Fixes).
• Free: Activate up to 3 filter lists. Pro: Unlimited filter lists & custom filter URL subscriptions.
• Element Blocker: Interactively select and hide unwanted webpage elements via Browser Tools → Block Element.
''',
      ),
      _GuideSectionData(
        number: 10,
        title: AppLocalizations.of(context)!.guideCustomHosts,
        icon: Icons.domain_rounded,
        keywords: ['video hosts', 'cdn', 'extensionless', 'probe', 'doodstream', 'streamtape', 'head probe'],
        badge: null,
        content: '''
### Extensionless Stream Sniffing
Certain streaming hosts serve video files using dynamic URLs without explicit `.mp4` or `.mkv` extensions.
• Add custom domain names in Settings → Browser → Sniffer → Extra Video Hosts.
• When visiting these domains, Aurora sends lightweight HEAD request probes to inspect response Content-Types and detect video streams automatically.
''',
      ),
      _GuideSectionData(
        number: 11,
        title: AppLocalizations.of(context)!.guideThemesAccent,
        icon: Icons.palette_outlined,
        keywords: ['theme', 'nord', 'oled', 'accent', 'color', 'dark mode'],
        badge: null,
        content: '''
### Customizing Look & Feel
• Dark Modes: Choose System default, Light theme, or True Dark (OLED black) for maximum display power efficiency.
• Accent Color Packs (Pro): Select between Nord Frost (default cyan), Aurora Green, Warm Sunset, or Deep Purple. Palette changes take effect instantly across all screens.
''',
      ),
      _GuideSectionData(
        number: 12,
        title: AppLocalizations.of(context)!.guidePrivateVault,
        icon: Icons.lock_outline_rounded,
        keywords: ['vault', 'encryption', 'aes-256', 'biometric', 'security', 'flag_secure'],
        badge: 'PRO',
        content: '''
### Biometric & Hardware Encryption
• Encrypts sensitive media files on-device with AES-256-GCM hardware key storage (Android Keystore).
• Secure access via device biometric authentication (Fingerprint / Face ID) or PIN.
• Screen Protection (`FLAG_SECURE`): Prevents screenshot capture and hides content preview in the Android recent apps switcher while unlocked.
• Auto-Lock: Automatically locks after 5 minutes of inactivity.
• Free: Store up to 25 items in Vault. Pro/Ultra: Unlimited Vault storage.
''',
      ),
      _GuideSectionData(
        number: 13,
        title: AppLocalizations.of(context)!.guideFfmpegStudio,
        icon: Icons.video_settings_rounded,
        keywords: ['ffmpeg', 'compress', 'convert', 'trim', 'audio extract', 'remux'],
        badge: 'ULTRA',
        content: '''
### On-Device Media Suite
Process and edit completed video and audio downloads directly on device without external tools:
• Remux containers (e.g. convert `.mkv` to `.mp4` without re-encoding).
• Audio Extraction: Convert video tracks into high-quality `MP3`, `AAC`, or `FLAC` audio files.
• Trim & Compress: Trim unwanted segments or re-compress videos with hardware acceleration.
''',
      ),
      _GuideSectionData(
        number: 14,
        title: AppLocalizations.of(context)!.guideBackupTransfer,
        icon: Icons.cloud_sync_rounded,
        keywords: ['backup', 'database', '1dm', '1dmbak', 'restore', 'webdav', 'vault sync', 'cloud', 'e2ee', 'synology', 'nextcloud'],
        badge: null,
        content: '''
### Database Backups & Cloud Sync
• Transactional Database Backup (Solution B): Export and restore full app state (download queues, history, bookmarks, saved pages, and tabs) into an atomic, zero-freeze transactional database snapshot off-thread.
• 1DM (.1dmbak / .1dm) Import Migration: Import legacy 1DM and 1DM+ backup archives directly off-thread into Aurora's unified database.
• WebDAV Backup (Pro): Backup and restore app settings, rules, and download queues to personal WebDAV servers (Nextcloud, Synology, ownCloud).
• Encrypted Vault Cloud Sync (Ultra): End-to-end PBKDF2-SHA256 + AES-GCM encrypted backup of vault files over WebDAV for multi-device security.
''',
      ),
      _GuideSectionData(
        number: 15,
        title: AppLocalizations.of(context)!.guideWatcherRss,
        icon: Icons.rss_feed_rounded,
        keywords: ['watcher', 'rss', 'atom', 'monitor', 'feed', 'automation'],
        badge: 'ULTRA',
        content: '''
### Automated Link Monitoring
Monitor RSS/Atom feeds or web pages for new download links automatically in the background:
1. Navigate to Settings → Data & Account → Watcher → Add Watch.
2. Enter RSS/page URL and optional regex filter (e.g. `.*\\.mp4\$`).
3. The background service checks periodically and automatically enqueues new matching downloads.
''',
      ),
      _GuideSectionData(
        number: 16,
        title: AppLocalizations.of(context)!.guideAutomationApi,
        icon: Icons.api_rounded,
        keywords: ['api', 'rest', 'tasker', 'macrodroid', 'localhost', 'token', 'curl'],
        badge: 'ULTRA',
        content: '''
### Localhost REST API Server
Integrate Aurora Downloader with Tasker, MacroDroid, shortcuts, or external scripts via `http://127.0.0.1:8080`.
• Protected by Bearer token authorization header.
• Endpoints: System Status (`GET /v1/status`), Task List (`GET /v1/tasks`), and Enqueue Download (`POST /v1/tasks`).
''',
      ),
      _GuideSectionData(
        number: 17,
        title: AppLocalizations.of(context)!.guidePipMode,
        icon: Icons.picture_in_picture_rounded,
        keywords: ['pip', 'picture in picture', 'floating player', 'video', 'background'],
        badge: null,
        content: '''
### Floating Video Player
Tap the PiP button in Aurora's built-in media player to shrink video into a floating window. Continue browsing or managing downloads while video playback continues seamlessly.
''',
      ),
      _GuideSectionData(
        number: 18,
        title: AppLocalizations.of(context)!.guideIncognitoMode,
        icon: Icons.visibility_off_rounded,
        keywords: ['incognito', 'private', 'history', 'cookies', 'shield'],
        badge: null,
        content: '''
### Private Browsing Protection
Toggle Private mode via Settings → Search & Privacy or address bar shield button. Active tabs display a purple shield indicator. Browsing history, cookies, and search suggestions are suppressed while Private mode is active.
''',
      ),
      _GuideSectionData(
        number: 19,
        title: AppLocalizations.of(context)!.guideBuildTiers,
        icon: Icons.workspace_premium_rounded,
        keywords: ['pro', 'ultra', 'pricing', 'tiers', 'channels', 'play', 'github', 'billing'],
        badge: null,
        content: '''
### Distribution Channels
• GitHub / Sideload Build: Open-source release (`github` channel) without billing client dependencies.
• Google Play Release: Store build (`play` channel) with integrated Google Play Billing for Pro/Ultra activation.

### Feature Matrix & Caps
• Free: 3 concurrent downloads, 8 chunks/task, 4 HLS segments, 3 tab groups, 25 vault items, 3 adblock filters, 20 Send to PC transfers/day, 5 Series Grab items/action.
• Pro: 16 concurrent downloads, 32 chunks/task, 8 HLS segments, unlimited tab groups & vault, Wi-Fi only mode, Download Rules, Schedule, Proxy, WebDAV backup, unlimited Send to PC & Series Grab.
• Ultra: 64 concurrent downloads, 64 chunks/task, unlimited HLS segments, FFmpeg Studio, Watcher RSS, Automation API, Encrypted Vault Sync, Server-grade engine.
''',
      ),
      _GuideSectionData(
        number: 20,
        title: AppLocalizations.of(context)!.guideTroubleshootingFaq,
        icon: Icons.help_outline_rounded,
        keywords: ['troubleshooting', 'faq', 'error', 'failed', 'battery', 'cloudflare', 'refresh link'],
        badge: null,
        content: '''
### Common Solutions
• Stalled / Slow Downloads: Check speed limits in Settings → Downloads, or adjust retry limits and stall timeouts.
• Expired Media Links: If a long download fails due to an expired link token, tap task overflow menu (⋮) → Refresh Link to update the stream URL without losing downloaded progress.
• Background Downloads Killed: Ensure background battery optimization is disabled for Aurora Downloader in Settings → About → Battery optimization.
• Cloudflare / Protected Sites: Tap Re-sniff on page in the Sniffer sheet to refresh session cookies.
''',
      ),
    ];
  }
}

class _GuideSectionData {
  final int number;
  final String title;
  final IconData icon;
  final List<String> keywords;
  final String? badge;
  final String content;

  const _GuideSectionData({
    required this.number,
    required this.title,
    required this.icon,
    required this.keywords,
    this.badge,
    required this.content,
  });
}

class _GuideSectionCard extends StatefulWidget {
  final _GuideSectionData section;

  const _GuideSectionCard({required this.section});

  @override
  State<_GuideSectionCard> createState() => _GuideSectionCardState();
}

class _GuideSectionCardState extends State<_GuideSectionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = widget.section;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: ac.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.glassBorder),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _expanded,
          onExpansionChanged: (v) => setState(() => _expanded = v),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ac.accentFrost.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(s.icon, color: ac.accentFrost, size: 22),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  '${s.number}. ${s.title}',
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: ac.textPrimary,
                  ),
                ),
              ),
              if (s.badge != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: s.badge == 'ULTRA'
                          ? Colors.purple.withValues(alpha: 0.2)
                          : ac.accentFrost.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      s.badge!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: s.badge == 'ULTRA'
                            ? Colors.purpleAccent
                            : ac.accentFrost,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _GuideContentRenderer(content: s.content),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideContentRenderer extends StatelessWidget {
  final String content;

  const _GuideContentRenderer({required this.content});

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final lines = content.trim().split('\n');
    final List<Widget> children = [];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }

      if (line.startsWith('### ')) {
        final headingText = line.substring(4);
        children.add(
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 10, bottom: 4),
            child: Text(
              headingText,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: ac.textPrimary,
              ),
            ),
          ),
        );
      } else if (line.startsWith('• ') || line.startsWith('- ')) {
        final bulletText = line.substring(2);
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '• ',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: ac.accentFrost,
                  ),
                ),
                Expanded(child: _buildRichText(bulletText, ac)),
              ],
            ),
          ),
        );
      } else if (RegExp(r'^\d+\.\s').hasMatch(line)) {
        final match = RegExp(r'^(\d+)\.\s(.*)$').firstMatch(line);
        final numStr = match?.group(1) ?? '1';
        final itemText = match?.group(2) ?? line;
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$numStr. ',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: ac.accentFrost,
                  ),
                ),
                Expanded(child: _buildRichText(itemText, ac)),
              ],
            ),
          ),
        );
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _buildRichText(line, ac),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildRichText(String text, AColors ac) {
    final parts = text.split('`');
    if (parts.length == 1) {
      return Text(
        text,
        style: TextStyle(
          fontSize: 13,
          height: 1.45,
          color: ac.textSecondary,
          fontFamily: 'Inter',
        ),
      );
    }

    final List<InlineSpan> spans = [];
    for (int i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      if (i.isEven) {
        spans.add(
          TextSpan(
            text: parts[i],
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: ac.textSecondary,
              fontFamily: 'Inter',
            ),
          ),
        );
      } else {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: ac.surfacePanel,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: ac.glassBorder,
                  width: 0.8,
                ),
              ),
              child: Text(
                parts[i],
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'JetBrains Mono',
                  color: ac.accentFrost,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        );
      }
    }

    return Text.rich(
      TextSpan(children: spans),
    );
  }
}
