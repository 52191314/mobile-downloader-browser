/// Payload validation for URLs that arrive from page JavaScript over a
/// JS bridge channel.
///
/// **Why payload validation and not origin validation.** Every channel
/// registered in `tab_callback_binder.dart` is reachable by any page loaded in
/// the browser WebView via
/// `window.flutter_inappwebview.callHandler('<name>', ...)`. There is no
/// authentication on that call, and `flutter_inappwebview` 6.1.5's
/// `JavaScriptHandlerCallback(List<dynamic>)` does not report the caller's
/// origin — so the bridge cannot tell a guard script's call from a hostile
/// page's call. Checking the origin would not help even if it were available:
/// the hostile page *is* the current page, so it would always pass.
///
/// What actually needs constraining is the **URL the page hands us**, because
/// the app then fetches it with app-level network access. Without this guard a
/// remote page can pivot Aurora onto the user's LAN (`http://192.168.1.1/...`,
/// a router admin panel) or at local files, which the page itself could never
/// reach.
///
/// The rule is relational, not a flat denylist, so that legitimately browsing a
/// LAN media server (Jellyfin on `192.168.1.50`, say) and sniffing media from it
/// keeps working: a private-network target is allowed **only when the page
/// asking for it is itself on a private host**. Remote page → private target is
/// the pivot, and that is the case this blocks.
library;

/// True when [rawUrl], supplied by page JavaScript, may be handed to the
/// sniffer / prober / player while [pageUrl] is the page that sent it.
///
/// Rejects:
///  * unparseable or relative URLs
///  * any scheme other than `http` / `https` — blocks `file:`, `content:`,
///    `data:`, `blob:`, `javascript:`, `intent:`
///  * empty hosts
///  * private / loopback / link-local targets when the page is on a public host
bool isAllowedBridgeUrl(String rawUrl, {required String pageUrl}) {
  final target = _parse(rawUrl);
  if (target == null) return false;

  final scheme = target.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  if (target.host.isEmpty) return false;

  // Public target: always fine — the page could have fetched it itself.
  if (!isPrivateHost(target.host)) return true;

  // Private target: only from a page already inside that trust zone.
  final page = _parse(pageUrl);
  if (page == null || page.host.isEmpty) return false;
  return isPrivateHost(page.host);
}

/// True when [host] names a loopback, private, link-local, or otherwise
/// non-routable address that a remote page must not be able to reach through us.
bool isPrivateHost(String host) {
  final h = host.toLowerCase().trim();
  if (h.isEmpty) return true;

  // Hostname forms that resolve inside the local network.
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  if (h == 'local' || h.endsWith('.local')) return true;
  if (h.endsWith('.internal') || h.endsWith('.home.arpa')) return true;

  // IPv6 — Uri strips the brackets from the host, so match the bare form.
  if (h.contains(':')) {
    if (h == '::' || h == '::1') return true;
    if (h.startsWith('fe8') || h.startsWith('fe9') ||
        h.startsWith('fea') || h.startsWith('feb')) {
      return true; // fe80::/10 link-local
    }
    if (h.startsWith('fc') || h.startsWith('fd')) return true; // fc00::/7 ULA
    // IPv4-mapped IPv6, e.g. ::ffff:192.168.1.1
    final lastColon = h.lastIndexOf(':');
    final tail = h.substring(lastColon + 1);
    if (tail.contains('.')) return isPrivateHost(tail);
    return false;
  }

  final octets = _ipv4Octets(h);
  if (octets == null) return false; // a normal domain name

  final a = octets[0], b = octets[1];
  if (a == 0) return true; // 0.0.0.0/8
  if (a == 10) return true; // 10/8
  if (a == 127) return true; // loopback
  if (a == 169 && b == 254) return true; // link-local + cloud metadata
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16/12
  if (a == 192 && b == 168) return true; // 192.168/16
  if (a == 100 && b >= 64 && b <= 127) return true; // 100.64/10 CGNAT
  if (a == 192 && b == 0) return true; // 192.0.0/24, 192.0.2/24
  if (a >= 224) return true; // multicast + reserved
  return false;
}

Uri? _parse(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) return null;
  return uri;
}

/// Parses [host] as a dotted-quad IPv4 literal, or returns null when it is not
/// one. Rejects out-of-range octets rather than clamping.
List<int>? _ipv4Octets(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}
