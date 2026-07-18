import 'dart:async';

import 'package:http/http.dart' as http;

import '../downloader/hls_playlist_parser.dart';
import '../logging/aurora_log.dart';
import '../platform/network_binding_service.dart';
import 'media_sniffer_engine.dart';
import 'models/browser_tab.dart';
import 'models/sniffed_media.dart';
import 'sniffer_url_utils.dart';
import 'controllers/sniff_intake_controller.dart';

/// Fetches HLS master-playlist variants (quality tiers) for a given
/// `.m3u8` URL using a three-tier fallback:
///
/// 0. Browser-captured playlist body (zero network).
/// 1. Dart HTTP client with browser cookies & headers.
/// 2. WebView JavaScript fetch (Cloudflare WAF bypass).
/// 3. Android native HttpURLConnection.
///
/// Previously `_SnifferScreenState._fetchMasterPlaylistVariants`.
class HlsVariantFetcher {
  HlsVariantFetcher._(); // static-only

  /// Fetches variants for [url].  Returns an empty list on failure.
  static Future<List<SniffedMedia>> fetch(
    String url, {
    required BrowserTab tab,
    required SniffIntakeController sniffIntakeController,
    required bool doNotTrackEnabled,
  }) async {
    final uri = Uri.tryParse(url);
    final path = uri?.path.toLowerCase() ?? '';
    if (uri == null ||
        (!path.endsWith('.m3u8') && !isPlaylistPathHint(path))) {
      return [];
    }

    // 0th attempt: browser-captured playlist body.
    final cached = tab.hlsPlaylistCache[url];
    if (cached != null && cached.isNotEmpty) {
      try {
        final playlist = HlsPlaylistParser.parse(cached, uri);
        if (playlist.isMaster && playlist.variants.isNotEmpty) {
          AuroraLog.instance.debug(
            'Using cached playlist body for $url '
            '(${playlist.variants.length} variants)',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
          return playlist.variants.map((v) => _toSniffedMedia(v)).toList();
        }
      } catch (_) {}
    }

    // Build auth headers.
    final headers = <String, String>{
      'User-Agent': downloadUserAgent(url, tab),
    };
    try {
      final cookies = await sniffIntakeController.getCookiesForUrl(url);
      headers.addAll(cookies);
    } catch (_) {}
    if (!hasHeader(headers, 'Referer')) {
      final pageUrl = tab.addressController.text;
      if (pageUrl.isNotEmpty) headers['Referer'] = pageUrl;
    }
    normalizeHeadersForUrl(
      headers,
      url,
      currentUrl: await tab.controller.currentUrl(),
      addressText: tab.addressController.text,
    );
    headers.addAll(baseRequestHeaders(doNotTrackEnabled));

    try {
      var response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        AuroraLog.instance.debug(
          'HlsVariantFetcher Dart client returned '
          '${response.statusCode}, trying WebView JS fetch…',
          category: LogCategory.sniffer,
          screen: LogScreen.browser,
          eventType: LogEventType.sniff,
        );
        // 1st fallback: WebView JS.
        String? jsBody;
        try {
          jsBody = await tab.controller.fetchPlaylistBodyViaJavaScript(url);
        } catch (e) {
          AuroraLog.instance.error(
            'JS fetch error: $e',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.error,
          );
        }
        if (jsBody != null && jsBody.isNotEmpty) {
          response = http.Response(
            jsBody,
            200,
            request: http.Request('GET', uri),
          );
          AuroraLog.instance.debug(
            'WebView JS fetch succeeded for variant fetch',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
        } else {
          AuroraLog.instance.debug(
            'WebView JS fetch failed, trying native Android HTTP…',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
          try {
            final nativeResult = await NetworkBindingService.fetchUrl(
              url,
              headers: headers,
            );
            final nativeStatus = nativeResult?['statusCode'] as int? ?? 0;
            final nativeBody = nativeResult?['body'] as String? ?? '';
            if (nativeStatus == 200 && nativeBody.isNotEmpty) {
              response = http.Response(
                nativeBody,
                200,
                request: http.Request('GET', uri),
              );
            }
          } catch (e) {
            AuroraLog.instance.error(
              'Native HTTP error: $e',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.error,
            );
          }
        }
      }

      if (response.statusCode != 200) return [];

      final playlist = HlsPlaylistParser.parse(response.body, uri);
      if (!playlist.isMaster || playlist.variants.isEmpty) return [];

      AuroraLog.instance.debug(
        'HlsVariantFetcher resolved ${playlist.variants.length} variants',
        category: LogCategory.sniffer,
        screen: LogScreen.browser,
        eventType: LogEventType.sniff,
      );
      return playlist.variants.map((v) => _toSniffedMedia(v)).toList();
    } catch (e) {
      AuroraLog.instance.error(
        'HlsVariantFetcher error: $e',
        category: LogCategory.sniffer,
        screen: LogScreen.browser,
        eventType: LogEventType.error,
      );
      return [];
    }
  }

  static SniffedMedia _toSniffedMedia(dynamic v) {
    int? w;
    int? h;
    if (v.resolution != null) {
      final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(v.resolution!);
      if (m != null) {
        w = int.tryParse(m.group(1)!);
        h = int.tryParse(m.group(2)!);
      }
    }
    final resLabel = h != null ? '${h}p ' : '';
    return SniffedMedia(
      url: v.uri.toString(),
      name: '$resLabel${MediaSnifferEngine.bandwidthLabel(v.bandwidth)}'.trim(),
      type: MediaType.video,
      bandwidth: v.bandwidth,
      width: w,
      height: h,
    );
  }
}
