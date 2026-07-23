import 'package:flutter/material.dart';
import 'package:aurora_downloader/ui/widgets/dock_order_store.dart';

import '../../theme/aurora_palette.dart';
import '../models/browser_tab.dart';

/// Compact, flat icon button used in the browser bottom dock.
class CompactNavButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;
  final Key? buttonKey;
  /// Optional override for the icon color (e.g. amber when bookmarked).
  final Color? color;

  const CompactNavButton({
    super.key,
    required this.icon,
    this.enabled = true,
    this.onTap,
    this.buttonKey,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // Always provide a non-null [onPressed] so Material does not stack a
    // second disabled opacity on our color (Back/Forward looked missing).
    final resolved = color ?? (enabled ? ac.textPrimary : ac.textSecondary);
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        key: buttonKey,
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 22, color: resolved),
        style: IconButton.styleFrom(foregroundColor: resolved),
        onPressed: () {
          if (enabled) onTap?.call();
        },
      ),
    );
  }
}

/// Samsung-shape primary browser strip: icon-only, even spacing, no labels.
///
/// Back · Forward · Queue · Radar · Bookmarks menu · Tabs · Menu
///
/// Star (add/remove favorite for the current page) lives on the address bar,
/// not here — matches Samsung Internet: star vs bookmarks-list icons.
class BrowserPrimaryBar extends StatelessWidget {
  final BrowserTab tab;
  final int sniffedBadgeCount;
  final VoidCallback onSniffer;
  final VoidCallback onTabs;
  final VoidCallback onMenu;
  /// Open the app Queue shell tab. Placed immediately left of Radar.
  final VoidCallback? onQueue;
  /// Open the bookmarks / favorites list (not toggle current page).
  final VoidCallback? onBookmarksMenu;
  final GlobalKey? menuKey;
  final GlobalKey? snifferKey;
  final GlobalKey? tabsKey;

  const BrowserPrimaryBar({
    super.key,
    required this.tab,
    required this.sniffedBadgeCount,
    required this.onSniffer,
    required this.onTabs,
    required this.onMenu,
    this.onQueue,
    this.onBookmarksMenu,
    this.menuKey,
    this.snifferKey,
    this.tabsKey,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final canBack = tab.canGoBack;
    final canForward = tab.canGoForward;

    Widget radarIcon() {
      final icon = Icon(
        Icons.radar,
        size: 22,
        color: ac.textPrimary,
      );
      if (sniffedBadgeCount <= 0) return icon;
      return Badge(
        label: Text(
          sniffedBadgeCount > 99 ? '99+' : '$sniffedBadgeCount',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
        ),
        backgroundColor: ac.accentAmber,
        child: icon,
      );
    }

    // Back · Forward · Queue · Radar · Bookmarks menu · Tabs · Menu
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        CompactNavButton(
          buttonKey: const Key('sniffer_back_button'),
          icon: Icons.arrow_back_ios_new,
          enabled: canBack,
          onTap: canBack ? () => tab.controller.goBack() : null,
        ),
        CompactNavButton(
          buttonKey: const Key('sniffer_forward_button'),
          icon: Icons.arrow_forward_ios,
          enabled: canForward,
          onTap: canForward ? () => tab.controller.goForward() : null,
        ),
        CompactNavButton(
          buttonKey: const Key('browser_queue_button'),
          icon: Icons.download_rounded,
          onTap: onQueue,
        ),
        SizedBox(
          key: snifferKey,
          width: 44,
          height: 44,
          child: IconButton(
            key: const Key('sniffer_sniffer_button'),
            padding: EdgeInsets.zero,
            onPressed: onSniffer,
            icon: radarIcon(),
          ),
        ),
        CompactNavButton(
          buttonKey: const Key('browser_bookmarks_menu_button'),
          icon: Icons.bookmarks_outlined,
          onTap: onBookmarksMenu,
        ),
        CompactNavButton(
          buttonKey: tabsKey ?? const Key('browser_tabs_button'),
          icon: Icons.tab,
          onTap: onTabs,
        ),
        CompactNavButton(
          buttonKey: menuKey ?? const Key('browser_menu_button'),
          icon: Icons.more_vert,
          onTap: onMenu,
        ),
      ],
    );
  }
}

/// Two-slide browser toolbar shown in the Sniffer screen's bottom strip.
///
/// In-page tools only (back, forward, sniffer, tabs, menu, …). App
/// destinations Queue / Browser / Settings live on the shell bottom nav.
///
/// Swipe horizontally to move between slides. Icons are flat (no circle
/// outline). A small pill indicator shows the active slide.
///
/// Icon order comes from [dockOrderStore]
/// (Settings → Appearance → Browser toolbar).
class BrowserDock extends StatefulWidget {
  final BrowserTab tab;
  final VoidCallback onSniffer;
  final VoidCallback onDownload;
  final VoidCallback onTab;
  final VoidCallback onBrowserTools;
  final VoidCallback onSettings;
  final VoidCallback onHistory;
  final VoidCallback onBookmarks;
  final VoidCallback onHome;
  final VoidCallback onAdblock;
  final VoidCallback onReaderMode;

  const BrowserDock({
    super.key,
    required this.tab,
    required this.onSniffer,
    required this.onDownload,
    required this.onTab,
    required this.onBrowserTools,
    required this.onSettings,
    required this.onHistory,
    required this.onBookmarks,
    required this.onHome,
    required this.onAdblock,
    required this.onReaderMode,
  });

  @override
  State<BrowserDock> createState() => _BrowserDockState();
}

class _BrowserDockState extends State<BrowserDock> {
  final PageController _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = DockOrderStore();
    final slide1Ids = store.slide1Order.isEmpty
        ? kDefaultSlide1Order
        : store.slide1Order;
    final slide2Ids = store.slide2Order.isEmpty
        ? kDefaultSlide2Order
        : store.slide2Order;

    final slide1 =
        slide1Ids.map((id) => _buttonForId(id)).whereType<Widget>().toList();
    final slide2 =
        slide2Ids.map((id) => _buttonForId(id)).whereType<Widget>().toList();

    return Column(
      children: [
        Expanded(
          child: PageView(
            controller: _pageController,
            onPageChanged: (index) => setState(() => _page = index),
            children: [
              _dockSlide(slide1),
              _dockSlide(slide2),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _DockDot(active: _page == 0),
              const SizedBox(width: 6),
              _DockDot(active: _page == 1),
            ],
          ),
        ),
      ],
    );
  }

  Widget? _buttonForId(String id) {
    final tab = widget.tab;
    final badgeCount = tab.snifferEngine.detectedMedia.length;
    final item = DockOrderStore.byId(id);
    if (item == null) return null;

    switch (id) {
      case 'back':
        return CompactNavButton(
          key: const Key('sniffer_back_button'),
          icon: item.icon,
          enabled: tab.canGoBack,
          onTap: tab.canGoBack ? () => tab.controller.goBack() : null,
        );
      case 'forward':
        return CompactNavButton(
          key: const Key('sniffer_forward_button'),
          icon: item.icon,
          enabled: tab.canGoForward,
          onTap: tab.canGoForward ? () => tab.controller.goForward() : null,
        );
      case 'sniffer':
        return CompactNavButton(
          key: const Key('sniffer_sniffer_button'),
          icon: badgeCount > 0 ? Icons.radar : Icons.add,
          enabled: true,
          onTap: widget.onSniffer,
        );
      case 'downloads':
        return CompactNavButton(
          key: const Key('mini_dock_queue'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onDownload,
        );
      case 'tabs':
        return CompactNavButton(
          key: const Key('browser_tabs_button'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onTab,
        );
      case 'home':
        return CompactNavButton(
          key: const Key('mini_dock_home'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onHome,
        );
      case 'menu':
        return CompactNavButton(
          key: const Key('mini_dock_menu'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onBrowserTools,
        );
      case 'history':
        return CompactNavButton(
          key: const Key('mini_dock_history'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onHistory,
        );
      case 'bookmarks':
        return CompactNavButton(
          key: const Key('mini_dock_bookmarks'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onBookmarks,
        );
      case 'settings':
        return CompactNavButton(
          key: const Key('mini_dock_settings'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onSettings,
        );
      case 'adblock':
        return CompactNavButton(
          key: const Key('mini_dock_adblock'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onAdblock,
        );
      case 'readerMode':
        return CompactNavButton(
          key: const Key('mini_dock_reader'),
          icon: item.icon,
          enabled: true,
          onTap: widget.onReaderMode,
        );
      default:
        return null;
    }
  }

  Widget _dockSlide(List<Widget> children) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: children,
      );
}

class _DockDot extends StatelessWidget {
  final bool active;
  const _DockDot({required this.active});

  @override
  Widget build(BuildContext context) => Container(
        width: 14,
        height: 4,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          color: active
              ? context.ac.accentFrost
              : context.ac.textSecondary.withValues(alpha: 0.4),
        ),
      );
}
