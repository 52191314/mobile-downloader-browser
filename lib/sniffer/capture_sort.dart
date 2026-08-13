import '../settings/download_settings.dart';
import 'models/sniffed_media.dart';

/// Sorts sniffed media for the catch sheet according to [sort].
///
/// The sort is a *total order*: after the mode's primary key, ties are broken
/// by [SniffedMedia.sniffedAt] (newest first) and finally by
/// [SniffedMedia.url] (an item's unique, stable identity). Dart's `List.sort`
/// is not guaranteed to be stable for lists longer than 32 elements, so
/// without these tie-breakers equal-key items would reorder on every re-sort
/// and the sheet would flicker. With a total order, re-sorting an already
/// sorted list is a stable no-op.
List<SniffedMedia> sortSniffedMedia(
  List<SniffedMedia> media,
  SniffedMediaSort sort,
) {
  final list = [...media];
  if (list.length <= 1) return list;

  // Precompute lowercased names once per element so the name comparator never
  // calls toLowerCase() inside the sort loop (O(n) instead of O(n log n)).
  final Map<SniffedMedia, String>? lowerNames = sort == SniffedMediaSort.name
      ? <SniffedMedia, String>{
          for (final m in list) m: m.name.toLowerCase(),
        }
      : null;

  list.sort((a, b) {
    final primary = _comparePrimary(a, b, sort, lowerNames);
    if (primary != 0) return primary;
    final byTime = b.sniffedAt.compareTo(a.sniffedAt);
    if (byTime != 0) return byTime;
    return a.url.compareTo(b.url);
  });
  return list;
}

int _comparePrimary(
  SniffedMedia a,
  SniffedMedia b,
  SniffedMediaSort sort,
  Map<SniffedMedia, String>? lowerNames,
) {
  switch (sort) {
    case SniffedMediaSort.newest:
      return b.sniffedAt.compareTo(a.sniffedAt);
    case SniffedMediaSort.name:
      final names = lowerNames!;
      return _compareNatural(names[a]!, names[b]!);
    case SniffedMediaSort.type:
      return a.type.name.compareTo(b.type.name);
    case SniffedMediaSort.size:
      return _compareSize(a, b);
    case SniffedMediaSort.duration:
      return _compareDuration(a, b);
  }
}

/// Numeric-aware ("natural") comparison of two already-lowercased names so
/// that `Episode 2` sorts before `Episode 10` rather than after it under
/// plain lexicographic ordering. Each name is split into runs of digits /
/// non-digits and compared run-by-run: digit runs compare numerically (by
/// significant-digit count after trimming leading zeros, so arbitrarily long
/// numbers never overflow an int), and a digit run sorts before a non-digit
/// run at the same position.
int _compareNatural(String a, String b) {
  final ar = _runs(a);
  final br = _runs(b);
  final n = ar.length < br.length ? ar.length : br.length;
  for (var i = 0; i < n; i++) {
    final ra = ar[i];
    final rb = br[i];
    final raIsDigit = _isDigitRun(ra);
    final rbIsDigit = _isDigitRun(rb);
    final int c;
    if (raIsDigit && rbIsDigit) {
      c = _compareNumericRun(ra, rb);
    } else if (raIsDigit != rbIsDigit) {
      c = raIsDigit ? -1 : 1;
    } else {
      c = ra.compareTo(rb);
    }
    if (c != 0) return c;
  }
  // One name is a prefix of the other: the shorter sorts first.
  return ar.length.compareTo(br.length);
}

final RegExp _nameRun = RegExp(r'[0-9]+|[^0-9]+');

List<String> _runs(String s) =>
    _nameRun.allMatches(s).map((m) => m.group(0)!).toList();

bool _isDigitRun(String run) {
  final c = run.codeUnitAt(0);
  return c >= 0x30 && c <= 0x39;
}

int _compareNumericRun(String a, String b) {
  final aa = _stripLeadingZeros(a);
  final bb = _stripLeadingZeros(b);
  if (aa.length != bb.length) return aa.length.compareTo(bb.length);
  return aa.compareTo(bb);
}

String _stripLeadingZeros(String s) {
  var i = 0;
  while (i < s.length - 1 && s.codeUnitAt(i) == 0x30) {
    i++;
  }
  return s.substring(i);
}

/// Compares two items for the `size` mode. Unknown sizes
/// ([SniffedMedia.contentLengthBytes] == null) sort to the bottom — a
/// deliberate UX choice: items with a known size are more informative and
/// should surface first. Unknown items are still stably ordered among
/// themselves by the shared `sniffedAt`/`url` tie-breakers, so they do not
/// jump around between rebuilds.
int _compareSize(SniffedMedia a, SniffedMedia b) {
  final as = a.contentLengthBytes;
  final bs = b.contentLengthBytes;
  if (as != null && bs != null) return bs.compareTo(as);
  if (as == null && bs == null) return 0;
  return as == null ? 1 : -1;
}

/// Mirrors [_compareSize] for [SniffedMedia.duration]: unknown durations sink
/// to the bottom and are stably ordered among themselves by the tie-breakers.
int _compareDuration(SniffedMedia a, SniffedMedia b) {
  final ad = a.duration?.inMilliseconds;
  final bd = b.duration?.inMilliseconds;
  if (ad != null && bd != null) return bd.compareTo(ad);
  if (ad == null && bd == null) return 0;
  return ad == null ? 1 : -1;
}
