import 'dart:async';

import 'package:flutter/widgets.dart';

import '../browser_controller.dart';
import '../media_sniffer_engine.dart';
import 'page_meta.dart';
import 'sniffed_media.dart';

class BrowserTab {
  final String id;
  final SnifferBrowserController controller;
  final MediaSnifferEngine snifferEngine;
  final TextEditingController addressController;
  final bool ownsEngine;
  Timer? videoPollTimer;
  StreamSubscription<SniffedMedia>? mediaSubscription;
  String? userAgent;
  String? title;
  String? currentUrl;
  String? groupName;
  bool canGoBack = false;
  bool canGoForward = false;
  PageMeta pageMeta = const PageMeta();
  /// Per-tab cache of HLS playlist response bodies captured by
  /// browser_guard.js. Keyed by URL, value is the raw playlist text.
  /// Cleared on each page navigation.
  Map<String, String> hlsPlaylistCache = {};
  /// Per-tab cache of Authorization headers captured during sniffing.
  /// Keyed by media URL. Populated by [_sniffWithLiveHeaders] so the
  /// header survives the sanitization in [sanitizeSniffedMediaHeaders]
  /// and can be re-added at download time. Cleared on each page navigation.
  Map<String, String> authHeaderCache = {};

  BrowserTab({
    required this.id,
    required this.controller,
    required this.snifferEngine,
    required this.addressController,
    this.ownsEngine = true,
    this.groupName,
  });

  void dispose() {
    videoPollTimer?.cancel();
    mediaSubscription?.cancel();
    addressController.dispose();
    snifferEngine.clearCache();
    if (ownsEngine) {
      snifferEngine.dispose();
    }
    controller.dispose();
  }

  void detachAddressListener(void Function() listener) {
    addressController.removeListener(listener);
  }
}
