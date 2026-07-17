part of '../sniffer_screen.dart';

class _CompactNavButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _CompactNavButton({
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
class _BrowserDock extends StatefulWidget {
  final BrowserTab tab;
  final VoidCallback onSniffer;
  final VoidCallback onDownload;
  final VoidCallback onTab;
  final VoidCallback onBrowserTools;
  final VoidCallback onSettings;
  final VoidCallback onHistory;
  final VoidCallback onBookmarks;

  const _BrowserDock({
    required this.tab,
    required this.onSniffer,
    required this.onDownload,
    required this.onTab,
    required this.onBrowserTools,
    required this.onSettings,
    required this.onHistory,
    required this.onBookmarks,
  });

  @override
  State<_BrowserDock> createState() => _BrowserDockState();
}

class _BrowserDockState extends State<_BrowserDock> {
  final PageController _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final badgeCount = tab.snifferEngine.detectedMedia.length;

    final slide1 = <Widget>[
      _CompactNavButton(
        key: const Key('sniffer_back_button'),
        icon: Icons.arrow_back_ios_new,
        enabled: tab.canGoBack,
        onTap: tab.canGoBack ? () => tab.controller.goBack() : null,
      ),
      _CompactNavButton(
        key: const Key('sniffer_forward_button'),
        icon: Icons.arrow_forward_ios,
        enabled: tab.canGoForward,
        onTap: tab.canGoForward ? () => tab.controller.goForward() : null,
      ),
      _CompactNavButton(
        key: const Key('sniffer_sniffer_button'),
        icon: badgeCount > 0 ? Icons.radar : Icons.add,
        enabled: true,
        onTap: widget.onSniffer,
      ),
      _CompactNavButton(
        key: const Key('mini_dock_queue'),
        icon: Icons.download_rounded,
        enabled: true,
        onTap: widget.onDownload,
      ),
      _CompactNavButton(
        key: const Key('browser_tabs_button'),
        icon: Icons.tab,
        enabled: true,
        onTap: widget.onTab,
      ),
    ];

    final slide2 = <Widget>[
      _CompactNavButton(
        key: const Key('mini_dock_menu'),
        icon: Icons.menu_rounded,
        enabled: true,
        onTap: widget.onBrowserTools,
      ),
      _CompactNavButton(
        key: const Key('mini_dock_history'),
        icon: Icons.history_rounded,
        enabled: true,
        onTap: widget.onHistory,
      ),
      _CompactNavButton(
        key: const Key('slide2_sniffer_button'),
        icon: badgeCount > 0 ? Icons.radar : Icons.add,
        enabled: true,
        onTap: widget.onSniffer,
      ),
      _CompactNavButton(
        key: const Key('mini_dock_bookmarks'),
        icon: Icons.star_rounded,
        enabled: true,
        onTap: widget.onBookmarks,
      ),
      _CompactNavButton(
        key: const Key('mini_dock_settings'),
        icon: Icons.tune_rounded,
        enabled: true,
        onTap: widget.onSettings,
      ),
    ];

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
