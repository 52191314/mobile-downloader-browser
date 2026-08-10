import 'package:flutter/material.dart';

import 'package:aurora_downloader/premium/pro_entitlement.dart';
import 'package:aurora_downloader/premium/pro_features.dart';
import 'package:aurora_downloader/premium/upsell_controller.dart';
import 'package:aurora_downloader/sniffer/browser_library.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Which half of a library sheet is showing.
enum LibrarySection { sites, videos }

/// Sites | Videos switcher pinned above a library sheet's content.
class LibrarySectionBar extends StatelessWidget {
  const LibrarySectionBar({
    super.key,
    required this.current,
    required this.onChanged,
    this.videoCount,
  });

  final LibrarySection current;
  final ValueChanged<LibrarySection> onChanged;

  /// Shown on the Videos segment so the section is not a mystery box.
  final int? videoCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SegmentedButton<LibrarySection>(
        segments: [
          const ButtonSegment(
            value: LibrarySection.sites,
            icon: Icon(Icons.public, size: 16),
            label: Text('Sites'),
          ),
          ButtonSegment(
            value: LibrarySection.videos,
            icon: const Icon(Icons.movie_outlined, size: 16),
            label: Text(
              videoCount == null || videoCount == 0
                  ? 'Videos'
                  : 'Videos ($videoCount)',
            ),
          ),
        ],
        selected: {current},
        showSelectedIcon: false,
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

/// "N of M free" strip shown above a capped list.
///
/// Deliberately not a wall: the list is visible underneath. A user who cannot
/// see what they saved assumes the feature is broken, not that it is paid.
class VideoGateBanner extends StatelessWidget {
  const VideoGateBanner({
    super.key,
    required this.used,
    required this.limit,
    required this.tier,
    required this.message,
  });

  final int used;
  final int limit;
  final EntitlementTier tier;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final atCap = used >= limit;
    final color = atCap ? ac.accentAmber : ac.textSecondary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => UpsellController.show(
            context,
            feature: ProFeature.videoLibrary,
            userTier: tier,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  atCap ? Icons.lock_outline_rounded : Icons.info_outline,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$used of $limit free · $message',
                    style: TextStyle(fontSize: 11, color: ac.textSecondary),
                  ),
                ),
                Text(
                  'Upgrade',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: ac.accentFrost,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 16:9 poster for a library row, falling back to a film icon.
class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final u = url?.trim();
    final usable = u != null &&
        u.isNotEmpty &&
        (u.startsWith('http://') || u.startsWith('https://'));

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 64,
        height: 36,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: ac.mediaVideo.withValues(alpha: 0.16),
              child: Icon(Icons.movie_rounded, size: 16, color: ac.mediaVideo),
            ),
            if (usable)
              Image.network(
                u,
                fit: BoxFit.cover,
                cacheWidth: 128,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }
}

/// Saved videos.
class VideoFavoritesList extends StatelessWidget {
  const VideoFavoritesList({
    super.key,
    required this.items,
    required this.onOpen,
    required this.onRemove,
    this.onOpenSourcePage,
    this.selectionMode = false,
    this.selectedUrls = const {},
    this.onToggleSelected,
    this.onSelectRange,
  });

  final List<BrowserFavorite> items;
  final ValueChanged<BrowserFavorite> onOpen;
  final ValueChanged<BrowserFavorite> onRemove;
  final ValueChanged<BrowserFavorite>? onOpenSourcePage;
  final bool selectionMode;
  final Set<String> selectedUrls;
  final ValueChanged<BrowserFavorite>? onToggleSelected;
  final void Function(BrowserFavorite favorite, int index)? onSelectRange;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Empty(
        icon: Icons.movie_outlined,
        title: 'No saved videos yet',
        body: 'Tap the star while a video is playing to keep it here.',
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final fav = items[i];
        final isSelected = selectedUrls.contains(fav.url);
        final theme = Theme.of(context);
        return ListTile(
          selected: isSelected,
          selectedTileColor: theme.colorScheme.primaryContainer.withOpacity(0.15),
          leading: _VideoThumb(url: fav.thumbnailUrl),
          title: Text(fav.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            fav.sourcePageUrl ?? fav.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          onTap: () {
            if (selectionMode) {
              onToggleSelected?.call(fav);
            } else {
              onOpen(fav);
            }
          },
          onLongPress: () => onSelectRange?.call(fav, i),
          trailing: selectionMode
              ? null
              : PopupMenuButton<String>(
                  onSelected: (a) {
                    if (a == 'remove') onRemove(fav);
                    if (a == 'page') onOpenSourcePage?.call(fav);
                  },
                  itemBuilder: (_) => [
                    if (fav.sourcePageUrl != null && onOpenSourcePage != null)
                      const PopupMenuItem(value: 'page', child: Text('Open page')),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove'),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// Watch history.
class VideoHistoryList extends StatelessWidget {
  const VideoHistoryList({
    super.key,
    required this.items,
    required this.onOpen,
    this.onOpenSourcePage,
    this.selectionMode = false,
    this.selectedUrls = const {},
    this.onToggleSelected,
    this.onSelectRange,
  });

  final List<BrowserHistoryEntry> items;
  final ValueChanged<BrowserHistoryEntry> onOpen;
  final ValueChanged<BrowserHistoryEntry>? onOpenSourcePage;
  final bool selectionMode;
  final Set<String> selectedUrls;
  final ValueChanged<BrowserHistoryEntry>? onToggleSelected;
  final void Function(BrowserHistoryEntry entry, int index)? onSelectRange;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Empty(
        icon: Icons.history_rounded,
        title: 'No watch history yet',
        body: 'Videos you play in Aurora\'s player show up here.',
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final entry = items[i];
        final isSelected = selectedUrls.contains(entry.url);
        final theme = Theme.of(context);
        return ListTile(
          selected: isSelected,
          selectedTileColor: theme.colorScheme.primaryContainer.withOpacity(0.15),
          leading: _VideoThumb(url: entry.thumbnailUrl),
          title:
              Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _relative(entry.visitedAt),
            style: const TextStyle(fontSize: 11),
          ),
          onTap: () {
            if (selectionMode) {
              onToggleSelected?.call(entry);
            } else {
              onOpen(entry);
            }
          },
          onLongPress: () => onSelectRange?.call(entry, i),
          trailing: selectionMode
              ? null
              : (entry.sourcePageUrl != null && onOpenSourcePage != null
                  ? IconButton(
                      tooltip: 'Open page',
                      icon: const Icon(Icons.open_in_new, size: 18),
                      onPressed: () => onOpenSourcePage!(entry),
                    )
                  : null),
        );
      },
    );
  }

  static String _relative(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: ac.textTertiary),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(
                color: ac.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: ac.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
