import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/media_capture_analyzer.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';

/// Re-sorts capture groups for the Options "Sort by" control.
///
/// Applied **after** analyzer confidence ordering and type/HLS filters so the
/// visible list follows [SniffedMediaSort] on each group's primary media.
List<CaptureGroup> sortCaptureGroups(
  List<CaptureGroup> groups,
  SniffedMediaSort sort,
) {
  if (groups.length <= 1) return groups;
  final list = [...groups];
  list.sort((a, b) => compareSniffedMediaForSort(a.primary.media, b.primary.media, sort));
  return list;
}

/// Comparator matching host `_sortedMedia` for a single pair of media items.
int compareSniffedMediaForSort(
  SniffedMedia a,
  SniffedMedia b,
  SniffedMediaSort sort,
) {
  switch (sort) {
    case SniffedMediaSort.newest:
      return b.sniffedAt.compareTo(a.sniffedAt);
    case SniffedMediaSort.name:
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    case SniffedMediaSort.type:
      return a.type.name.compareTo(b.type.name);
    case SniffedMediaSort.size:
      return (b.contentLengthBytes ?? -1).compareTo(a.contentLengthBytes ?? -1);
    case SniffedMediaSort.duration:
      return (b.duration?.inMilliseconds ?? -1).compareTo(
        a.duration?.inMilliseconds ?? -1,
      );
  }
}

/// Short Title Case label for Options dropdowns.
String sniffedMediaSortLabel(SniffedMediaSort sort) {
  return switch (sort) {
    SniffedMediaSort.newest => 'Newest',
    SniffedMediaSort.name => 'Name',
    SniffedMediaSort.type => 'Type',
    SniffedMediaSort.size => 'Size',
    SniffedMediaSort.duration => 'Duration',
  };
}

/// Short Title Case label for display-mode dropdown.
String sniffedMediaDisplayModeLabel(SniffedMediaDisplayMode mode) {
  return switch (mode) {
    SniffedMediaDisplayMode.size => 'Size',
    SniffedMediaDisplayMode.duration => 'Duration',
    SniffedMediaDisplayMode.both => 'Both',
  };
}
