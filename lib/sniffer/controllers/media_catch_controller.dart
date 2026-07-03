import '../media_capture_analyzer.dart';
import '../models/sniffed_media.dart';

/// Manages media capture state: which media to show, active filters,
/// selected indices, and capture analysis delegation.
///
/// This is a pure data/analysis controller with no widget dependencies.
class MediaCatchController {
  bool captureShowAllMedia = false;
  bool hideShortClips = false;
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

  /// Toggle selection of [index].
  void toggleSelection(int index) {
    if (selectedIndices.contains(index)) {
      selectedIndices.remove(index);
    } else {
      selectedIndices.add(index);
    }
  }

  /// Select all visible items. Caller passes the count of visible items.
  void selectAll(int count) {
    selectedIndices.addAll(Iterable.generate(count));
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
      minMediaSizeKb: 0,
      minMediaDurationSeconds: hideShortClips ? 10 : 0,
    );
  }

  /// Filter groups according to the current [activeFilter].
  List<CaptureGroup> filteredGroups(List<CaptureGroup> groups) {
    if (activeFilter == null) return groups;
    return groups.where((g) {
      if (g.primary.media.type == activeFilter) return true;
      // Also include groups where any candidate matches the filter
      return g.candidates.any((c) => c.media.type == activeFilter);
    }).toList(growable: false);
  }

  /// Get all selected media items from the given groups.
  List<SniffedMedia> selectedGroups(List<CaptureGroup> groups) {
    final visible = filteredGroups(groups);
    final result = <SniffedMedia>[];
    var globalIdx = 0;
    for (final group in visible) {
      for (final candidate in group.candidates) {
        if (selectedIndices.contains(globalIdx)) {
          result.add(candidate.media);
        }
        globalIdx++;
      }
    }
    return result;
  }

  /// Compute recommended (auto-selected) indices for the given groups.
  Set<int> recommendedCaptureIndices(List<CaptureGroup> groups) {
    final visible = filteredGroups(groups);
    final indices = <int>{};
    var globalIdx = 0;
    for (final group in visible) {
      if (group.isRecommended && group.candidates.isNotEmpty) {
        // Select ALL candidates of the recommended group so every variant
        // (1080p, 720p, 480p, …) is pre-checked in the flat card layout.
        for (var i = 0; i < group.candidates.length; i++) {
          indices.add(globalIdx + i);
        }
      }
      globalIdx += group.candidates.length;
    }
    return indices;
  }

  /// Human-readable metadata label for a capture group.
  String captureMetadataLabel(CaptureGroup group) {
    final primaryMedia = group.primary.media;
    final primary = group.primary;
    final buf = StringBuffer();
    if (primaryMedia.contentLengthBytes != null &&
        primaryMedia.contentLengthBytes! > 0) {
      buf.write(_formatBytes(primaryMedia.contentLengthBytes!));
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
