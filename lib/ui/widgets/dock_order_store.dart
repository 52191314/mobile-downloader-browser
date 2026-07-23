import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Metadata for one dock button slot.
class DockItem {
  /// Stable string id used for persistence (e.g. `'back'`, `'sniffer'`).
  final String id;

  /// Icon displayed on the dock button.
  final IconData icon;

  /// Human-readable label shown in the Appearance editor.
  final String label;

  const DockItem({required this.id, required this.icon, required this.label});
}

/// All available dock items the user can assign to a slide.
///
/// IDs must stay stable — changing them would invalidate persisted orders.
const kAllDockItems = <DockItem>[
  DockItem(id: 'back', icon: Icons.arrow_back_ios_new, label: 'Go back'),
  DockItem(id: 'forward', icon: Icons.arrow_forward_ios, label: 'Go forward'),
  DockItem(id: 'sniffer', icon: Icons.radar, label: 'Sniffed media'),
  DockItem(id: 'downloads', icon: Icons.download_rounded, label: 'Downloads'),
  DockItem(id: 'tabs', icon: Icons.tab, label: 'Tabs'),
  DockItem(id: 'home', icon: Icons.home_rounded, label: 'Home'),
  DockItem(id: 'menu', icon: Icons.menu_rounded, label: 'Browser tools'),
  DockItem(id: 'history', icon: Icons.history_rounded, label: 'History'),
  // List/menu icon — distinct from the address-bar star (add current page).
  DockItem(id: 'bookmarks', icon: Icons.bookmarks_rounded, label: 'Bookmarks'),
  DockItem(id: 'settings', icon: Icons.settings_rounded, label: 'Settings'),
  DockItem(id: 'adblock', icon: Icons.shield, label: 'Adblock'),
  DockItem(id: 'readerMode', icon: Icons.auto_stories, label: 'Reader mode'),
];

/// Product primary bar (fixed in UI):
/// Back · Forward · Queue · Radar · Bookmarks menu · Tabs · Menu.
/// Star (toggle current page) sits on the address bar, not the primary strip.
/// Appearance editor still uses these defaults for reset / custom slides.
const kDefaultSlide1Order = ['back', 'forward', 'sniffer', 'tabs', 'menu'];
const kDefaultSlide2Order = [
  'home',
  'history',
  'bookmarks',
  'adblock',
  'readerMode',
];

/// Max buttons per dock slide (matches the even-spaced row layout).
const kMaxDockItemsPerSlide = 5;

/// Lightweight store for dock button order, persisted to `dock_order.json`.
///
/// Extends [ChangeNotifier] so the browser dock rebuilds when the user
/// reorders icons in Settings → Appearance.
class DockOrderStore extends ChangeNotifier {
  static DockOrderStore? _instance;

  List<String> _slide1 = List.unmodifiable(kDefaultSlide1Order);
  List<String> _slide2 = List.unmodifiable(kDefaultSlide2Order);
  bool _loaded = false;

  DockOrderStore._();

  factory DockOrderStore() {
    _instance ??= DockOrderStore._();
    return _instance!;
  }

  /// The ordered item IDs for slide 1.
  List<String> get slide1Order => _slide1;

  /// The ordered item IDs for slide 2.
  List<String> get slide2Order => _slide2;

  /// Whether an explicit order differs from the factory defaults.
  bool get isCustomized =>
      !_listEquals(_slide1, kDefaultSlide1Order) ||
      !_listEquals(_slide2, kDefaultSlide2Order);

  /// Load persisted order from disk. Safe to call multiple times; only the
  /// first call reads from disk.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/dock_order.json');
      if (!file.existsSync()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is Map) {
        final s1 = json['slide1'];
        final s2 = json['slide2'];
        if (s1 is List) {
          _slide1 = List.unmodifiable(
            s1
                .whereType<String>()
                .where((id) => _byId(id) != null)
                .take(kMaxDockItemsPerSlide)
                .toList(),
          );
        }
        if (s2 is List) {
          _slide2 = List.unmodifiable(
            s2
                .whereType<String>()
                .where((id) => _byId(id) != null)
                .take(kMaxDockItemsPerSlide)
                .toList(),
          );
        }
        notifyListeners();
      }
    } catch (_) {
      // Corrupt file — keep defaults.
    }
  }

  /// Persist the current slide orders to disk.
  Future<void> save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/dock_order.json');
      await file.writeAsString(
        jsonEncode({'slide1': _slide1, 'slide2': _slide2}),
      );
    } catch (_) {}
  }

  /// Replace the order for both slides and persist.
  Future<void> update({
    required List<String> slide1,
    required List<String> slide2,
  }) async {
    _slide1 = List.unmodifiable(
      slide1
          .where((id) => _byId(id) != null)
          .take(kMaxDockItemsPerSlide)
          .toList(),
    );
    _slide2 = List.unmodifiable(
      slide2
          .where((id) => _byId(id) != null)
          .take(kMaxDockItemsPerSlide)
          .toList(),
    );
    await save();
    notifyListeners();
  }

  /// Reset both slides to defaults and persist.
  Future<void> reset() async {
    _slide1 = List.unmodifiable(kDefaultSlide1Order);
    _slide2 = List.unmodifiable(kDefaultSlide2Order);
    await save();
    notifyListeners();
  }

  /// Look up a [DockItem] by id. Returns `null` for unknown ids.
  static DockItem? byId(String id) => _byId(id);

  static DockItem? _byId(String id) {
    for (final item in kAllDockItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Shorthand to get the singleton store.
DockOrderStore get dockOrderStore => DockOrderStore();
