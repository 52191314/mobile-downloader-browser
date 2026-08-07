/// Aurora Watcher — on-device RSS/page monitor + auto-enqueue.
///
/// Gate: [ProFeature.watcher] (Ultra tier only).
///
/// Watchers run as an in-app periodic timer while the app process is alive;
/// when a new item is detected, the URL is auto-enqueued into the download
/// queue. Checks do not run while the process is killed (no OS scheduling).
library;

/// Type of content source to watch.
enum WatchKind {
  /// Standard RSS/Atom feed.
  rss,

  /// Monitor a web page for new links matching a pattern.
  page,
}

/// A single watch rule that periodically checks a feed or page for new items.
class WatchRule {
  final String id;
  final WatchKind kind;
  final String url;
  final String? label;

  /// Optional regex to filter links/titles. Only matching items are enqueued.
  final String? matchRegex;

  /// Minimum interval between checks (default: 1 hour).
  final Duration minInterval;

  /// Whether this rule is active.
  bool enabled;

  /// Last time this rule was checked.
  DateTime? lastCheckedAt;

  /// Set of seen item identifiers (GUID for RSS, link hash for page).
  Set<String> seenIds;

  /// Maximum number of seen IDs to retain (prevents unbounded growth).
  static const int maxSeenIds = 500;

  /// When this rule was created.
  final DateTime createdAt;

  WatchRule({
    required this.id,
    required this.kind,
    required this.url,
    this.label,
    this.matchRegex,
    this.minInterval = const Duration(hours: 1),
    this.enabled = true,
    this.lastCheckedAt,
    Set<String>? seenIds,
    DateTime? createdAt,
  })  : seenIds = seenIds ?? {},
        createdAt = createdAt ?? DateTime.now();

  /// Returns a copy with the given fields replaced.
  WatchRule copyWith({
    String? id,
    WatchKind? kind,
    String? url,
    String? label,
    String? matchRegex,
    Duration? minInterval,
    bool? enabled,
    DateTime? lastCheckedAt,
    Set<String>? seenIds,
    DateTime? createdAt,
  }) {
    return WatchRule(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      url: url ?? this.url,
      label: label ?? this.label,
      matchRegex: matchRegex ?? this.matchRegex,
      minInterval: minInterval ?? this.minInterval,
      enabled: enabled ?? this.enabled,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      seenIds: seenIds ?? this.seenIds,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Whether enough time has passed since the last check.
  bool get isDue {
    if (lastCheckedAt == null) return true;
    return DateTime.now().difference(lastCheckedAt!) >= minInterval;
  }

  /// Add a newly discovered item ID and trim if over capacity.
  void addSeen(String id) {
    seenIds.add(id);
    if (seenIds.length > maxSeenIds) {
      // Keep the most recent entries
      final keep = seenIds.length - maxSeenIds ~/ 2;
      seenIds = seenIds
          .toList()
          .sublist(seenIds.length - keep)
          .toSet();
    }
  }

  /// Serialize to JSON for persistence.
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'url': url,
        'label': label,
        'matchRegex': matchRegex,
        'minIntervalMinutes': minInterval.inMinutes,
        'enabled': enabled,
        'lastCheckedAt': lastCheckedAt?.toIso8601String(),
        'seenIds': seenIds.toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  /// Deserialize from JSON.
  factory WatchRule.fromJson(Map<String, dynamic> json) {
    return WatchRule(
      id: json['id'] as String,
      kind: WatchKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => WatchKind.rss,
      ),
      url: json['url'] as String,
      label: json['label'] as String?,
      matchRegex: json['matchRegex'] as String?,
      minInterval: Duration(
        minutes: (json['minIntervalMinutes'] as num?)?.toInt() ?? 60,
      ),
      enabled: json['enabled'] as bool? ?? true,
      lastCheckedAt: json['lastCheckedAt'] != null
          ? DateTime.tryParse(json['lastCheckedAt'] as String)
          : null,
      seenIds: (json['seenIds'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toSet() ??
          {},
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
    );
  }
}
