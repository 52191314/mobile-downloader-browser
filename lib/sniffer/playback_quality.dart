import 'models/sniffed_media.dart';

/// Sort qualities by height desc, then bandwidth desc.
List<SniffedMedia> sortQualityMedia(List<SniffedMedia> list) {
  final sorted = [...list];
  sorted.sort((a, b) {
    final ah = a.height ?? -1;
    final bh = b.height ?? -1;
    if (ah != bh) return bh.compareTo(ah);
    final ab = a.bandwidth ?? -1;
    final bb = b.bandwidth ?? -1;
    return bb.compareTo(ab);
  });
  return sorted;
}

/// Prefer the user's selected capture row URL, then same height, then top.
SniffedMedia pickStartQuality(
  SniffedMedia media,
  List<SniffedMedia> qualities,
) {
  if (qualities.isEmpty) return media;
  for (final q in qualities) {
    if (q.url == media.url) return q;
  }
  if (media.height != null) {
    for (final q in qualities) {
      if (q.height == media.height) return q;
    }
  }
  if (media.bandwidth != null) {
    for (final q in qualities) {
      if (q.bandwidth == media.bandwidth) return q;
    }
  }
  // Qualities are height-desc; first is best.
  return qualities.first;
}

/// Builds a short subtitle for the floating play button.
String? floatingPlayerSubtitle(SniffedMedia? media) {
  if (media == null) return null;
  final h = media.height;
  if (h != null && h > 0) return '${h}p';
  if (media.url.toLowerCase().contains('.m3u8')) return 'HLS';
  return null;
}
