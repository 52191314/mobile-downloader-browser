/// Aurora Watcher service — periodic RSS/page monitor + auto-enqueue.
///
/// Gate: [ProFeature.watcher] (Ultra tier only).
///
/// Architecture:
/// - Runs as an in-app periodic timer while the app process is alive
///   (foreground or backgrounded). It is NOT an OS-scheduled background
///   task: if the process is killed, checks stop until the app reopens.
/// - Fetches RSS feeds or page HTML using Dart HTTP client.
/// - Diffs against [WatchRule.seenIds] to identify new items.
/// - Auto-enqueues new URLs into the download queue.
/// - Fires [onNewItems] when new items are enqueued (host shows a
///   local notification).
///
/// Battery note: the loop ticks every 5 minutes, but each rule only checks
/// when its own [WatchRule.minInterval] has elapsed (default 1 hour).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'watcher_models.dart';
import 'watcher_store.dart';

/// Simple RSS item extracted from a feed.
class _FeedItem {
  final String? guid;
  final String? link;
  final String? title;

  const _FeedItem({this.guid, this.link, this.title});
}

/// Manages watch rules and performs periodic checks.
class WatcherService extends ChangeNotifier {
  List<WatchRule> _rules = [];
  Timer? _timer;
  bool _running = false;

  /// Callback to enqueue a download URL.
  final Future<void> Function(String url, {String? label})? onEnqueue;

  /// Fired with a human-readable summary when new items were enqueued.
  /// The host typically surfaces this as a local notification.
  final void Function(String message)? onNewItems;

  WatcherService({this.onEnqueue, this.onNewItems});

  /// Read-only view of all rules.
  List<WatchRule> get rules => List.unmodifiable(_rules);

  /// Whether the watcher loop is active.
  bool get isRunning => _running;

  /// Load rules from persistent storage and start the watcher loop.
  Future<void> initialize() async {
    _rules = await WatcherStore.load();
    notifyListeners();
    _startLoop();
  }

  /// Add a new watch rule.
  Future<void> addRule(WatchRule rule) async {
    _rules.add(rule);
    await _persist();
    notifyListeners();
  }

  /// Update an existing watch rule.
  Future<void> updateRule(WatchRule rule) async {
    final idx = _rules.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) {
      _rules[idx] = rule;
      await _persist();
      notifyListeners();
    }
  }

  /// Remove a watch rule by ID.
  Future<void> removeRule(String id) async {
    _rules.removeWhere((r) => r.id == id);
    await _persist();
    notifyListeners();
  }

  /// Toggle a rule on/off.
  Future<void> toggleRule(String id) async {
    final idx = _rules.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      _rules[idx].enabled = !_rules[idx].enabled;
      await _persist();
      notifyListeners();
    }
  }

  /// Manually trigger a check for a specific rule.
  Future<void> checkNow(String ruleId) async {
    final rule = _rules.firstWhere(
      (r) => r.id == ruleId,
      orElse: () => _rules.first,
    );
    await _checkRule(rule);
    notifyListeners();
  }

  /// Stop the watcher loop.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internal loop
  // ---------------------------------------------------------------------------

  void _startLoop() {
    _timer?.cancel();
    _running = true;
    // Check every 5 minutes; individual rules have their own minInterval gate.
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _checkAll());
    // Also run an immediate check for rules that are due.
    _checkAll();
  }

  Future<void> _checkAll() async {
    if (!_running) return;
    for (final rule in _rules) {
      if (!rule.enabled || !rule.isDue) continue;
      await _checkRule(rule);
    }
  }

  Future<void> _checkRule(WatchRule rule) async {
    try {
      final items = await _fetchItems(rule);
      final newItems = <_FeedItem>[];

      for (final item in items) {
        final id = item.guid ?? item.link ?? item.title ?? '';
        if (id.isEmpty) continue;

        if (!rule.seenIds.contains(id)) {
          // Check match regex if set
          if (rule.matchRegex != null && rule.matchRegex!.isNotEmpty) {
            final title = item.title ?? item.link ?? '';
            try {
              if (!RegExp(rule.matchRegex!).hasMatch(title)) continue;
            } catch (_) {
              // Invalid regex, skip filter
            }
          }
          final link = item.link ?? item.guid;
          if (link != null && link.isNotEmpty) {
            newItems.add(item);
            rule.addSeen(id);
          }
        }
      }

      rule.lastCheckedAt = DateTime.now();

      // Enqueue new items
      for (final item in newItems) {
        final link = item.link ?? item.guid;
        if (link != null && link.isNotEmpty) {
          try {
            await onEnqueue?.call(link, label: item.title);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('[WatcherService] enqueue failed: $e');
            }
          }
        }
      }

      // Notify the host when anything was actually enqueued.
      if (newItems.isNotEmpty) {
        final source = rule.label ?? rule.url;
        final count = newItems.length;
        onNewItems?.call('$count new item${count == 1 ? '' : 's'} · $source');
      }

      await _persist();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[WatcherService] check failed for ${rule.url}: $e');
      }
      // Don't update lastCheckedAt on failure so it retries next cycle.
    }
  }

  // ---------------------------------------------------------------------------
  // Fetch items
  // ---------------------------------------------------------------------------

  Future<List<_FeedItem>> _fetchItems(WatchRule rule) async {
    switch (rule.kind) {
      case WatchKind.rss:
        return _fetchRss(rule.url);
      case WatchKind.page:
        return _fetchPage(rule.url);
    }
  }

  Future<List<_FeedItem>> _fetchRss(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) return [];
      return _parseRss(response.body);
    } catch (_) {
      return [];
    }
  }

  Future<List<_FeedItem>> _fetchPage(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) return [];
      return _parsePage(response.body);
    } catch (_) {
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Parsers (minimal, regex-based — full XML parser is heavy)
  // ---------------------------------------------------------------------------

  List<_FeedItem> _parseRss(String body) {
    final items = <_FeedItem>[];
    // Match <item>...</item> blocks
    final itemPattern = RegExp(
      r'<item[^>]*>(.*?)</item>',
      dotAll: true,
    );
    for (final match in itemPattern.allMatches(body)) {
      final block = match.group(1) ?? '';
      final guid = _extractTag(block, 'guid');
      final link = _extractTag(block, 'link');
      final title = _extractTag(block, 'title');
      items.add(_FeedItem(guid: guid, link: link, title: title));
    }
    // Fallback: match <entry> blocks (Atom feed)
    final entryPattern = RegExp(
      r'<entry[^>]*>(.*?)</entry>',
      dotAll: true,
    );
    for (final match in entryPattern.allMatches(body)) {
      final block = match.group(1) ?? '';
      final id = _extractTag(block, 'id');
      final link = _extractLinkAttr(block);
      final title = _extractTag(block, 'title');
      items.add(_FeedItem(guid: id, link: link, title: title));
    }
    return items;
  }

  List<_FeedItem> _parsePage(String body) {
    final items = <_FeedItem>[];
    // Extract all <a href="..."> links with optional text
    final linkPattern = RegExp(
      r'<a\s+[^>]*href=["' "'" r']([^"' "'" r']+)["' "'" r'][^>]*>(.*?)</a>',
      dotAll: true,
    );
    for (final match in linkPattern.allMatches(body)) {
      final href = match.group(1) ?? '';
      final text = _stripHtml(match.group(2) ?? '');
      items.add(_FeedItem(
        guid: href, // use URL as unique ID for pages
        link: href,
        title: text,
      ));
    }
    return items;
  }

  String? _extractTag(String block, String tag) {
    final match = RegExp('<$tag[^>]*>(.*?)</$tag>', dotAll: true).firstMatch(block);
    return _stripHtml(match?.group(1) ?? '');
  }

  String? _extractLinkAttr(String block) {
    final match = RegExp(
      r'<link[^>]*href=["' "'" r']([^"' "'" r']+)["' "'" r']',
    ).firstMatch(block);
    return match?.group(1);
  }

  String _stripHtml(String input) {
    return input
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'&[^;]+;'), '')
        .trim();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> _persist() async {
    await WatcherStore.save(_rules);
  }
}
