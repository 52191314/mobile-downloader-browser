import 'dart:async';

import 'native_html_media_extractor.dart';

/// Result of one listing-page crawl: the media URLs discovered across the
/// listing page and every followed detail page.
class ListingCrawlResult {
  final List<CrawledMedia> media;
  final int pagesScanned;

  /// True when the crawl was cancelled by the user mid-run.
  final bool cancelled;

  const ListingCrawlResult({
    required this.media,
    required this.pagesScanned,
    required this.cancelled,
  });
}

/// One media URL discovered while crawling a listing page.
class CrawledMedia {
  final String url;

  /// The detail page (or listing page) the media was found on.
  final String sourcePageUrl;

  /// The detail page's `<title>` when available — used as a filename hint.
  final String? pageTitle;

  const CrawledMedia({
    required this.url,
    required this.sourcePageUrl,
    this.pageTitle,
  });
}

/// Progress snapshot emitted while crawling.
class ListingCrawlProgress {
  final int pagesScanned;
  final int totalMediaFound;
  final String currentUrl;

  const ListingCrawlProgress({
    required this.pagesScanned,
    required this.totalMediaFound,
    required this.currentUrl,
  });
}

/// Crawls a listing page (e.g. a channel / tag / user page that shows many
/// video thumbnails) and collects the direct media URLs of every video it
/// links to.
///
/// Generic by design: no per-site patterns. The algorithm is:
///
/// 1. Fetch the listing page HTML.
/// 2. Extract same-origin `<a href>` links. Classify each:
///    - links whose path looks like a **detail page** (deeper path, not
///      obviously navigation) are queued for fetching,
///    - pagination links (`?page=N`, `/page/N`, `?p=N` …) are followed up to
///      [maxPages],
///    - everything else (nav, media files, assets) is skipped.
/// 3. Fetch each detail page (up to [maxDetailPages]) and extract media URLs
///    from its HTML using [NativeHtmlMediaExtractor].
/// 4. Dedupe by URL; return the collected media.
///
/// The [fetchHtml] callback is injected so callers can choose the transport
/// (WebView JS fetch to ride the browser's WAF-bypass stack, or native HTTP).
class ListingPageCrawler {
  /// Fetches the HTML body of [url]. Return null on failure.
  final Future<String?> Function(String url) fetchHtml;

  /// Optional fallback that loads [url] in a rendered (JS-enabled) context
  /// and returns every media URL the page exposes — `<video>`/`<source>`
  /// src, og:video meta, script strings and performance resource entries.
  ///
  /// Used when a detail page's static HTML contains no direct media URL
  /// (JS-constructed player URLs, XHR-loaded playlists, …). Called at most
  /// [maxRenderedDomFetches] times per crawl.
  final Future<List<String>> Function(String url)? fetchMediaViaRenderedDom;

  /// Hard cap on rendered-DOM fallback fetches per crawl. Each one spins up
  /// a headless WebView (~seconds), so the fallback is only worth it for a
  /// bounded number of detail pages.
  final int maxRenderedDomFetches;

  final int maxPages;
  final int maxDetailPages;

  /// Optional cancel probe — checked between fetches. Returning true stops
  /// the crawl as soon as the current fetch completes.
  final bool Function()? isCancelled;

  /// Optional progress listener.
  final void Function(ListingCrawlProgress progress)? onProgress;

  ListingPageCrawler({
    required this.fetchHtml,
    this.fetchMediaViaRenderedDom,
    this.maxRenderedDomFetches = 20,
    this.maxPages = 10,
    this.maxDetailPages = 100,
    this.isCancelled,
    this.onProgress,
  });

  static final RegExp _linkRegExp = RegExp(
    r'''<a\s[^>]*href=["']([^"']+)["']''',
    caseSensitive: false,
  );

  /// Detail-page path shapes we treat as "a video page", not navigation.
  /// A link qualifies as a detail page when it is same-origin AND its path
  /// is deeper than the listing path AND it is not an obvious nav/asset link.
  static final RegExp _navPathRegExp = RegExp(
    r'/(login|register|signup|signin|signout|logout|search|premium|donate|'
    r'about|contact|faq|help|terms|privacy|policy|cart|checkout|account|'
    r'settings|admin|api|feed|rss|sitemap|tag|categories?|category)(/|$)',
    caseSensitive: false,
  );

  static final RegExp _assetExtensionRegExp = RegExp(
    r'\.(css|js|json|xml|txt|html?|png|jpe?g|gif|webp|svg|ico|avif|bmp|'
    r'woff2?|ttf|otf|eot|map|webmanifest)(\?|$)',
    caseSensitive: false,
  );

  /// Pagination query-parameter names (page, p, pg, pageNo, …).
  static final RegExp _pageParamRegExp = RegExp(
    r'[?&](page|p|pg|pageno|paged)=(\d+)',
    caseSensitive: false,
  );

  /// Pagination path shapes: /page/2, /page-2, /p/2, /2 …
  static final RegExp _pagePathRegExp = RegExp(
    r'/(page|p|pg)[/-](\d+)/?$',
    caseSensitive: false,
  );

  /// Crawls [listingUrl] and returns every media URL found.
  Future<ListingCrawlResult> crawlListing(String listingUrl) async {
    final listingUri = Uri.tryParse(listingUrl);
    if (listingUri == null || !listingUri.hasScheme) {
      return const ListingCrawlResult(media: [], pagesScanned: 0, cancelled: false);
    }

    final origin = listingUri.origin;
    final listingPath = listingUri.path;

    final mediaByUrl = <String, CrawledMedia>{};
    final visitedPages = <String>{};
    final pendingPages = <String>[listingUrl];
    var pagesScanned = 0;
    var detailPagesFetched = 0;

    bool cancelled() => isCancelled?.call() ?? false;

    // Phase 1: walk the listing + pagination pages, collecting detail links.
    final detailPageUrls = <String>{};
    while (pendingPages.isNotEmpty &&
        pagesScanned < maxPages &&
        detailPagesFetched < maxDetailPages) {
      if (cancelled()) break;
      final pageUrl = pendingPages.removeAt(0);
      if (!visitedPages.add(pageUrl)) continue;

      pagesScanned++;
      onProgress?.call(ListingCrawlProgress(
        pagesScanned: pagesScanned,
        totalMediaFound: mediaByUrl.length,
        currentUrl: pageUrl,
      ));

      final html = await fetchHtml(pageUrl);
      if (html == null || html.isEmpty) continue;

      final base = Uri.tryParse(pageUrl);
      if (base == null) continue;

      // Direct media URLs on the listing page itself (rare but possible).
      for (final mediaUrl in NativeHtmlMediaExtractor.parseHtmlForMedia(html)) {
        _addMedia(mediaByUrl, mediaUrl, pageUrl, pageTitle: null);
      }

      for (final match in _linkRegExp.allMatches(html)) {
        final rawHref = match.group(1);
        if (rawHref == null || rawHref.isEmpty) continue;
        final resolved = _resolveLink(base, rawHref);
        if (resolved == null) continue;
        if (!_isSameOrigin(origin, resolved)) continue;

        final path = resolved.path;
        if (path.isEmpty || path == '/') continue; // homepage
        if (_assetExtensionRegExp.hasMatch(path)) continue;
        if (_navPathRegExp.hasMatch(path)) continue;
        if (path == listingPath && resolved.query.isEmpty) continue;

        // Pagination?
        if (_isPagination(resolved, pageUrl)) {
          pendingPages.add(resolved.toString());
          continue;
        }

        // Detail page? Same-origin, not nav/asset. Qualifies when either:
        //  - the path is a strict sub-path of the listing (deeper), or
        //  - the last path segment is a numeric ID — the classic
        //    video-page shape (`/watch/123`, `/v/12345`, …) even when the
        //    detail path lives outside the listing path.
        if (_isDetailPagePath(path, listingPath)) {
          detailPageUrls.add(resolved.toString());
        }
      }

      // Enforce the detail-page cap as we discover links so we never fetch
      // the whole site.
      if (detailPageUrls.length >= maxDetailPages) break;
    }

    // Phase 2: fetch each detail page and extract its media.
    var renderedDomFetches = 0;
    for (final detailUrl in detailPageUrls) {
      if (cancelled()) break;
      if (detailPagesFetched >= maxDetailPages) break;
      detailPagesFetched++;
      onProgress?.call(ListingCrawlProgress(
        pagesScanned: pagesScanned,
        totalMediaFound: mediaByUrl.length,
        currentUrl: detailUrl,
      ));

      final html = await fetchHtml(detailUrl);
      if (html == null || html.isEmpty) continue;

      final title = _extractPageTitle(html);
      final staticMedia = NativeHtmlMediaExtractor.parseHtmlForMedia(html);
      var foundOnPage = staticMedia.length;
      for (final mediaUrl in staticMedia) {
        _addMedia(mediaByUrl, mediaUrl, detailUrl, pageTitle: title);
      }

      // JS-rendered fallback: when the static HTML exposes no direct media
      // URL, load the page in a rendered (headless WebView) context and
      // collect whatever the player produced — video/src elements, og:video,
      // script-embedded URLs and XHR-loaded playlists.
      final fallback = fetchMediaViaRenderedDom;
      if (foundOnPage == 0 &&
          fallback != null &&
          renderedDomFetches < maxRenderedDomFetches) {
        renderedDomFetches++;
        onProgress?.call(ListingCrawlProgress(
          pagesScanned: pagesScanned,
          totalMediaFound: mediaByUrl.length,
          currentUrl: detailUrl,
        ));
        try {
          final rendered = await fallback(detailUrl);
          for (final mediaUrl in rendered) {
            _addMedia(mediaByUrl, mediaUrl, detailUrl, pageTitle: title);
          }
        } catch (_) {
          // Fallback failure must not abort the whole crawl.
        }
      }
    }

    return ListingCrawlResult(
      media: mediaByUrl.values.toList(),
      pagesScanned: pagesScanned,
      cancelled: cancelled(),
    );
  }

  void _addMedia(
    Map<String, CrawledMedia> sink,
    String url,
    String sourcePageUrl, {
    String? pageTitle,
  }) {
    final normalized = _normalizeUrl(url);
    if (normalized == null) return;
    sink.putIfAbsent(
      normalized,
      () => CrawledMedia(
        url: url,
        sourcePageUrl: sourcePageUrl,
        pageTitle: pageTitle,
      ),
    );
  }

  /// Resolves [rawHref] against [base]; returns null for non-http(s) links.
  Uri? _resolveLink(Uri base, String rawHref) {
    final href = rawHref.trim();
    if (href.isEmpty) return null;
    if (href.startsWith('#') || href.startsWith('javascript:') ||
        href.startsWith('mailto:') || href.startsWith('tel:')) {
      return null;
    }
    try {
      final resolved = base.resolve(href);
      if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
      return resolved;
    } catch (_) {
      return null;
    }
  }

  bool _isSameOrigin(String origin, Uri uri) {
    try {
      return uri.origin == origin;
    } catch (_) {
      return false;
    }
  }

  bool _isPagination(Uri link, String currentPageUrl) {
    if (_pagePathRegExp.hasMatch(link.path)) return true;
    if (link.query.isNotEmpty && _pageParamRegExp.hasMatch(link.toString())) {
      // Only treat as pagination when it's a different page number than the
      // current URL's own page param (avoids re-fetching the same page).
      final current = Uri.tryParse(currentPageUrl);
      final curPage = current != null
          ? _pageParamRegExp.firstMatch(current.toString())?.group(2)
          : null;
      final linkPage = _pageParamRegExp.firstMatch(link.toString())?.group(2);
      if (linkPage == null) return false;
      return linkPage != curPage;
    }
    return false;
  }

  /// True when [path] looks like a video detail page relative to the listing
  /// at [listingPath]: either a strict sub-path of the listing (deeper) or a
  /// path ending in a numeric ID segment. Both are checked segment-wise so a
  /// sibling listing (`/creators`, `/user/video`) is never mistaken for a
  /// detail page.
  static bool _isDetailPagePath(String path, String listingPath) {
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return false;

    final listingSegs =
        listingPath.split('/').where((s) => s.isNotEmpty).toList();

    // Strict sub-path of the listing: `/user/short` + `/user/short/123`.
    if (listingSegs.isNotEmpty &&
        segs.length > listingSegs.length &&
        _isSegmentPrefix(listingSegs, segs)) {
      return true;
    }

    // Trailing numeric ID — `/watch/123`, `/v/12345`, `/123`.
    if (RegExp(r'^\d+$').hasMatch(segs.last)) return true;

    return false;
  }

  static bool _isSegmentPrefix(List<String> prefix, List<String> segs) {
    if (prefix.length > segs.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != segs[i]) return false;
    }
    return true;
  }

  static String? _normalizeUrl(String url) {
    try {
      final uri = Uri.parse(url);
      // Drop fragment; keep query (token freshness matters).
      return uri.replace(fragment: '').toString();
    } catch (_) {
      return null;
    }
  }

  static String? _extractPageTitle(String html) {
    final titleMatch = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (titleMatch == null) return null;
    var title = titleMatch.group(1)?.trim() ?? '';
    // Strip common site-name suffixes: "Video — SiteName".
    title = title.replaceFirst(RegExp(r'\s*[—–-]\s*[^—–-]+$'), '').trim();
    if (title.isEmpty) return null;
    // HTML entity decode for the common ones.
    title = title
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    return title;
  }
}
