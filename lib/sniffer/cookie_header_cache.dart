
/// Manages a time-based cache of cookie header maps keyed by normalized URL.
/// Cookies are cached for a short TTL (5 seconds) to avoid flooding the
/// native cookie manager per captured URL during rapid sniff events.
class CookieHeaderCache {
  final Map<String, Map<String, String>> _cache = {};
  final Map<String, DateTime> _cacheTimestamps = {};

  /// TTL for cached cookie headers.
  Duration _ttl = const Duration(seconds: 5);

  /// Sets the TTL for cached entries.
  void setTtl(Duration ttl) {
    _ttl = ttl;
  }

  /// Returns cached cookie headers for [key] if they exist and are fresh
  /// (younger than [_ttl]). Returns null if stale or missing.
  Map<String, String>? get(String key) {
    final cachedAt = _cacheTimestamps[key];
    final cached = _cache[key];
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) <= _ttl) {
      return cached;
    }
    return null;
  }

  /// Sets (or overwrites) the cookie headers for [key].
  void set(String key, Map<String, String> headers) {
    _cache[key] = headers;
    _cacheTimestamps[key] = DateTime.now();
  }

  /// Clears the entire cache.
  void clear() {
    _cache.clear();
    _cacheTimestamps.clear();
  }

  /// Clears entries matching a specific host domain.
  void clearForHost(String host) {
    final lowHost = host.toLowerCase();
    _cache.removeWhere((url, _) {
      final uri = Uri.tryParse(url);
      if (uri == null) return false;
      final uriHost = uri.host.toLowerCase();
      return uriHost == lowHost || uriHost.endsWith('.$lowHost') || lowHost.endsWith('.$uriHost');
    });
    _cacheTimestamps.removeWhere((url, _) {
      final uri = Uri.tryParse(url);
      if (uri == null) return false;
      final uriHost = uri.host.toLowerCase();
      return uriHost == lowHost || uriHost.endsWith('.$lowHost') || lowHost.endsWith('.$uriHost');
    });
  }
}
