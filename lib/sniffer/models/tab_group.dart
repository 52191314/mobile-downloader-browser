/// Represents a tab group — a named, optionally color-coded container
/// that organizes open browser tabs.
///
/// Groups persist across app restarts via [TabLifecycleController] using
/// a separate `tab_groups.json` file (independent of `browser_tabs.json`
/// so the per-group metadata can evolve without bloating per-tab
/// payloads).
class TabGroup {
  /// Display name. Trimmed; treated as case-insensitive for collision
  /// detection.
  final String name;

  /// Palette index (0..7) into [TabGroupPalette.swatches]. When this is
  /// the sentinel value [unassignedColorIndex] the group's color is
  /// derived from the name hash by [TabGroupPalette.forName].
  final int colorIndex;

  /// Sentinel meaning "no explicit color override".
  static const int unassignedColorIndex = -1;

  /// When non-null, new tabs whose URL host matches this string are
  /// silently added to this group by [TabLifecycleController.openNewTab].
  /// Stored lower-case.
  final String? autoHost;

  /// User-controlled sort order across groups (lower = earlier in the
  /// sheet). Stable across reloads.
  final int sortOrder;

  /// Creation timestamp (informational; not used for sorting).
  final DateTime createdAt;

  const TabGroup({
    required this.name,
    this.colorIndex = unassignedColorIndex,
    this.autoHost,
    this.sortOrder = 0,
    required this.createdAt,
  });

  /// True when the group has an explicit color override (vs derived).
  bool get hasExplicitColor => colorIndex >= 0 && colorIndex < 8;

  TabGroup copyWith({
    String? name,
    int? colorIndex,
    Object? autoHost = _sentinel,
    int? sortOrder,
    DateTime? createdAt,
  }) {
    return TabGroup(
      name: name ?? this.name,
      colorIndex: colorIndex ?? this.colorIndex,
      autoHost: identical(autoHost, _sentinel)
          ? this.autoHost
          : autoHost as String?,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'colorIndex': colorIndex,
        'autoHost': autoHost,
        'sortOrder': sortOrder,
        'createdAt': createdAt.toIso8601String(),
      };

  factory TabGroup.fromJson(Map<String, dynamic> json) {
    final rawIdx = json['colorIndex'] as int? ?? unassignedColorIndex;
    return TabGroup(
      name: (json['name'] as String? ?? '').trim(),
      colorIndex: rawIdx,
      autoHost: (json['autoHost'] as String?)?.toLowerCase(),
      sortOrder: json['sortOrder'] as int? ?? 0,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TabGroup &&
          other.name.toLowerCase() == name.toLowerCase() &&
          other.colorIndex == colorIndex &&
          other.autoHost == autoHost &&
          other.sortOrder == sortOrder);

  @override
  int get hashCode => Object.hash(
        name.toLowerCase(),
        colorIndex,
        autoHost,
        sortOrder,
      );

  @override
  String toString() => 'TabGroup($name, color=$colorIndex, autoHost=$autoHost)';
}

const Object _sentinel = Object();