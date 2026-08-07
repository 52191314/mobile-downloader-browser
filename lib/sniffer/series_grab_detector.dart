/// Series auto-grab detector (P2 / R-PR-05).
///
/// Extracts episode links from the current page using heuristics:
///
/// 1. Numbered sibling links on the current page (anchors with text matching
///    patterns like `EP 01`, `E01`, `S01E02`, `第N集`, `#01`).
/// 2. Pagination "next" chain following same path pattern up to maxDepth=10,
///    collecting links from each page.
///
/// Results are sorted by parsed episode number (ascending) then DOM order.
/// Free users are capped at first-5 via [FreeTaste.evaluate].
library;


/// Parsed episode descriptor from a link.
class EpisodeLink {
  /// Full target URL.
  final String url;

  /// Display text of the link element (for UI).
  final String? label;

  /// Parsed episode number (0-based heuristic; higher = later).
  /// Season-part episodes use `season * 1000 + episode`.
  final int order;

  /// Optional season number (e.g. 2 for S02E05).
  final int? season;

  /// Optional episode number within a season (e.g. 5 for S02E05).
  final int? episodeNumber;

  const EpisodeLink({
    required this.url,
    this.label,
    required this.order,
    this.season,
    this.episodeNumber,
  });

  @override
  String toString() =>
      'EpisodeLink(url=$url, order=$order, season=$season, ep=$episodeNumber)';
}

/// Parses an episode number from a link [text] string.
///
/// Returns `null` when no recognizable episode pattern is found.
///
/// Recognized patterns (case-insensitive):
/// - `EP01`, `ep 01`, `EP.01` → order=1
/// - `E01`, `e01` → order=1
/// - `S01E02`, `s1e2` → order=1002, season=1, episode=2
/// - `第1集`, `第01話` → order=1
/// - `#01`, `#1` → order=1
/// - Bare `01`, `02` at start or after `/` → order=1
EpisodeLink? parseEpisodeLink(String text, String url) {
  final t = text.trim();
  if (t.isEmpty) return null;

  // S01E02 / s1e2 pattern (season+episode).
  final seasonEp =
      RegExp(r'[Ss]\s*(\d{1,3})\s*[Ee]\s*(\d{1,3})').firstMatch(t);
  if (seasonEp != null) {
    final s = int.parse(seasonEp.group(1)!);
    final e = int.parse(seasonEp.group(2)!);
    return EpisodeLink(
      url: url,
      label: t,
      order: s * 1000 + e,
      season: s,
      episodeNumber: e,
    );
  }

  // EP01 / ep 01 / EP.01 pattern.
  final ep = RegExp(r'ep\.?\s*(\d{1,4})', caseSensitive: false).firstMatch(t);
  if (ep != null) {
    final e = int.parse(ep.group(1)!);
    return EpisodeLink(
      url: url,
      label: t,
      order: e,
      episodeNumber: e,
    );
  }

  // Standalone E01 / e01 pattern.
  final eOnly =
      RegExp(r'^\s*e\.?\s*(\d{1,4})\s*$', caseSensitive: false).firstMatch(t);
  if (eOnly != null) {
    final e = int.parse(eOnly.group(1)!);
    return EpisodeLink(
      url: url,
      label: t,
      order: e,
      episodeNumber: e,
    );
  }

  // Chinese/Japanese: 第N集 / 第N話
  final cjk = RegExp(r'第\s*(\d{1,4})\s*[集話回]').firstMatch(t);
  if (cjk != null) {
    final e = int.parse(cjk.group(1)!);
    return EpisodeLink(
      url: url,
      label: t,
      order: e,
      episodeNumber: e,
    );
  }

  // Hash/numbered: #01 / #1
  final hashNum = RegExp(r'#\s*(\d{1,4})').firstMatch(t);
  if (hashNum != null) {
    final e = int.parse(hashNum.group(1)!);
    return EpisodeLink(
      url: url,
      label: t,
      order: e,
      episodeNumber: e,
    );
  }

  // Bare number at boundaries: "01" / " 02 " (full string match or after slash)
  final bare = RegExp(r'(?:^|/)\s*(\d{1,4})\s*(?:$|\s)').firstMatch(t);
  if (bare != null) {
    final e = int.parse(bare.group(1)!);
    return EpisodeLink(
      url: url,
      label: t,
      order: e,
      episodeNumber: e,
    );
  }

  return null;
}

/// Detects and ranks episode links from a set of HTML anchor elements.
///
/// Each entry in [anchors] should be a map with keys:
/// - `url`: the href target (required).
/// - `text`: the inner text or title attribute of the anchor (optional).
///
/// Returns episode links sorted by parsed episode order ascending, with ties
/// broken by the original DOM order (implicit in the list index).
///
/// Links that do not match any episode pattern are excluded.
List<EpisodeLink> detectEpisodeLinks(
    List<Map<String, String?>> anchors) {
  final results = <EpisodeLink>[];
  for (final anchor in anchors) {
    final url = anchor['url'];
    final text = anchor['text'];
    if (url == null || url.isEmpty) continue;
    final searchText = text ?? url;
    final parsed = parseEpisodeLink(searchText, url);
    if (parsed != null) results.add(parsed);
  }
  // Stable sort by order, then by original position (stable = keep DOM order).
  results.sort((a, b) => a.order.compareTo(b.order));
  return results;
}

/// Maximum page depth for pagination chain following.
const int seriesGrabMaxDepth = 10;

/// Safety cap: maximum episodes to enqueue even for Pro/Ultra.
const int seriesGrabSafetyMax = 100;
