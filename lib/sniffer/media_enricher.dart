import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../downloader/hls_playlist_parser.dart';
import '../logging/aurora_log.dart';
import 'dash_playlist_parser.dart';
import 'media_sniffer_engine.dart';
import 'models/sniffed_media.dart';
import 'sniffed_media_cache.dart';
import 'sniffer_url_utils.dart';

/// Host interface that [MediaEnricher] uses to access the owning
/// [MediaSnifferEngine]'s state. Defined as a class so it can be unit
/// tested with a fake host without instantiating a real engine.
abstract class MediaEnricherHost {
  /// The HTTP client used for Tier 1/2/3 probes.
  http.Client get client;

  /// Underlying detected-media list. The enricher mutates this list
  /// (adds variant playlist items, replaces the original entry with the
  /// enriched copy) and reads from it to locate the current item.
  ///
  /// Named `mutableDetectedMedia` on the host to avoid clashing with the
  /// engine's public unmodifiable `detectedMedia` getter.
  List<SniffedMedia> get mutableDetectedMedia;

  /// Broadcast stream controller the enricher emits `mediaChanged` events
  /// through after mutating the list.
  StreamController<SniffedMedia> get mediaChangedController;

  /// Optional cookie provider for target media requests.
  Future<Map<String, String>> Function({String? url})? get cookieProvider;

  /// Optional WebView JS header probe callback (Tier 4 fallback).
  Future<Map<String, String>?> Function(String url)? get fetchViaWebView;

  /// Optional WebView JS body fetch callback for protected HLS playlists.
  Future<String?> Function(String url)? get fetchPlaylistBodyViaWebView;

  /// Optional headless-WebView body fetch callback that uses same-origin XHR
  /// from the CDN's domain to bypass both CORS (same origin) and Cloudflare
  /// WAF (real Chrome TLS fingerprint + cf_clearance cookie).
  /// Used as the last-resort tier (4th attempt) for playlist body fetching.
  Future<String?> Function(String url)? get fetchPlaylistBodyViaHeadlessWebView;

  /// Optional per-tab HLS playlist body cache.
  String? Function(String url)? get hlsPlaylistCache;

  /// True once [MediaEnricherHost.dispose] has been called. The enricher
  /// checks this before mutating state and before emitting events.
  bool get isDisposedEngine;

  /// Trim the detected-media list to [SniffedMediaCache.maxDetectedMedia]
  /// when the soft cap is exceeded.
  void evictToLimit();
}

/// Owns the enrichment queue, the active-enrich counter, and the
/// per-item probe pipeline (Tier 1/2/3 HTTP, Tier 4 WebView JS, image
/// dimension sniffing, MP4 atom parsing, HLS variant playlist parsing,
/// segment size sampling).
///
/// The enricher is created once per [MediaSnifferEngine] and shares the
/// engine's dedup set, broadcast controller, HTTP client, and webview
/// callbacks via the [MediaEnricherHost] interface.
class MediaEnricher {
  final MediaEnricherHost host;

  /// Number of enrich probes currently in flight.
  int activeEnrichCount = 0;

  /// FIFO queue of items waiting to be enriched. Capacity is implicitly
  /// bounded by [activeEnrichCount] (at most 3 concurrent probes).
  final List<SniffedMedia> enrichQueue = [];

  MediaEnricher({required this.host});

  /// Enqueue [item] for enrichment. If the queue was empty and no probes
  /// are in flight, the next drain pass is scheduled immediately.
  void enqueue(SniffedMedia item) {
    if (host.isDisposedEngine) return;
    enrichQueue.add(item);
    _drainEnrichQueue();
  }

  void _drainEnrichQueue() {
    while (activeEnrichCount < 3 &&
        enrichQueue.isNotEmpty &&
        !host.isDisposedEngine) {
      final item = enrichQueue.removeAt(0);
      activeEnrichCount++;
      unawaited(
        enrich(item).whenComplete(() {
          activeEnrichCount--;
          if (enrichQueue.isEmpty && activeEnrichCount == 0) {
            host.evictToLimit();
          }
          _drainEnrichQueue();
        }),
      );
    }
  }

  Future<void> enrich(SniffedMedia item) async {
    int? contentLength;
    String? contentType;
    Duration? duration;
    int? videoWidth;
    int? videoHeight;
    bool estimated = false;
    String? videoCodec;
    String? audioCodec;
    String? containerFormat;
    int? sampleRate;
    int? channels;
    bool? isLive;
    double? frameRate;

    final uri = Uri.tryParse(item.url);
    if (uri == null || !uri.hasScheme) return;

    final headers = Map<String, String>.from(item.headers);
    bool hasUA = false;
    headers.forEach((k, v) {
      if (k.toLowerCase() == 'user-agent') hasUA = true;
    });
    if (!hasUA) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
    }
    var hasCookie = false;
    headers.forEach((k, v) {
      if (k.toLowerCase() == 'cookie' && v.trim().isNotEmpty) {
        hasCookie = true;
      }
    });
    if (!hasCookie && host.cookieProvider != null) {
      try {
        final cookies = await host.cookieProvider!(url: item.url);
        headers.addAll(cookies);
      } catch (e) {
        debugPrint('[MediaEnricher] Cookie provider threw for ${item.url}: $e');
      }
    }

    try {
      // Tier 1: HEAD Request
      final headResp = await host.client
          .head(uri, headers: headers)
          .timeout(const Duration(seconds: 10))
          .catchError((_) => http.Response('', 500));
      if (headResp.statusCode >= 200 && headResp.statusCode < 400) {
        final headContentRange = headResp.headers['content-range'] ?? '';
        final headRangeMatch = RegExp(
          r'bytes \d+-\d+/(\d+)',
        ).firstMatch(headContentRange);
        if (headRangeMatch != null) {
          contentLength = int.tryParse(headRangeMatch.group(1)!);
        } else {
          contentLength = int.tryParse(
            headResp.headers['content-length'] ?? '',
          );
        }
        contentType = headResp.headers['content-type'];
        debugPrint(
          '[MediaEnricher] Tier 1 HEAD ${headResp.statusCode} '
          'content-length=$contentLength for ${item.url}',
        );
      } else {
        debugPrint(
          '[MediaEnricher] Tier 1 HEAD failed ${headResp.statusCode} '
          'for ${item.url}',
        );
        // Tier 2: Streamed GET with Range: bytes=0-0 (immediately cancel stream to avoid downloading body)
        bool gotSize = false;
        try {
          final request = http.Request('GET', uri);
          request.headers.addAll({...headers, 'Range': 'bytes=0-0'});
          request.followRedirects = true;

          final response = await host.client
              .send(request)
              .timeout(const Duration(seconds: 10));
          if (response.statusCode >= 200 && response.statusCode < 400) {
            final resHeaders = response.headers;
            final contentRange = resHeaders['content-range'] ?? '';
            final rangeMatch = RegExp(
              r'bytes \d+-\d+/(\d+)',
            ).firstMatch(contentRange);
            final lengthHeader = resHeaders['content-length'] ?? '';
            if (rangeMatch != null) {
              contentLength = int.tryParse(rangeMatch.group(1)!);
              gotSize = true;
            } else if (lengthHeader.isNotEmpty) {
              final parsed = int.tryParse(lengthHeader);
              // Guard: a 206 response to Range: bytes=0-0 returns
              // Content-Length: 1 (the single requested byte). Treat
              // values <= 1 as "no size" so Tiers 3/4 still run.
              if (parsed != null && parsed > 1) {
                contentLength = parsed;
                gotSize = true;
              }
            }
            contentType = resHeaders['content-type'];
          }
          debugPrint(
            '[MediaEnricher] Tier 2 Range-GET '
            'gotSize=$gotSize content-length=$contentLength for ${item.url}',
          );
          unawaited(response.stream.listen((_) {}).cancel().catchError((_) {}));
        } catch (e) {
          debugPrint(
            '[MediaEnricher] Tier 2 Range-GET threw for ${item.url}: $e',
          );
        }

        // Tier 3: If Tier 2 failed/no size resolved, try standard Streamed GET without Range header
        if (!gotSize) {
          try {
            final request = http.Request('GET', uri);
            request.headers.addAll(headers);
            request.followRedirects = true;

            final response = await host.client
                .send(request)
                .timeout(const Duration(seconds: 10));
            if (response.statusCode >= 200 && response.statusCode < 400) {
              final resHeaders = response.headers;
              final lengthHeader = resHeaders['content-length'] ?? '';
              if (lengthHeader.isNotEmpty) {
                contentLength = int.tryParse(lengthHeader);
              }
              contentType = resHeaders['content-type'];
            }
            debugPrint(
              '[MediaEnricher] Tier 3 GET '
              'content-length=$contentLength for ${item.url}',
            );
            unawaited(
              response.stream.listen((_) {}).cancel().catchError((_) {}),
            );
          } catch (e) {
            debugPrint(
              '[MediaEnricher] Tier 3 GET threw for ${item.url}: $e',
            );
          }
        }
      }
    } catch (e, s) {
      debugPrint('[MediaEnricher] enrich() threw for ${item.url}: $e\n$s');
    }

    // Tier 4: WebView JS fetch (bypasses Cloudflare WAF). Only useful when
    // contentLength is still null after Tiers 1-3 all failed.
    if (contentLength == null && host.fetchViaWebView != null) {
      try {
        final jsHeaders = await host.fetchViaWebView!(item.url);
        if (jsHeaders != null) {
          final statusCode = int.tryParse(jsHeaders['statusCode'] ?? '');
          if (statusCode != null && statusCode >= 200 && statusCode < 400) {
            var cl = jsHeaders['content-length'];
            // If content-length is missing, try to extract the total size
            // from content-range (sent when CDN responds with 206 Partial
            // Content, e.g. Range-GET fallback when HEAD returns 405).
            if (cl == null || cl.isEmpty) {
              final cr = jsHeaders['content-range'];
              if (cr != null && cr.isNotEmpty) {
                final rangeMatch =
                    RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(cr);
                if (rangeMatch != null) {
                  cl = rangeMatch.group(1);
                }
              }
            }
            if (cl != null && cl.isNotEmpty) {
              contentLength = int.tryParse(cl);
              debugPrint(
                '[MediaEnricher] Tier 4 (WebView HEAD) got '
                'content-length=$cl for ${item.url}',
              );
            } else {
              debugPrint(
                '[MediaEnricher] Tier 4 WebView HEAD returned headers without content-length for ${item.url}: $jsHeaders',
              );
            }
            contentType ??= jsHeaders['content-type'];
          }
        }
      } catch (e) {
        debugPrint(
          '[MediaEnricher] Tier 4 WebView HEAD threw for ${item.url}: $e',
        );
      }
    }

    if (item.type == MediaType.image) {
      try {
        final imgResp = await host.client
            .get(uri, headers: {...headers, 'Range': 'bytes=0-2047'})
            .timeout(const Duration(seconds: 10))
            .catchError((_) => http.Response('', 500));
        if (imgResp.statusCode == 206 || imgResp.statusCode == 200) {
          final b = imgResp.bodyBytes;
          final dims = await _parseImageDimensionsInIsolate(b);
          if (dims != null) {
            videoWidth = dims['width'] as int;
            videoHeight = dims['height'] as int;
          } else {
            // No valid image dimensions — the body might be a disguised HLS
            // playlist (#EXTM3U) hosted under a non-.m3u8 URL path that
            // contains playlist hints (/hls/, /master/, /playlist/, etc.).
            if (_hasPlaylistPathHint(uri)) {
              // First check the browser-captured HLS playlist cache — if
              // the JS body sniffing already populated it (e.g. via the
              // fetch hook's HlsPlaylistChannel), we can detect #EXTM3U
              // without making a Dart HTTP request that the CDN might
              // block (403 due to missing cookies/referer).
              final cached = _readHlsPlaylistCache(item.url);
              if (cached != null && _reclassifyAsHlsFromString(cached, item)) {
                return;
              }
              if (_reclassifyAsHlsFromBytes(b, item)) return;
            }
          }
        } else if (_hasPlaylistPathHint(uri)) {
          // Image probe failed (e.g. 403, 500) but URL hints at a playlist.
          // Try the browser-captured HLS cache first (no network needed),
          // then fall back to a fresh Dart HTTP fetch.
          final cached = _readHlsPlaylistCache(item.url);
          if (cached != null && _reclassifyAsHlsFromString(cached, item)) {
            return;
          }
          if (await _reclassifyAsHlsFromFetch(uri, headers, item)) return;
        }
      } catch (_) {}
    }

    if (item.type == MediaType.audio) {
      try {
        final aResp = await host.client
            .get(uri, headers: {...headers, 'Range': 'bytes=0-32767'})
            .timeout(const Duration(seconds: 10))
            .catchError((_) => http.Response('', 500));
        if (aResp.statusCode == 206 || aResp.statusCode == 200) {
          final b = aResp.bodyBytes;
          final audioResult = await _parseAudioHeadersInIsolate(b);
          if (audioResult != null) {
            audioCodec = audioResult['codec'] as String?;
            containerFormat ??= audioResult['container'] as String?;
            sampleRate = audioResult['sampleRate'] as int?;
            channels = audioResult['channels'] as int?;
            final durMs = audioResult['durationMs'] as int?;
            if (durMs != null && durMs > 0) {
              duration = Duration(milliseconds: durMs);
            }
          }
        }
      } catch (_) {}
    }

    if (item.type == MediaType.video && !_isHlsUri(uri, item) &&
        !uri.path.toLowerCase().endsWith('.mpd')) {
      try {
        final vResp = await host.client
            .get(uri, headers: {...headers, 'Range': 'bytes=0-65535'})
            .timeout(const Duration(seconds: 10))
            .catchError((_) => http.Response('', 500));
        if (vResp.statusCode == 206 || vResp.statusCode == 200) {
          final b = vResp.bodyBytes;
          final videoResult = await _parseVideoMp4AtomsInIsolate(b);
          if (videoResult != null) {
            final vw = videoResult['width'] as int?;
            final vh = videoResult['height'] as int?;
            final vCodec = videoResult['videoCodec'] as String?;
            final aCodec = videoResult['audioCodec'] as String?;
            final rawFps = videoResult['frameRate'] as double?;
            final durMs = videoResult['durationMs'] as int?;
            if (vw != null && vh != null && vw > 0 && vh > 0) {
              videoWidth = vw;
              videoHeight = vh;
              videoCodec = vCodec;
              audioCodec = aCodec;
            }
            if (rawFps != null) {
              // Round to 2 decimal places; clamp to a sane upper bound
              final clamped = rawFps.clamp(1.0, 240.0);
              frameRate = (clamped * 100).round() / 100.0;
            }
            if (durMs != null && durMs > 0) {
              duration = Duration(milliseconds: durMs);
            }
          }
        }
      } catch (_) {}
    }

    if (_isHlsUri(uri, item)) {
      debugPrint('[MediaEnricher] HLS enrichment entered for ${item.url}');
      AuroraLog.instance.debug(
        'HLS enrichment entered for ${item.url}',
        category: LogCategory.sniffer,
        screen: LogScreen.browser,
        eventType: LogEventType.sniff,
      );
      try {
        String? playlistBody;
        try {
          final cached = host.hlsPlaylistCache?.call(item.url);
          if (cached != null && cached.trim().isNotEmpty) {
            playlistBody = cached;
            debugPrint(
              '[MediaEnricher] HLS cache hit for ${item.url} (${cached.length} chars)',
            );
            AuroraLog.instance.debug(
              'HLS cache hit for ${item.url} (${cached.length} chars)',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
          }
        } catch (_) {}

        if (playlistBody == null) {
          debugPrint(
            '[MediaEnricher] HLS enrichment cache miss for ${item.url}',
          );
          AuroraLog.instance.debug(
            'HLS enrichment cache miss for ${item.url}',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
          // Race-condition mitigation: the browser_guard.js fetch hook may
          // still be cloning the response body into hlsPlaylistCache. Wait
          // briefly and re-check before falling through to network tiers.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          try {
            final retryCached = host.hlsPlaylistCache?.call(item.url);
            if (retryCached != null && retryCached.trim().isNotEmpty) {
              playlistBody = retryCached;
              debugPrint(
                '[MediaEnricher] HLS body available after 600ms retry for ${item.url}',
              );
              AuroraLog.instance.debug(
                'HLS body available after 600ms retry for ${item.url}',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.sniff,
              );
            }
          } catch (_) {}
        }

        // WebView JS fetch: bypasses Cloudflare WAF that blocks Dart's
        // http.Client. The browser has already passed the WAF (it loaded
        // the page) so its XHR shares the same TLS fingerprint / cookies /
        // IP reputation and can reach the protected playlist.
        // NOTE: cross-origin XHR is still subject to CORS — this tier may
        // fail for CDNs served from a different origin than the page.
        if (playlistBody == null && host.fetchPlaylistBodyViaWebView != null) {
          try {
            debugPrint(
              '[MediaEnricher] Trying WebView JS fetch for HLS body: ${item.url}',
            );
            AuroraLog.instance.debug(
              'Trying WebView JS fetch for HLS body: ${item.url}',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
            final jsBody = await host.fetchPlaylistBodyViaWebView!(item.url);
            if (jsBody != null && jsBody.isNotEmpty) {
              debugPrint(
                '[MediaEnricher] Fetched HLS playlist body via WebView for ${item.url} (${jsBody.length} chars)',
              );
              AuroraLog.instance.debug(
                'Fetched HLS playlist body via WebView for ${item.url} (${jsBody.length} chars)',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.sniff,
              );
              playlistBody = jsBody;
            } else {
              debugPrint(
                '[MediaEnricher] WebView playlist fetch returned null/empty for ${item.url}',
              );
              AuroraLog.instance.warn(
                'WebView playlist fetch returned null/empty for ${item.url}',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.error,
              );
            }
          } catch (e) {
            debugPrint(
              '[MediaEnricher] WebView playlist fetch threw: $e',
            );
            AuroraLog.instance.warn(
              'WebView playlist fetch threw for ${item.url}: $e',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.error,
            );
          }
        }

        // Dart HTTP: may be blocked by Cloudflare WAF (TLS fingerprint
        // detection) on protected CDNs.
        bool wasNetworkError = false;
        if (playlistBody == null) {
          final response = await host.client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 10))
              .catchError((e) {
                wasNetworkError = true;
                return http.Response('', 600); // 600 indicates socket/DNS/timeout error
              });
          if (response.statusCode >= 200 && response.statusCode < 400) {
            playlistBody = response.body;
            debugPrint(
               '[MediaEnricher] Dart HLS GET succeeded for ${item.url} (${response.body.length} chars)',
            );
            AuroraLog.instance.debug(
               'Dart HLS GET succeeded for ${item.url} (${response.body.length} chars)',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
          } else {
            debugPrint(
               '[MediaEnricher] Dart HLS GET failed for ${item.url}, status ${response.statusCode}',
            );
            AuroraLog.instance.warn(
               'Dart HLS GET failed for ${item.url}, status ${response.statusCode}',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.error,
            );
          }
        }

        // Headless WebView same-origin fetch (4th tier): navigates a
        // headless WebView to the CDN origin and issues a same-origin XHR.
        // This bypasses both CORS (same origin) and Cloudflare WAF (real
        // Chrome TLS fingerprint + cf_clearance cookie). It is the most
        // reliable fallback but the heaviest (creates a headless WebView).
        if (playlistBody == null &&
            !wasNetworkError &&
            host.fetchPlaylistBodyViaHeadlessWebView != null) {
          try {
            debugPrint(
              '[MediaEnricher] Trying headless WebView fetch for HLS body: ${item.url}',
            );
            AuroraLog.instance.debug(
              'Trying headless WebView fetch for HLS body: ${item.url}',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
            final headlessBody =
                await host.fetchPlaylistBodyViaHeadlessWebView!(item.url);
            if (headlessBody != null && headlessBody.isNotEmpty) {
              debugPrint(
                '[MediaEnricher] Fetched HLS playlist body via headless WebView for ${item.url} (${headlessBody.length} chars)',
              );
              AuroraLog.instance.debug(
                'Fetched HLS playlist body via headless WebView for ${item.url} (${headlessBody.length} chars)',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.sniff,
              );
              playlistBody = headlessBody;
            } else {
              debugPrint(
                '[MediaEnricher] Headless WebView playlist fetch returned null/empty for ${item.url}',
              );
              AuroraLog.instance.warn(
                'Headless WebView playlist fetch returned null/empty for ${item.url}',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.error,
              );
            }
          } catch (e) {
            debugPrint(
              '[MediaEnricher] Headless WebView playlist fetch threw: $e',
            );
            AuroraLog.instance.warn(
              'Headless WebView playlist fetch threw for ${item.url}: $e',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.error,
            );
          }
        }

        // --- All-tiers-failed summary ---
        if (playlistBody == null || playlistBody.trim().isEmpty) {
          debugPrint(
            '[MediaEnricher] ⚠ ALL HLS body-fetch tiers failed for ${item.url} — '
            'variants will NOT be expanded',
          );
          AuroraLog.instance.warn(
            'ALL HLS body-fetch tiers failed for ${item.url} — '
            'variants NOT expanded',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.error,
          );
        }

        if (playlistBody != null && playlistBody.isNotEmpty) {
          var playlist = HlsPlaylistParser.parse(playlistBody, uri);
          final bodyPreview = playlistBody.length > 200
              ? playlistBody.substring(0, 200)
              : playlistBody;
          debugPrint(
            '[MediaEnricher] HLS body parsed for ${item.url}: '
            'isMaster=${playlist.isMaster}, ${playlist.variants.length} variants, '
            '${playlist.segments.length} segments, body[:200]=${bodyPreview.replaceAll('\n', '\\n')}',
          );
          AuroraLog.instance.debug(
            'HLS body parsed for ${item.url}: isMaster=${playlist.isMaster}, '
            '${playlist.variants.length} variants, ${playlist.segments.length} segments',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );

          // --- Simplified-master re-fetch (Phase 2) ---
          // Some CDNs (e.g. mycloudz.cc, cloudwish.xyz on javhd.today) serve a
          // reduced 1-variant master to the browser's <video> element (client
          // detection via Sec-Fetch-Dest: video / media-player Accept headers).
          // The headless WebView's XHR sends different request headers and should
          // get the full multi-variant master that other downloaders see.
          if (playlist.isMaster &&
              playlist.variants.length <= 1 &&
              host.fetchPlaylistBodyViaHeadlessWebView != null) {
            try {
              debugPrint(
                '[MediaEnricher] Master has only ${playlist.variants.length} variant(s)'
                ' — re-fetching via headless WebView: ${item.url}',
              );
              AuroraLog.instance.debug(
                'Master has only ${playlist.variants.length} variant(s)'
                ' — re-fetching via headless WebView: ${item.url}',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.sniff,
              );
              final headlessMasterBody =
                  await host.fetchPlaylistBodyViaHeadlessWebView!(item.url);
              if (headlessMasterBody != null &&
                  headlessMasterBody.isNotEmpty &&
                  headlessMasterBody.length > playlistBody.length) {
                final fullPlaylist =
                    HlsPlaylistParser.parse(headlessMasterBody, uri);
                if (fullPlaylist.variants.length > playlist.variants.length) {
                  debugPrint(
                    '[MediaEnricher] Master re-fetched via headless WebView: '
                    '${playlist.variants.length}→${fullPlaylist.variants.length}'
                    ' variants for ${item.url}',
                  );
                  AuroraLog.instance.info(
                    'Master re-fetched via headless WebView: '
                    '${playlist.variants.length}→${fullPlaylist.variants.length}'
                    ' variants for ${item.url}',
                    category: LogCategory.sniffer,
                    screen: LogScreen.browser,
                    eventType: LogEventType.sniff,
                  );
                  // Log the full-master body preview for diagnostics
                  final fullPreview = headlessMasterBody.length > 200
                      ? headlessMasterBody.substring(0, 200)
                      : headlessMasterBody;
                  debugPrint(
                    '[MediaEnricher] Full master body[:200]=${fullPreview.replaceAll('\n', '\\n')}',
                  );
                  playlist = fullPlaylist;
                  playlistBody = headlessMasterBody;
                } else {
                  debugPrint(
                    '[MediaEnricher] Headless re-fetch did not yield more variants'
                    ' (${fullPlaylist.variants.length} vs ${playlist.variants.length})'
                    ' for ${item.url}',
                  );
                  AuroraLog.instance.debug(
                    'Headless re-fetch did not yield more variants for ${item.url}',
                    category: LogCategory.sniffer,
                    screen: LogScreen.browser,
                    eventType: LogEventType.sniff,
                  );
                }
              } else if (headlessMasterBody != null) {
                debugPrint(
                  '[MediaEnricher] Headless re-fetch returned same/smaller body'
                  ' for ${item.url}',
                );
              } else {
                debugPrint(
                  '[MediaEnricher] Headless master re-fetch returned null/empty for ${item.url}',
                );
                AuroraLog.instance.warn(
                  'Headless master re-fetch returned null/empty for ${item.url}',
                  category: LogCategory.sniffer,
                  screen: LogScreen.browser,
                  eventType: LogEventType.error,
                );
              }
            } catch (e) {
              debugPrint(
                '[MediaEnricher] Headless master re-fetch threw for ${item.url}: $e',
              );
              AuroraLog.instance.warn(
                'Headless master re-fetch threw for ${item.url}: $e',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.error,
              );
            }
          }

          if (playlist.isMaster) {
            var createdCount = 0;
            var skippedCount = 0;
            // Build a URL set once (O(n)) so the per-variant dedup check is
            // O(1) instead of O(n*v) over the whole detected-media list.
            final existingUrls = {for (final m in host.mutableDetectedMedia) m.url};
            for (final variant in playlist.variants) {
              final vUri = variant.uri;
              final vUrl = vUri.toString();
              // Skip if this variant URL already exists in the detected
              // media list (e.g. from a previous enrichment pass or from
              // sniff() capturing the active variant URL).  Prevents
              // duplicate items when the enricher re-runs on rescan.
              if (existingUrls.contains(vUrl)) {
                skippedCount++;
                continue;
              }
              int? vWidth;
              int? vHeight;
              final resStr = variant.resolution;
              if (resStr != null) {
                final resMatch = RegExp(r'^(\d+)x(\d+)$').firstMatch(resStr);
                if (resMatch != null) {
                  vWidth = int.tryParse(resMatch.group(1)!);
                  vHeight = int.tryParse(resMatch.group(2)!);
                }
              }
              final vItem = SniffedMedia(
                url: vUrl,
                name: '${item.name} (${MediaSnifferEngine.bandwidthLabel(variant.bandwidth)})',
                type: item.type,
                contentType: 'application/vnd.apple.mpegurl',
                sourcePageUrl: item.sourcePageUrl,
                headers: item.headers,
                bandwidth: variant.bandwidth,
                width: vWidth,
                height: vHeight,
                masterUrl: item.url,
              );
              host.mutableDetectedMedia.add(vItem);
              host.mediaChangedController.add(vItem);
              enqueue(vItem);
              createdCount++;
            }
            debugPrint(
              '[MediaEnricher] Master playlist expanded: '
              '$createdCount variants created, $skippedCount skipped (duplicates)'
              ' for ${item.url}',
            );
            AuroraLog.instance.info(
              'Master playlist expanded for ${item.url}: '
              '$createdCount variants created, $skippedCount skipped (duplicates)',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
          } else {
            duration = Duration(
              milliseconds: (playlist.durationSeconds * 1000).round(),
            );
            final totalByteRangeLength = playlist.totalByteRangeLength;
            if (totalByteRangeLength != null) {
              contentLength = totalByteRangeLength;
            } else if (playlist.segments.isNotEmpty) {
              // Sample up to 3 segments (first, middle, last) and average
              // their sizes for a more accurate VBR estimate.
              final segs = playlist.segments;
              final sampleIndices = <int>{};
              if (segs.length > 0) sampleIndices.add(segs.length ~/ 4);
              if (segs.length > 1) sampleIndices.add(segs.length ~/ 2);
              if (segs.length > 2) sampleIndices.add(segs.length * 3 ~/ 4);
              if (sampleIndices.isEmpty) sampleIndices.add(0);
              final sampleSizes = <int>[];

              for (final si in sampleIndices) {
                final segmentUri = segs[si].uri;
                int? segmentSize;
                try {
                  final headResp = await host.client
                      .head(segmentUri, headers: headers)
                      .timeout(const Duration(seconds: 5))
                      .catchError((_) => http.Response('', 500));
                  if (headResp.statusCode >= 200 &&
                      headResp.statusCode < 400) {
                    segmentSize = int.tryParse(
                      headResp.headers['content-length'] ?? '',
                    );
                  } else {
                    final request = http.Request('GET', segmentUri);
                    request.headers.addAll({...headers, 'Range': 'bytes=0-0'});
                    request.followRedirects = true;
                    final response = await host.client
                        .send(request)
                        .timeout(const Duration(seconds: 5));
                    if (response.statusCode >= 200 &&
                        response.statusCode < 400) {
                      final cr = response.headers['content-range'] ?? '';
                      final rm = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(cr);
                      if (rm != null) {
                        segmentSize = int.tryParse(rm.group(1)!);
                      } else {
                        final lh = response.headers['content-length'] ?? '';
                        final parsed = int.tryParse(lh);
                        if (parsed != null && parsed > 1) {
                          segmentSize = parsed;
                        }
                      }
                    }
                    unawaited(
                      response.stream.listen((_) {}).cancel().catchError((_) {}),
                    );
                  }
                } catch (_) {}

                if (segmentSize == null && host.fetchViaWebView != null) {
                  try {
                    final jsHeaders = await host.fetchViaWebView!(
                      segmentUri.toString(),
                    );
                    final statusCode = int.tryParse(
                      jsHeaders?['statusCode'] ?? '',
                    );
                    if (statusCode != null &&
                        statusCode >= 200 &&
                        statusCode < 400) {
                      final lengthHeader =
                          jsHeaders?['content-length'] ?? '';
                      if (lengthHeader.isNotEmpty) {
                        segmentSize = int.tryParse(lengthHeader);
                      }
                    }
                  } catch (_) {}
                }

                if (segmentSize != null && segmentSize > 0) {
                  sampleSizes.add(segmentSize);
                }
              }

              if (sampleSizes.isNotEmpty) {
                final avgSize =
                    sampleSizes.reduce((a, b) => a + b) ~/ sampleSizes.length;
                contentLength = avgSize * segs.length;
                debugPrint(
                  '[MediaEnricher] HLS segment sampling: '
                  '${sampleSizes.length} samples, avg=${avgSize}B, '
                  'total estimate=${contentLength}B for ${item.url}',
                );
              }
            }
          }
          contentType ??= 'application/vnd.apple.mpegurl';
        }
      } catch (e) {
        debugPrint('[MediaEnricher] HLS enrichment threw for ${item.url}: $e');
      }
    }

    if (uri.path.toLowerCase().endsWith('.mpd') ||
        (item.contentType?.toLowerCase().contains('dash+xml') ?? false)) {
      debugPrint('[MediaEnricher] DASH enrichment entered for ${item.url}');
      AuroraLog.instance.debug(
        'DASH enrichment entered for ${item.url}',
        category: LogCategory.sniffer,
        screen: LogScreen.browser,
        eventType: LogEventType.sniff,
      );
      try {
        String? manifestBody;
        try {
          final cached = host.hlsPlaylistCache?.call(item.url);
          if (cached != null && cached.trim().isNotEmpty) {
            manifestBody = cached;
            debugPrint(
              '[MediaEnricher] DASH cache hit for ${item.url} (${cached.length} chars)',
            );
            AuroraLog.instance.debug(
              'DASH cache hit for ${item.url} (${cached.length} chars)',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
          }
        } catch (_) {}

        if (manifestBody == null) {
          debugPrint(
            '[MediaEnricher] DASH enrichment cache miss for ${item.url}',
          );
          AuroraLog.instance.debug(
            'DASH enrichment cache miss for ${item.url}',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
        }

        if (manifestBody == null &&
            host.fetchPlaylistBodyViaWebView != null) {
          try {
            debugPrint(
              '[MediaEnricher] Trying WebView JS fetch for DASH body: ${item.url}',
            );
            AuroraLog.instance.debug(
              'Trying WebView JS fetch for DASH body: ${item.url}',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
            final jsBody =
                await host.fetchPlaylistBodyViaWebView!(item.url);
            if (jsBody != null && jsBody.isNotEmpty) {
              debugPrint(
                '[MediaEnricher] Fetched DASH manifest via WebView for ${item.url} (${jsBody.length} chars)',
              );
              AuroraLog.instance.debug(
                'Fetched DASH manifest via WebView for ${item.url} (${jsBody.length} chars)',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.sniff,
              );
              manifestBody = jsBody;
            } else {
              debugPrint(
                '[MediaEnricher] WebView DASH fetch returned null/empty for ${item.url}',
              );
              AuroraLog.instance.warn(
                'WebView DASH fetch returned null/empty for ${item.url}',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.error,
              );
            }
          } catch (e) {
            debugPrint(
              '[MediaEnricher] WebView DASH fetch threw: $e',
            );
            AuroraLog.instance.warn(
              'WebView DASH fetch threw for ${item.url}: $e',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.error,
            );
          }
        }

        bool wasNetworkError = false;
        if (manifestBody == null) {
          final response = await host.client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 10))
              .catchError((e) {
                wasNetworkError = true;
                return http.Response('', 600);
              });
          if (response.statusCode >= 200 && response.statusCode < 400) {
            manifestBody = response.body;
            debugPrint(
               '[MediaEnricher] Dart DASH GET succeeded for ${item.url} (${response.body.length} chars)',
            );
            AuroraLog.instance.debug(
               'Dart DASH GET succeeded for ${item.url} (${response.body.length} chars)',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
          } else {
            debugPrint(
               '[MediaEnricher] Dart DASH GET failed for ${item.url}, status ${response.statusCode}',
            );
            AuroraLog.instance.warn(
               'Dart DASH GET failed for ${item.url}, status ${response.statusCode}',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.error,
            );
          }
        }

        // Headless WebView same-origin fetch for DASH manifest body.
        if (manifestBody == null &&
            !wasNetworkError &&
            host.fetchPlaylistBodyViaHeadlessWebView != null) {
          try {
            debugPrint(
              '[MediaEnricher] Trying headless WebView fetch for DASH body: ${item.url}',
            );
            AuroraLog.instance.debug(
              'Trying headless WebView fetch for DASH body: ${item.url}',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
            final headlessBody =
                await host.fetchPlaylistBodyViaHeadlessWebView!(item.url);
            if (headlessBody != null && headlessBody.isNotEmpty) {
              debugPrint(
                '[MediaEnricher] Fetched DASH manifest via headless WebView for ${item.url} (${headlessBody.length} chars)',
              );
              AuroraLog.instance.debug(
                'Fetched DASH manifest via headless WebView for ${item.url} (${headlessBody.length} chars)',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.sniff,
              );
              manifestBody = headlessBody;
            } else {
              debugPrint(
                '[MediaEnricher] Headless WebView DASH fetch returned null/empty for ${item.url}',
              );
              AuroraLog.instance.warn(
                'Headless WebView DASH fetch returned null/empty for ${item.url}',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.error,
              );
            }
          } catch (e) {
            debugPrint(
              '[MediaEnricher] Headless WebView DASH fetch threw: $e',
            );
            AuroraLog.instance.warn(
              'Headless WebView DASH fetch threw for ${item.url}: $e',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.error,
            );
          }
        }

        // --- All-tiers-failed summary ---
        if (manifestBody == null || manifestBody.trim().isEmpty) {
          debugPrint(
            '[MediaEnricher] ⚠ ALL DASH body-fetch tiers failed for ${item.url} — '
            'variants will NOT be expanded',
          );
          AuroraLog.instance.warn(
            'ALL DASH body-fetch tiers failed for ${item.url} — '
            'variants NOT expanded',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.error,
          );
        }

        if (manifestBody != null && manifestBody.isNotEmpty) {
          final playlist = DashPlaylistParser.parse(manifestBody, uri);
          debugPrint(
            '[MediaEnricher] DASH manifest parsed for ${item.url}: '
            'isMultiVariant=${playlist.isMultiVariant}, '
            '${playlist.representations.length} representations, '
            'duration=${playlist.durationSeconds}s',
          );
          AuroraLog.instance.debug(
            'DASH manifest parsed for ${item.url}: '
            'isMultiVariant=${playlist.isMultiVariant}, '
            '${playlist.representations.length} representations',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
          if (playlist.durationSeconds > 0) {
            duration = playlist.duration;
            isLive = playlist.isLive;
          }
          if (playlist.isMultiVariant) {
            // Emit one SniffedMedia per Representation, mirroring the HLS
            // variant pattern. The estimated size uses bandwidth*duration
            // so the user gets a useful byte count without us having to
            // probe each segment.
            final baseDuration = duration ?? playlist.duration;
            var variantCount = 0;
            for (final rep in playlist.representations) {
              final variantUrl =
                  rep.mediaTemplate?.toString() ?? item.url;
              int? variantSize;
              if (rep.bandwidth > 0) {
                final durMs = baseDuration.inMilliseconds.toDouble();
                variantSize =
                    ((rep.bandwidth / 8) * (durMs / 1000)).round();
              }
              final vItem = SniffedMedia(
                url: variantUrl,
                name: '${item.name} (${rep.displayLabel})',
                type: rep.isAudio
                    ? MediaType.audio
                    : item.type,
                contentType: rep.mimeType ?? 'application/dash+xml',
                sourcePageUrl: item.sourcePageUrl,
                headers: item.headers,
                bandwidth: rep.bandwidth,
                width: rep.width,
                height: rep.height,
                frameRate: rep.frameRate,
                videoCodec: rep.codecs,
                audioCodec: rep.isAudio ? rep.codecs : null,
                sampleRate: rep.audioSamplingRate,
                masterUrl: item.url,
                channels: rep.isAudio ? 2 : null,
                containerFormat: 'mp4',
                isLive: isLive,
                contentLengthBytes: variantSize,
                isSizeEstimated: variantSize != null,
              );
              host.mutableDetectedMedia.add(vItem);
              host.mediaChangedController.add(vItem);
              enqueue(vItem);
              variantCount++;
            }
            debugPrint(
              '[MediaEnricher] DASH variants created: $variantCount for ${item.url}',
            );
            AuroraLog.instance.info(
              'DASH variants created: $variantCount for ${item.url}',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.sniff,
            );
          }
          contentType ??= 'application/dash+xml';
        }
      } catch (e) {
        debugPrint('[MediaEnricher] DASH enrichment threw for ${item.url}: $e');
      }
    }

    // Flag short clips: TS segments with estimated duration < 10 seconds.
    bool isShortClip = false;
    if (uri.path.toLowerCase().endsWith('.ts') &&
        duration != null &&
        duration.inSeconds < 10) {
      isShortClip = true;
    }

    if (host.isDisposedEngine) return;
    final index =
        host.mutableDetectedMedia.indexWhere((media) => media.url == item.url);
    if (index == -1 || host.isDisposedEngine) return;
    final isHlsPlaylist = _isHlsUri(uri, item);
    final isDashManifest = uri.path.toLowerCase().endsWith('.mpd') ||
        (item.contentType?.toLowerCase().contains('dash+xml') ?? false);
    final mediaItem = host.mutableDetectedMedia[index];
    final existingSize = mediaItem.contentLengthBytes;
    int? finalSize;
    if (isHlsPlaylist || isDashManifest) {
      // For HLS / DASH manifests, the HTTP-probed contentLength is the
      // size of the .m3u8 / .mpd body (a few hundred bytes / a few KB),
      // NOT the full video.
      // 1. If we have estimated size from segment count, use it.
      // 2. If we have a bandwidth and a duration, estimate from bandwidth.
      // 3. Fallback to existingSize.
      final itemBandwidth = mediaItem.bandwidth ?? item.bandwidth;
      final effectiveDuration = duration ?? mediaItem.duration;
      if (contentLength != null && contentLength > 10000) {
        finalSize = contentLength;
        estimated = false;
      } else if (itemBandwidth != null) {
        // Use actual duration if known, otherwise default to 1800s
        final durationMs = effectiveDuration != null
            ? effectiveDuration.inMilliseconds.toDouble()
            : 1800.0 * 1000;
        finalSize = ((itemBandwidth / 8) * (durationMs / 1000)).round();
        estimated = effectiveDuration == null;
      } else {
        finalSize = existingSize;
      }
    } else {
      finalSize = contentLength ?? existingSize;
    }
    final enriched = mediaItem.copyWith(
      contentLengthBytes: finalSize,
      contentType: contentType,
      duration: duration,
      width: videoWidth,
      height: videoHeight,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      containerFormat: containerFormat ?? mediaItem.containerFormat,
      sampleRate: sampleRate,
      channels: channels,
      isLive: isLive,
      frameRate: frameRate,
      isShortClip: isShortClip,
      isSizeEstimated: estimated,
      headers: headers,
    );
    host.mutableDetectedMedia[index] = enriched;
    if (!host.isDisposedEngine) {
      host.mediaChangedController.add(enriched);
    }
  }

  /// Returns true when the URI path contains hints that a URL might be a
  /// disguised playlist (e.g. .../hls/.../index.jpg).
  static bool _hasPlaylistPathHint(Uri uri) {
    return isPlaylistPathHint(uri.toString());
  }

  /// Checks if [bodyBytes] starts with #EXTM3U and, if so, reclassifies the
  /// [item] in the host's media list from image to video and re-enqueues it
  /// for HLS enrichment. Returns true if reclassification happened (caller
  /// should return from enrich() early).
  bool _reclassifyAsHlsFromBytes(List<int> bodyBytes, SniffedMedia item) {
    final bodyStr = String.fromCharCodes(bodyBytes);
    final trimmed = bodyStr.trimLeft();
    if (!trimmed.startsWith('#EXTM3U')) return false;

    debugPrint(
      '[MediaEnricher] Detected disguised HLS playlist (#EXTM3U) in '
      '${item.url} — reclassifying from image to video',
    );
    _updateAndReenqueueAsHls(item);
    return true;
  }

  /// Fetches the response body for [uri] and checks for #EXTM3U.
  /// If detected, reclassifies the item and returns true.
  Future<bool> _reclassifyAsHlsFromFetch(
    Uri uri,
    Map<String, String> headers,
    SniffedMedia item,
  ) async {
    try {
      final resp = await host.client
          .get(uri, headers: {...headers, 'Range': 'bytes=0-1023'})
          .timeout(const Duration(seconds: 10))
          .catchError((_) => http.Response('', 500));
      if (resp.statusCode != 206 && resp.statusCode != 200) return false;
      return _reclassifyAsHlsFromBytes(resp.bodyBytes, item);
    } catch (_) {
      return false;
    }
  }

  /// Reads the browser-captured HLS playlist body for [url] from the
  /// host's `hlsPlaylistCache` (populated by the JS body sniffing via
  /// HlsPlaylistChannel). Returns null if the cache is empty.
  String? _readHlsPlaylistCache(String url) {
    try {
      return host.hlsPlaylistCache?.call(url);
    } catch (_) {
      return null;
    }
  }

  /// Same as [_reclassifyAsHlsFromBytes] but takes a String body.
  /// Used when the body comes from the browser-captured HLS cache
  /// rather than a Dart HTTP response.
  bool _reclassifyAsHlsFromString(String body, SniffedMedia item) {
    final trimmed = body.trimLeft();
    if (!trimmed.startsWith('#EXTM3U')) return false;

    debugPrint(
      '[MediaEnricher] Detected disguised HLS playlist (#EXTM3U) in '
      'hlsPlaylistCache for ${item.url} — reclassifying from image to video',
    );
    _updateAndReenqueueAsHls(item);
    return true;
  }

  /// Updates the item in the host's media list to MediaType.video with
  /// an HLS content-type, and re-enqueues it for HLS enrichment.
  void _updateAndReenqueueAsHls(SniffedMedia item) {
    if (host.isDisposedEngine) return;
    final index =
        host.mutableDetectedMedia.indexWhere((m) => m.url == item.url);
    if (index == -1) return;
    final existing = host.mutableDetectedMedia[index];
    if (existing.type == MediaType.video ||
        existing.type == MediaType.playlist) return;

    final updated = existing.copyWith(
      type: MediaType.video,
      contentType: 'application/vnd.apple.mpegurl',
      containerFormat: 'mpeg-ts',
    );
    host.mutableDetectedMedia[index] = updated;
    if (!host.isDisposedEngine) {
      host.mediaChangedController.add(updated);
    }
    enqueue(updated);
  }

  /// Returns true when the URI or SniffedMedia metadata indicates the item
  /// is an HLS playlist (either by .m3u8 extension or by content-type).
  static bool _isHlsUri(Uri uri, SniffedMedia item) {
    final path = uri.path.toLowerCase();
    if (path.endsWith('.m3u8')) return true;
    final ct = item.contentType?.toLowerCase() ?? '';
    return ct.contains('mpegurl');
  }
}

/// Result of parsing the first MP3 frame header in an MPEG audio stream.
class _Mp3FrameInfo {
  final int bitrateKbps;
  final int sampleRate;
  final int channels;
  const _Mp3FrameInfo({
    required this.bitrateKbps,
    required this.sampleRate,
    required this.channels,
  });
}

/// Result of the lightweight MP4 audio-atom scan. Returns whatever the
/// probe could resolve: codec label (e.g. "aac"), sample rate, channel
/// count, and a duration if both `mvhd` and a media timescale are present.
class _Mp4AudioInfo {
  final String? codec;
  final int? sampleRate;
  final int? channels;
  final Duration? duration;
  const _Mp4AudioInfo({
    this.codec,
    this.sampleRate,
    this.channels,
    this.duration,
  });
}

/// Parses a 4-byte MPEG audio frame header to extract bitrate, sample
/// rate, and channel count. Returns null when the header is reserved or
/// otherwise invalid (e.g. the 4 bytes don't form a valid frame sync).
_Mp3FrameInfo? _parseMp3FrameHeader(int header) {
  // The first 11 bits must be all-1s except bit 21 (LSB of the second
  // byte), which must be 0 — i.e. 0xFF 0xE_.
  if ((header & 0xFFE00000) != 0xFFE00000) return null;

  // version: 0 = v2.5, 1 = reserved, 2 = v2, 3 = v1
  final versionBits = (header >> 19) & 0x03;
  // layer: 1 = L3, 2 = L2, 3 = L1, 0 = reserved
  final layerBits = (header >> 17) & 0x03;
  if (versionBits == 1 || layerBits == 0) return null;

  // Bitrate index is 4 bits at positions 16..13.
  final bitrateIdx = (header >> 12) & 0x0F;
  // Sample rate index is 2 bits at positions 11..10.
  final sampleRateIdx = (header >> 10) & 0x03;
  // Channel mode is 2 bits at positions 8..7. 3 = mono, others = stereo.
  final channelMode = (header >> 6) & 0x03;
  final channels = channelMode == 3 ? 1 : 2;

  // Bitrate table indexed by (version, layer) and bitrate index.
  // Each entry is kbps; 0 means "free" (we treat as invalid).
  const bitrateTable = <List<List<int>>>[
    // versionBits == 0 (v2.5) — same as v2
    [
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // reserved (layer 0)
      [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0], // L3
      [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0], // L2
      [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0], // L1
    ],
    // versionBits == 1 (reserved)
    [
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ],
    // versionBits == 2 (v2)
    [
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],
      [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],
      [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0],
    ],
    // versionBits == 3 (v1)
    [
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0],
      [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0],
      [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0],
    ],
  ];
  final bitrateKbps =
      bitrateTable[versionBits][layerBits][bitrateIdx];

  // Sample rate table indexed by versionBits and sampleRateIdx.
  // v1: 44100, 48000, 32000, reserved
  // v2: 22050, 24000, 16000, reserved
  // v2.5: 11025, 12000, 8000, reserved
  const sampleRateTable = <List<int>>[
    [11025, 12000, 8000, 0], // v2.5
    [0, 0, 0, 0], // reserved
    [22050, 24000, 16000, 0], // v2
    [44100, 48000, 32000, 0], // v1
  ];
  final sampleRate = sampleRateTable[versionBits][sampleRateIdx];

  if (bitrateKbps <= 0 || sampleRate <= 0) return null;
  return _Mp3FrameInfo(
    bitrateKbps: bitrateKbps,
    sampleRate: sampleRate,
    channels: channels,
  );
}

/// Returns true if [b] starting at [offset] contains the ASCII bytes of
/// [ascii] (case-sensitive, length must match).
bool _startsWithAscii(List<int> b, int offset, String ascii) {
  if (offset < 0 || offset + ascii.length > b.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (b[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

/// Scans the leading bytes of an MP4/ISO BMFF stream for audio-specific
/// atoms: `mvhd` (movie duration), `mdhd` (track timescale), and `mp4a`
/// (channel count + sample rate). Mirrors the structure of the video
/// probe but only fills in audio-relevant fields.
_Mp4AudioInfo? _parseMp4AudioAtoms(List<int> b) {
  int? movieTimescale;
  int? movieDuration;
  int? mdhdTimescale;
  int? mp4aSampleRate;
  int? mp4aChannels;
  bool foundMp4a = false;

  // Bounds check: 40 bytes of lookahead is more than enough for any
  // fixed-size header we read (mvhd needs 36, mdhd 32, mp4a 32).
  for (var i = 0; i < b.length - 40; i++) {
    // mvhd
    if (b[i] == 0x6D &&
        b[i + 1] == 0x76 &&
        b[i + 2] == 0x68 &&
        b[i + 3] == 0x64) {
      final ver = b[i + 4];
      if (ver == 1) {
        if (i + 36 <= b.length) {
          movieTimescale =
              (b[i + 24] << 24) |
              (b[i + 25] << 16) |
              (b[i + 26] << 8) |
              b[i + 27];
          var d = 0;
          for (var j = 0; j < 8; j++) {
            d = (d << 8) | b[i + 28 + j];
          }
          movieDuration = d;
        }
      } else {
        if (i + 24 <= b.length) {
          movieTimescale =
              (b[i + 16] << 24) |
              (b[i + 17] << 16) |
              (b[i + 18] << 8) |
              b[i + 19];
          movieDuration =
              (b[i + 20] << 24) |
              (b[i + 21] << 16) |
              (b[i + 22] << 8) |
              b[i + 23];
        }
      }
    }
    // mdhd
    if (b[i] == 0x6D &&
        b[i + 1] == 0x64 &&
        b[i + 2] == 0x68 &&
        b[i + 3] == 0x64) {
      final ver = b[i + 4];
      final tsOff = ver == 1 ? i + 28 : i + 20;
      if (tsOff + 4 <= b.length) {
        mdhdTimescale =
            (b[tsOff] << 24) |
            (b[tsOff + 1] << 16) |
            (b[tsOff + 2] << 8) |
            b[tsOff + 3];
      }
    }
    // mp4a — the audio sample entry inside stsd. The "Audio Sample Entry"
    // (ISO 14496-12) layout after the 4-byte "mp4a" type is:
    //   reserved(6) + data_ref_index(2) + reserved(8) + channel_count(2)
    //   + sample_size(2) + compression_id(2) + packet_size(2) +
    //   sample_rate(4) — stored as 16.16 fixed point.
    // Since the "mp4a" magic lives at b[i..i+3], the rest of the box
    // body (which we treat as starting right after the 4-byte type) is
    // at offsets i+4 and beyond, even though the full box header also
    // includes a 4-byte size before the type.
    if (b[i] == 0x6D &&
        b[i + 1] == 0x70 &&
        b[i + 2] == 0x34 &&
        b[i + 3] == 0x61) {
      if (i + 32 <= b.length) {
        // channel_count at i+20 (6 reserved + 2 dref + 8 reserved + 2 ch).
        mp4aChannels = (b[i + 20] << 8) | b[i + 21];
        // sample_rate at i+28, upper 16 bits are the integer Hz part.
        mp4aSampleRate = (b[i + 28] << 8) | b[i + 29];
        if (mp4aSampleRate > 0) {
          foundMp4a = true;
        }
      }
    }
  }

  Duration? dur;
  if (movieDuration != null && movieTimescale != null && movieTimescale > 0) {
    final seconds = movieDuration / movieTimescale;
    if (seconds > 0 && seconds < 24 * 3600) {
      dur = Duration(milliseconds: (seconds * 1000).round());
    }
  }

  if (!foundMp4a &&
      mdhdTimescale == null &&
      movieDuration == null) {
    return null;
  }

  return _Mp4AudioInfo(
    codec: foundMp4a ? 'aac' : null,
    sampleRate: mp4aSampleRate,
    channels: mp4aChannels,
    duration: dur,
  );
}

// ---------------------------------------------------------------------------
// Isolate-parsing helpers — each runs binary header/atom analysis off the UI
// isolate so that media enrichment does not block the render thread.
// ---------------------------------------------------------------------------

/// Parse image dimensions (JPEG/PNG/GIF/WEBP) from raw bytes on a background
/// isolate. Returns `{width, height}` or null.
Future<Map<String, int>?> _parseImageDimensionsInIsolate(Uint8List bytes) async {
  return Isolate.run<Map<String, int>?>(() {
    int? w, h;
    if (bytes.length > 6 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      for (var i = 0; i < bytes.length - 5; i++) {
        if (bytes[i] == 0xFF && (bytes[i + 1] & 0xF0) == 0xC0) {
          h = (bytes[i + 5] << 8) | bytes[i + 6];
          w = (bytes[i + 7] << 8) | bytes[i + 8];
          break;
        }
      }
    } else if (bytes.length > 8 &&
        bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4E && bytes[3] == 0x47) {
      w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    } else if (bytes.length > 6 &&
        bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      w = bytes[6] | (bytes[7] << 8);
      h = bytes[8] | (bytes[9] << 8);
    } else if (bytes.length > 20 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 &&
        bytes[2] == 0x46 && bytes[3] == 0x46) {
      w = ((bytes[26] & 0x3F) << 8) | bytes[27];
      h = (((bytes[26] >> 6) | (bytes[28] << 2)) << 8) | bytes[29];
    }
    if (w != null && h != null && w > 0 && h > 0) {
      return {'width': w, 'height': h};
    }
    return null;
  });
}

/// Parse audio binary headers (MP3/ID3v2, FLAC, OGG Vorbis, M4A/mp4a) on a
/// background isolate. Returns a map with keys: codec, container, sampleRate,
/// channels, durationMs — any may be null.
Future<Map<String, dynamic>?> _parseAudioHeadersInIsolate(Uint8List b) async {
  return Isolate.run<Map<String, dynamic>?>(() {
    if (b.length < 4) return null;
    String? audioCodec;
    String? containerFormat;
    int? sampleRate;
    int? channels;
    int? durationMs;

    // -- MP3 / ID3v2 --
    var scanFrom = 0;
    if (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
      if (b.length >= 10) {
        final tagSize = (b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9];
        scanFrom = 10 + tagSize;
      }
    }
    if (scanFrom < b.length - 4 &&
        b[scanFrom] == 0xFF && (b[scanFrom + 1] & 0xE0) == 0xE0) {
      final mp3Header = (b[scanFrom] << 24) |
          (b[scanFrom + 1] << 16) |
          (b[scanFrom + 2] << 8) |
          b[scanFrom + 3];
      final mp3Parsed = _parseMp3FrameHeader(mp3Header);
      if (mp3Parsed != null) {
        audioCodec = 'mp3';
        containerFormat ??= 'mp3';
        sampleRate = mp3Parsed.sampleRate;
        channels = mp3Parsed.channels;
      }
    } else if (b[0] == 0x66 && b[1] == 0x4C &&
        b[2] == 0x61 && b[3] == 0x43) {
      // -- FLAC --
      if (b.length >= 42) {
        final sr = (b[18] << 12) | (b[19] << 4) | (b[20] >> 4);
        final ch = ((b[20] >> 1) & 0x07) + 1;
        var totalSamples = (b[21] & 0x0F);
        for (var k = 0; k < 4; k++) {
          totalSamples = (totalSamples << 8) | b[22 + k];
        }
        audioCodec = 'flac';
        containerFormat ??= 'flac';
        sampleRate = sr > 0 ? sr : null;
        channels = ch;
        if (sr > 0 && totalSamples > 0) {
          final seconds = totalSamples / sr;
          if (seconds > 0 && seconds < 24 * 3600) {
            durationMs = (seconds * 1000).round();
          }
        }
      }
    } else if (b[0] == 0x4F && b[1] == 0x67 &&
        b[2] == 0x67 && b[3] == 0x53) {
      // -- OGG Vorbis --
      if (b.length >= 30) {
        final segCount = b[26];
        var payloadStart = 27 + segCount;
        if (payloadStart + 1 < b.length && b[payloadStart] == 0x01) {
          if (payloadStart + 30 <= b.length &&
              _startsWithAscii(b, payloadStart + 1, 'vorbis')) {
            channels = b[payloadStart + 11];
            sampleRate = b[payloadStart + 12] |
                (b[payloadStart + 13] << 8) |
                (b[payloadStart + 14] << 16) |
                (b[payloadStart + 15] << 24);
            audioCodec = 'vorbis';
            containerFormat ??= 'ogg';
            sampleRate = sampleRate > 0 ? sampleRate : null;
            channels = channels > 0 ? channels : null;
          }
        }
      }
    } else if (b.length > 8 &&
        b[4] == 0x66 && b[5] == 0x74 &&
        b[6] == 0x79 && b[7] == 0x70) {
      // -- M4A / ISO BMFF audio --
      final audioMp4 = _parseMp4AudioAtoms(b);
      if (audioMp4 != null) {
        audioCodec = audioMp4.codec ?? 'aac';
        containerFormat ??= 'mp4';
        sampleRate = audioMp4.sampleRate;
        channels = audioMp4.channels;
        if (audioMp4.duration != null) {
          durationMs = audioMp4.duration!.inMilliseconds;
        }
      }
    }

    if (audioCodec == null && sampleRate == null && channels == null) {
      return null;
    }
    return {
      'codec': audioCodec,
      'container': containerFormat,
      'sampleRate': sampleRate,
      'channels': channels,
      'durationMs': durationMs,
    };
  });
}

/// Parse MP4 atoms (tkhd, mvhd, mdhd, stts) on a background isolate to
/// extract video dimensions, framerate, duration, and codec hints.
/// Returns a map with keys: width, height, videoCodec, audioCodec, frameRate,
/// durationMs — any may be null.
Future<Map<String, dynamic>?> _parseVideoMp4AtomsInIsolate(Uint8List b) async {
  return Isolate.run<Map<String, dynamic>?>(() {
    int? vw, vh;
    Duration? movieDuration;
    int? trackTimescale;
    int? firstSampleDelta;

    for (var i = 0; i < b.length - 80; i++) {
      // tkhd
      if (b[i] == 0x74 && b[i + 1] == 0x6B &&
          b[i + 2] == 0x68 && b[i + 3] == 0x64) {
        final ver = b[i + 4];
        final wOff = ver == 1 ? i + 92 : i + 80;
        final hOff = wOff + 4;
        if (hOff + 4 <= b.length) {
          final vwRaw = (b[wOff] << 24) | (b[wOff + 1] << 16) |
              (b[wOff + 2] << 8) | b[wOff + 3];
          final vhRaw = (b[hOff] << 24) | (b[hOff + 1] << 16) |
              (b[hOff + 2] << 8) | b[hOff + 3];
          vw = vwRaw >> 16;
          vh = vhRaw >> 16;
        }
      }
      // mvhd
      if (b[i] == 0x6D && b[i + 1] == 0x76 &&
          b[i + 2] == 0x68 && b[i + 3] == 0x64) {
        final ver = b[i + 4];
        if (ver == 1) {
          if (i + 36 <= b.length) {
            final timescale = (b[i + 24] << 24) | (b[i + 25] << 16) |
                (b[i + 26] << 8) | b[i + 27];
            var durationRaw = 0;
            for (var j = 0; j < 8; j++) {
              durationRaw = (durationRaw << 8) | b[i + 28 + j];
            }
            if (timescale > 0 && durationRaw > 0) {
              movieDuration = Duration(
                milliseconds: ((durationRaw * 1000) / timescale).round(),
              );
            }
          }
        } else {
          if (i + 24 <= b.length) {
            final timescale = (b[i + 16] << 24) | (b[i + 17] << 16) |
                (b[i + 18] << 8) | b[i + 19];
            final durationRaw = (b[i + 20] << 24) | (b[i + 21] << 16) |
                (b[i + 22] << 8) | b[i + 23];
            if (timescale > 0 && durationRaw > 0) {
              movieDuration = Duration(
                milliseconds: ((durationRaw * 1000) / timescale).round(),
              );
            }
          }
        }
      }
      // mdhd
      if (b[i] == 0x6D && b[i + 1] == 0x64 &&
          b[i + 2] == 0x68 && b[i + 3] == 0x64) {
        final ver = b[i + 4];
        final tsOff = ver == 1 ? i + 28 : i + 16;
        if (tsOff + 4 <= b.length) {
          final ts = (b[tsOff] << 24) | (b[tsOff + 1] << 16) |
              (b[tsOff + 2] << 8) | b[tsOff + 3];
          if (ts > 0) trackTimescale = ts;
        }
      }
      // stts
      if (b[i] == 0x73 && b[i + 1] == 0x74 &&
          b[i + 2] == 0x74 && b[i + 3] == 0x73) {
        if (i + 20 <= b.length) {
          final sampleDelta = (b[i + 16] << 24) | (b[i + 17] << 16) |
              (b[i + 18] << 8) | b[i + 19];
          if (sampleDelta > 0) firstSampleDelta = sampleDelta;
        }
      }
    }

    double? frameRate;
    if (trackTimescale != null && firstSampleDelta != null) {
      final rawFps = trackTimescale / firstSampleDelta;
      final clamped = rawFps.clamp(1.0, 240.0);
      frameRate = (clamped * 100).round() / 100.0;
    }

    // Codec detection from string patterns in bytes
    String? vCodec, aCodec;
    final bodyStr = String.fromCharCodes(b);
    if (bodyStr.contains('avcC')) {
      vCodec = 'h264';
    } else if (bodyStr.contains('hvcC')) {
      vCodec = 'h265';
    } else if (bodyStr.contains('vpcC')) {
      vCodec = 'vp9';
    }
    if (bodyStr.contains('mp4a')) {
      aCodec = 'aac';
    } else if (bodyStr.contains('Opus')) {
      aCodec = 'opus';
    }

    return {
      'width': vw,
      'height': vh,
      'videoCodec': vCodec,
      'audioCodec': aCodec,
      'frameRate': frameRate,
      'durationMs': movieDuration?.inMilliseconds,
    };
  });
}
