import '../media_capture_analyzer.dart';
import '../models/sniffed_media.dart';

/// Manages media capture state: which media to show, active filters,
/// selected indices, and capture analysis delegation.
///
/// This is a pure data/analysis controller with no widget dependencies.
///
/// **Selection index space:** [selectedIndices] are indices into the
/// **currently displayed** [List<CaptureGroup>] (post short-clip, type
/// filter, and HLS post-filter). Callers must pass that same list into
/// [recommendedGroupIndices] / [selectedFrom] — do not re-analyze without
/// those transforms.
class MediaCatchController {
  bool captureShowAllMedia = false;
  MediaType? activeFilter;
  final Set<int> selectedIndices = {};
  final MediaCaptureAnalyzer captureAnalyzer =
      const MediaCaptureAnalyzer();

  MediaCatchController();

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  /// Clear the current selection.
  void clearSelection() => selectedIndices.clear();

  /// Toggle selection of a **displayed-group** [index].
  void toggleSelection(int index) {
    if (selectedIndices.contains(index)) {
      selectedIndices.remove(index);
    } else {
      selectedIndices.add(index);
    }
  }

  /// Select all visible groups. Caller passes the count of displayed groups.
  ///
  /// Clears any prior selection first so stale indices above [count] cannot
  /// resurrect when the displayed list later grows.
  void selectAll(int count) {
    selectedIndices
      ..clear()
      ..addAll(Iterable.generate(count));
  }

  /// Number of selected items that fall within [visibleCount].
  int selectedCount(int visibleCount) =>
      selectedIndices.where((i) => i < visibleCount).length;

  // ---------------------------------------------------------------------------
  // Filtering & analysis (delegates to MediaCaptureAnalyzer)
  // ---------------------------------------------------------------------------

  /// Analyze and group the given media list using current settings.
  MediaCaptureResult analyze(List<SniffedMedia> media) {
    return captureAnalyzer.analyze(
      media,
      showAll: captureShowAllMedia,
    );
  }

  /// Filter groups according to the current [activeFilter].
  ///
  /// Used by the sheet pipeline to build the displayed list. Selection
  /// helpers ([recommendedGroupIndices], [selectedFrom]) do **not** call
  /// this again — pass the already-filtered displayed list.
  List<CaptureGroup> filteredGroups(List<CaptureGroup> groups) {
    if (activeFilter == null) return groups;
    return groups.where((g) {
      if (g.primary.media.type == activeFilter) return true;
      // Also include groups where any candidate matches the filter
      return g.candidates.any((c) => c.media.type == activeFilter);
    }).toList(growable: false);
  }

  /// Selected capture groups from [visibleGroups] (already displayed list).
  ///
  /// Indices in [selectedIndices] / the optional [indices] override refer
  /// to positions in [visibleGroups], not flat candidates.
  ///
  /// Batch download / multi-select consumers (PR3 sticky bar) must resolve
  /// selection **only** via this helper with the same `displayedGroups` the
  /// list built — never re-filter or re-analyze.
  List<CaptureGroup> selectedFrom(
    List<CaptureGroup> visibleGroups, [
    Set<int>? indices,
  ]) {
    final selected = indices ?? selectedIndices;
    return [
      for (var i = 0; i < visibleGroups.length; i++)
        if (selected.contains(i)) visibleGroups[i],
    ];
  }

  /// Indices into [visibleGroups] for groups marked recommended.
  ///
  /// [visibleGroups] must already be the displayed list (short-clip + type
  /// + HLS post-filter). Does **not** re-filter via [filteredGroups].
  Set<int> recommendedGroupIndices(List<CaptureGroup> visibleGroups) {
    return {
      for (var i = 0; i < visibleGroups.length; i++)
        if (visibleGroups[i].isRecommended) i,
    };
  }

  /// Human-readable metadata label for a capture group.
  String captureMetadataLabel(CaptureGroup group) {
    final primaryMedia = group.primary.media;
    final primary = group.primary;
    final buf = StringBuffer();
    if (primaryMedia.contentLengthBytes != null &&
        primaryMedia.contentLengthBytes! > 0) {
      final sizeLabel = _formatBytes(primaryMedia.contentLengthBytes!);
      buf.write(
        primaryMedia.isSizeEstimated ? '~$sizeLabel' : sizeLabel,
      );
    }
    if (group.variantCount > 1) {
      if (buf.isNotEmpty) buf.write(' · ');
      buf.write('${group.variantCount} variants');
    }
    if (primary.qualityLabel != null) {
      if (buf.isNotEmpty) buf.write(' · ');
      buf.write(primary.qualityLabel);
    }
    return buf.toString();
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  void dispose() {
    selectedIndices.clear();
  }
}
