// Lookup helpers for per-tab HLS playlist body caches.
//
// Cache keys are exact URLs as seen by browser_guard / native intercept.
// Download tasks often request a sibling quality path (480p vs 1080p) or the
// same path with different query ordering — exact map hits miss even when the
// body was already captured. Path-level match reuses those bodies safely when
// host + path agree (query/fragment ignored).

/// Returns a cached playlist body for [url], or null if none is usable.
String? lookupHlsPlaylistCache(Map<String, String> cache, String url) {
  if (cache.isEmpty || url.isEmpty) return null;

  final exact = cache[url];
  if (exact != null && exact.isNotEmpty && _looksLikePlaylist(exact)) {
    return exact;
  }

  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty || uri.path.isEmpty) return null;

  for (final entry in cache.entries) {
    final body = entry.value;
    if (body.isEmpty || !_looksLikePlaylist(body)) continue;
    final cachedUri = Uri.tryParse(entry.key);
    if (cachedUri == null) continue;
    if (_samePlaylistResource(uri, cachedUri)) {
      return body;
    }
  }
  return null;
}

bool _samePlaylistResource(Uri a, Uri b) {
  return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.path == b.path;
}

bool _looksLikePlaylist(String body) {
  final trimmed = body.trimLeft();
  if (trimmed.startsWith('#EXTM3U')) return true;
  // Some CDNs prepend a BOM or whitespace; still accept if tag appears early.
  final head = trimmed.length > 64 ? trimmed.substring(0, 64) : trimmed;
  return head.contains('#EXTM3U');
}
