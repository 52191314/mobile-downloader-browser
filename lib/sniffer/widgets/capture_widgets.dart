import 'package:flutter/material.dart';
import 'package:aurora_downloader/ui/widgets/dock_order_store.dart';

import '../../theme/aurora_palette.dart';
import '../models/browser_tab.dart';

/// Compact, flat icon button used in the browser bottom dock.
class CompactNavButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const CompactNavButton({
    super.key,
    required this.icon,
    this.enabled = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 18),
        color: enabled ? context.ac.textPrimary : context.ac.textDisabled,
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}

/// Two-slide browser dock shown in the Sniffer screen's bottom strip.
///
/// Slide 1: Backward · Forward · Sniffer · Download · Tab
/// Slide 2: Browser Tools · Sniffer · History · Bookmarks · Settings
///
/// Swipe horizontally to move between slides. Icons are flat (no circle
/// outline). A small pill indicator shows the active slide.
///
/// Icon order comes from [dockOrderStore] (Settings → Appearance → Bottom dock).
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
