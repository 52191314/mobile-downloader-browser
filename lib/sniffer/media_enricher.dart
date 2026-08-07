import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'media_binary_parsers.dart';
import 'worker_isolate_pool.dart';

import '../downloader/hls_playlist_parser.dart';
import '../downloader/hls_size_estimator.dart';
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
      // Tier 1: HEAD Request (offloaded to isolate).
      // Capture result regardless of status so we can detect 403/401 (WAF
      // blocks) and skip straight to Tier 4 instead of wasting time on more
      // HTTP probes that will also be blocked.
      final headResult = await _probeInIsolate(
        method: 'HEAD',
        url: item.url,
        headers: headers,
        onlySuccess: false, // capture status code even on error
      );
      if (headResult != null) {
        final status = headResult['statusCode'] as int? ?? 0;
        if (status >= 200 && status < 400) {
          final headContentRange = headResult['contentRange'] as String? ?? '';
          final headRangeMatch = RegExp(
            r'bytes \d+-\d+/(\d+)',
          ).firstMatch(headContentRange);
          if (headRangeMatch != null) {
            contentLength = int.tryParse(headRangeMatch.group(1)!);
          } else {
            contentLength = headResult['contentLength'] as int?;
          }
          contentType = headResult['contentType'] as String?;
          debugPrint(
            '[MediaEnricher] Tier 1 HEAD '
            'content-length=$contentLength for ${item.url}',
          );
        } else if (status == 403 || status == 401) {
          // WAF/blocked — skip Tiers 2-3 (they'll fail too), go to Tier 4.
          debugPrint(
            '[MediaEnricher] Tier 1 HEAD got $status → WAF likely, '
            'skipping HTTP fallback tiers for ${item.url}',
          );
        } else {
          // Non-2xx non-WAF — fall through to Tiers 2-4.
          debugPrint(
            '[MediaEnricher] Tier 1 HEAD status=$status for ${item.url}',
          );
        }
      }
      // Tiers 2-3: HTTP probes (only when Tier 1 didn't return a WAF code).
      if (contentLength == null && headResult?['statusCode'] is int) {
        final status = headResult!['statusCode'] as int;
        if (status != 403 && status != 401) {
          // Tier 2: GET with Range: bytes=0-0
          bool gotSize = false;
          try {
            final rangeResult = await _probeInIsolate(
              method: 'GET',
              url: item.url,
              headers: headers,
              range: 'bytes=0-0',
              timeoutSeconds: 3, // short timeout for non-2xx responses
            );
            if (rangeResult != null) {
              final cr = rangeResult['contentRange'] as String? ?? '';
              final rangeMatch = RegExp(
                r'bytes \d+-\d+/(\d+)',
              ).firstMatch(cr);
              final lengthInt = rangeResult['contentLength'] as int?;
              if (rangeMatch != null) {
                contentLength = int.tryParse(rangeMatch.group(1)!);
                gotSize = true;
              } else if (lengthInt != null && lengthInt > 1) {
                contentLength = lengthInt;
                gotSize = true;
              }
              contentType = rangeResult['contentType'] as String?;
            }
            debugPrint(
              '[MediaEnricher] Tier 2 Range-GET '
              'gotSize=$gotSize content-length=$contentLength for ${item.url}',
            );
          } catch (e) {
            debugPrint(
              '[MediaEnricher] Tier 2 Range-GET threw for ${item.url}: $e',
            );
          }

          // Tier 3: plain GET without Range
          if (!gotSize) {
            try {
              final getResult = await _probeInIsolate(
                method: 'GET',
                url: item.url,
                headers: headers,
                timeoutSeconds: 3,
              );
              if (getResult != null) {
                final lengthInt = getResult['contentLength'] as int?;
                if (lengthInt != null) {
                  contentLength = lengthInt;
                }
                contentType = getResult['contentType'] as String?;
              }
              debugPrint(
                '[MediaEnricher] Tier 3 GET '
                'content-length=$contentLength for ${item.url}',
              );
            } catch (e) {
              debugPrint(
                '[MediaEnricher] Tier 3 GET threw for ${item.url}: $e',
              );
            }
          }
        }
      }
    } catch (e, s) {
      debugPrint('[MediaEnricher] enrich() threw for ${item.url}: $e\n$s');
    }

    // Tier 4: WebView JS fetch (bypasses Cloudflare WAF). Used when all
    // HTTP tiers failed OR when Tier 1 detected a WAF block (403/401).
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
        final imgResult = await _probeInIsolate(
          method: 'GET',
          url: item.url,
          headers: headers,
          range: 'bytes=0-2047',
        );
        if (imgResult != null) {
          final b = Uint8List.fromList((imgResult['bodyBytes'] as List<int>?) ?? []);
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
        final aResult = await _probeInIsolate(
          method: 'GET',
          url: item.url,
          headers: headers,
          range: 'bytes=0-32767',
        );
        if (aResult != null) {
          final b = Uint8List.fromList((aResult['bodyBytes'] as List<int>?) ?? []);
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
        final vResult = await _probeInIsolate(
          method: 'GET',
          url: item.url,
          headers: headers,
          range: 'bytes=0-65535',
        );
        if (vResult != null) {
          final b = Uint8List.fromList((vResult['bodyBytes'] as List<int>?) ?? []);
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
      debugPrint('HLS enrichment entered for ${item.url}');
      try {
        String? playlistBody;
        try {
          final cached = host.hlsPlaylistCache?.call(item.url);
          if (cached != null && cached.trim().isNotEmpty) {
            playlistBody = cached;
            debugPrint(
              '[MediaEnricher] HLS cache hit for ${item.url} (${cached.length} chars)',
            );
            debugPrint('HLS cache hit for ${item.url} (${cached.length} chars)');
          }
        } catch (_) {}

        if (playlistBody == null) {
          debugPrint(
            '[MediaEnricher] HLS enrichment cache miss for ${item.url}',
          );
          debugPrint('HLS enrichment cache miss for ${item.url}');
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
              debugPrint('HLS body available after 600ms retry for ${item.url}');
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
            debugPrint('Trying WebView JS fetch for HLS body: ${item.url}');
            final jsBody = await host.fetchPlaylistBodyViaWebView!(item.url);
            if (jsBody != null && jsBody.isNotEmpty) {
              debugPrint(
                '[MediaEnricher] Fetched HLS playlist body via WebView for ${item.url} (${jsBody.length} chars)',
              );
              debugPrint('Fetched HLS playlist body via WebView for ${item.url} (${jsBody.length} chars)');
              playlistBody = jsBody;
            } else {
              debugPrint(
                '[MediaEnricher] WebView playlist fetch returned null/empty for ${item.url}',
              );
              debugPrint('WebView playlist fetch returned null/empty for ${item.url}');
            }
          } catch (e) {
            debugPrint(
              '[MediaEnricher] WebView playlist fetch threw: $e',
            );
            debugPrint('WebView playlist fetch threw for ${item.url}: $e');
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
            debugPrint('Dart HLS GET succeeded for ${item.url} (${response.body.length} chars)');
          } else {
            debugPrint(
               '[MediaEnricher] Dart HLS GET failed for ${item.url}, status ${response.statusCode}',
            );
            debugPrint('Dart HLS GET failed for ${item.url}, status ${response.statusCode}');
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
            debugPrint('Trying headless WebView fetch for HLS body: ${item.url}');
            final headlessBody =
                await host.fetchPlaylistBodyViaHeadlessWebView!(item.url);
            if (headlessBody != null && headlessBody.isNotEmpty) {
              debugPrint(
                '[MediaEnricher] Fetched HLS playlist body via headless WebView for ${item.url} (${headlessBody.length} chars)',
              );
              debugPrint('Fetched HLS playlist body via headless WebView for ${item.url} (${headlessBody.length} chars)');
              playlistBody = headlessBody;
            } else {
              debugPrint(
                '[MediaEnricher] Headless WebView playlist fetch returned null/empty for ${item.url}',
              );
              debugPrint('Headless WebView playlist fetch returned null/empty for ${item.url}');
            }
          } catch (e) {
            debugPrint(
              '[MediaEnricher] Headless WebView playlist fetch threw: $e',
            );
            debugPrint('Headless WebView playlist fetch threw for ${item.url}: $e');
          }
        }

        // --- All-tiers-failed summary ---
        if (playlistBody == null || playlistBody.trim().isEmpty) {
          debugPrint(
            '[MediaEnricher] ⚠ ALL HLS body-fetch tiers failed for ${item.url} — '
            'variants will NOT be expanded',
          );
          debugPrint('ALL HLS body-fetch tiers failed for ${item.url} — '
            'variants NOT expanded');
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
          debugPrint('HLS body parsed for ${item.url}: isMaster=${playlist.isMaster}, '
            '${playlist.variants.length} variants, ${playlist.segments.length} segments');

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
              debugPrint('Master has only ${playlist.variants.length} variant(s)'
                ' — re-fetching via headless WebView: ${item.url}');
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
                  debugPrint('Master re-fetched via headless WebView: '
                    '${playlist.variants.length}→${fullPlaylist.variants.length}'
                    ' variants for ${item.url}');
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
                  debugPrint('Headless re-fetch did not yield more variants for ${item.url}');
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
                debugPrint('Headless master re-fetch returned null/empty for ${item.url}');
              }
            } catch (e) {
              debugPrint(
                '[MediaEnricher] Headless master re-fetch threw for ${item.url}: $e',
              );
              debugPrint('Headless master re-fetch threw for ${item.url}: $e');
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
              if (host.isDisposedEngine) continue;
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
            debugPrint('Master playlist expanded for ${item.url}: '
              '$createdCount variants created, $skippedCount skipped (duplicates)');
          } else {
            duration = Duration(
              milliseconds: (playlist.durationSeconds * 1000).round(),
            );
            // Best-in-class size estimate:
            // byte-range exact → duration-weighted samples → avg×count
            // → bandwidth×duration.
            final segs = playlist.segments;
            int initBytes = 0;
            if (playlist.initSegmentUri != null) {
              initBytes = await _probeSegmentContentLength(
                    playlist.initSegmentUri!,
                    headers,
                  ) ??
                  0;
            }

            final samples = <HlsSizeSample>[];
            // Probe at most 2 segments with a single HEAD to get a rough
            // size estimate.  The old value of 8 produced up to 64 HTTP
            // probes for 4-variant pages — wasted bandwidth for cosmetic
            // sizes that are already estimated via bandwidth×duration.
            if (playlist.totalByteRangeLength == null && segs.isNotEmpty) {
              final indices = HlsSizeEstimator.selectSampleIndices(
                segs.length,
                maxSamples: segs.length <= 6 ? segs.length : 2,
              );
              for (final si in indices) {
                final segmentUri = segs[si].uri;
                final segmentSize =
                    await _probeSegmentContentLength(segmentUri, headers);
                if (segmentSize != null &&
                    segmentSize >= HlsSizeEstimator.minSegmentBytes &&
                    segmentSize <= HlsSizeEstimator.maxSegmentBytes) {
                  samples.add(HlsSizeSample(
                    index: si,
                    bytes: segmentSize,
                    durationSeconds: segs[si].durationSeconds,
                  ));
                }
              }
            }

            final estimate = HlsSizeEstimator.estimate(
              playlist: playlist,
              samples: samples,
              bandwidthBps: item.bandwidth,
              initSegmentBytes: initBytes,
            );
            if (estimate.totalBytes != null && estimate.totalBytes! > 0) {
              contentLength = estimate.totalBytes;
              estimated = estimate.isEstimated;
              debugPrint(
                '[MediaEnricher] HLS size ${estimate.source.name}: '
                '${estimate.totalBytes}B (${estimate.detail}) for ${item.url}',
              );
              debugPrint('HLS size ${estimate.source.name}: ${estimate.totalBytes}B '
                '(${estimate.detail}) for ${item.url}');
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
      debugPrint('DASH enrichment entered for ${item.url}');
      try {
        String? manifestBody;
        try {
          final cached = host.hlsPlaylistCache?.call(item.url);
          if (cached != null && cached.trim().isNotEmpty) {
            manifestBody = cached;
            debugPrint(
              '[MediaEnricher] DASH cache hit for ${item.url} (${cached.length} chars)',
            );
            debugPrint('DASH cache hit for ${item.url} (${cached.length} chars)');
          }
        } catch (_) {}

        if (manifestBody == null) {
          debugPrint(
            '[MediaEnricher] DASH enrichment cache miss for ${item.url}',
          );
          debugPrint('DASH enrichment cache miss for ${item.url}');
        }

        if (manifestBody == null &&
            host.fetchPlaylistBodyViaWebView != null) {
          try {
            debugPrint(
              '[MediaEnricher] Trying WebView JS fetch for DASH body: ${item.url}',
            );
            debugPrint('Trying WebView JS fetch for DASH body: ${item.url}');
            final jsBody =
                await host.fetchPlaylistBodyViaWebView!(item.url);
            if (jsBody != null && jsBody.isNotEmpty) {
              debugPrint(
                '[MediaEnricher] Fetched DASH manifest via WebView for ${item.url} (${jsBody.length} chars)',
              );
              debugPrint('Fetched DASH manifest via WebView for ${item.url} (${jsBody.length} chars)');
              manifestBody = jsBody;
            } else {
              debugPrint(
                '[MediaEnricher] WebView DASH fetch returned null/empty for ${item.url}',
              );
              debugPrint('WebView DASH fetch returned null/empty for ${item.url}');
            }
          } catch (e) {
            debugPrint(
              '[MediaEnricher] WebView DASH fetch threw: $e',
            );
            debugPrint('WebView DASH fetch threw for ${item.url}: $e');
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
            debugPrint('Dart DASH GET succeeded for ${item.url} (${response.body.length} chars)');
          } else {
            debugPrint(
               '[MediaEnricher] Dart DASH GET failed for ${item.url}, status ${response.statusCode}',
            );
            debugPrint('Dart DASH GET failed for ${item.url}, status ${response.statusCode}');
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
            debugPrint('Trying headless WebView fetch for DASH body: ${item.url}');
            final headlessBody =
                await host.fetchPlaylistBodyViaHeadlessWebView!(item.url);
            if (headlessBody != null && headlessBody.isNotEmpty) {
              debugPrint(
                '[MediaEnricher] Fetched DASH manifest via headless WebView for ${item.url} (${headlessBody.length} chars)',
              );
              debugPrint('Fetched DASH manifest via headless WebView for ${item.url} (${headlessBody.length} chars)');
              manifestBody = headlessBody;
            } else {
              debugPrint(
                '[MediaEnricher] Headless WebView DASH fetch returned null/empty for ${item.url}',
              );
              debugPrint('Headless WebView DASH fetch returned null/empty for ${item.url}');
            }
          } catch (e) {
            debugPrint(
              '[MediaEnricher] Headless WebView DASH fetch threw: $e',
            );
            debugPrint('Headless WebView DASH fetch threw for ${item.url}: $e');
          }
        }

        // --- All-tiers-failed summary ---
        if (manifestBody == null || manifestBody.trim().isEmpty) {
          debugPrint(
            '[MediaEnricher] ⚠ ALL DASH body-fetch tiers failed for ${item.url} — '
            'variants will NOT be expanded',
          );
          debugPrint('ALL DASH body-fetch tiers failed for ${item.url} — '
            'variants NOT expanded');
        }

        if (manifestBody != null && manifestBody.isNotEmpty) {
          final playlist = DashPlaylistParser.parse(manifestBody, uri);
          debugPrint(
            '[MediaEnricher] DASH manifest parsed for ${item.url}: '
            'isMultiVariant=${playlist.isMultiVariant}, '
            '${playlist.representations.length} representations, '
            'duration=${playlist.durationSeconds}s',
          );
          debugPrint('DASH manifest parsed for ${item.url}: '
            'isMultiVariant=${playlist.isMultiVariant}, '
            '${playlist.representations.length} representations');
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
            // Dedup check — same pattern as HLS variant loop above.
            final existingUrls = {for (final m in host.mutableDetectedMedia) m.url};
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
              if (existingUrls.contains(variantUrl)) {
                continue;
              }
              if (host.isDisposedEngine) continue;
              existingUrls.add(variantUrl);
              host.mutableDetectedMedia.add(vItem);
              host.mediaChangedController.add(vItem);
              enqueue(vItem);
              variantCount++;
            }
            debugPrint(
              '[MediaEnricher] DASH variants created: $variantCount for ${item.url}',
            );
            debugPrint('DASH variants created: $variantCount for ${item.url}');
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
    // Preserve whether contentLength came from a real probe vs estimate.
    // The HLS branch above sets `estimated` when using samples/bandwidth.
    var sizeIsEstimated = estimated;
    if (isHlsPlaylist || isDashManifest) {
      // For HLS / DASH manifests, a tiny HTTP contentLength is the
      // playlist body itself — never treat it as the full media size.
      final itemBandwidth = mediaItem.bandwidth ?? item.bandwidth;
      final effectiveDuration = duration ?? mediaItem.duration;
      if (contentLength != null && contentLength > 10000) {
        // Sampled/byte-range/bandwidth estimate produced by the HLS path.
        finalSize = contentLength;
        // Keep sizeIsEstimated as set by the estimator (exact byte-range
        // sets estimated=false; samples set estimated=true).
      } else if (itemBandwidth != null &&
          effectiveDuration != null &&
          effectiveDuration.inSeconds > 0) {
        // Only use bandwidth×duration when we know the real duration.
        // Never invent a 1800s default — that massively over-estimates.
        final durationMs = effectiveDuration.inMilliseconds.toDouble();
        finalSize = ((itemBandwidth / 8) * (durationMs / 1000)).round();
        sizeIsEstimated = true;
      } else if (existingSize != null && existingSize > 10000) {
        finalSize = existingSize;
        sizeIsEstimated = mediaItem.isSizeEstimated;
      } else {
        // Unknown — leave null rather than a misleading playlist-body size.
        finalSize = null;
        sizeIsEstimated = true;
      }
    } else {
      finalSize = contentLength ?? existingSize;
      sizeIsEstimated = estimated && contentLength == null;
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
      isSizeEstimated: sizeIsEstimated,
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

  // ---------------------------------------------------------------------------
  // Offloaded helpers — dispatch to the persistent worker-isolate pool.
  // Falls back to main-thread execution when the pool is unavailable (e.g.
  // in test environments where Isolate.spawn is limited).
  // ---------------------------------------------------------------------------

  /// Returns true when running inside `flutter test`.
  bool _isTestEnvironment() {
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  /// Parse image dimensions on a background worker. Returns `{width, height}`
  /// or null.
  Future<Map<String, int>?> _parseImageDimensionsInIsolate(
      Uint8List bytes) async {
    if (_isTestEnvironment()) {
      return Future.value(parseImageDimensions(bytes));
    }
    try {
      final result = await WorkerIsolatePool.instance.execute('parseImage', {
        'bytes': bytes.toList(),
      });
      return result as Map<String, int>?;
    } catch (_) {
      return null;
    }
  }

  /// Parse audio binary headers on a background worker. Returns a map with
  /// keys: codec, container, sampleRate, channels, durationMs — any may be null.
  Future<Map<String, dynamic>?> _parseAudioHeadersInIsolate(
      Uint8List b) async {
    if (_isTestEnvironment()) {
      return Future.value(parseAudioHeaders(b));
    }
    try {
      final result = await WorkerIsolatePool.instance.execute('parseAudio', {
        'bytes': b.toList(),
      });
      return result as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// Parse MP4 atoms on a background worker. Returns a map with keys: width,
  /// height, videoCodec, audioCodec, frameRate, durationMs — any may be null.
  Future<Map<String, dynamic>?> _parseVideoMp4AtomsInIsolate(
      Uint8List b) async {
    if (_isTestEnvironment()) {
      return Future.value(parseVideoMp4Atoms(b));
    }
    try {
      final result = await WorkerIsolatePool.instance.execute('parseMp4', {
        'bytes': b.toList(),
      });
      return result as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// Probe a segment URI for Content-Length (HEAD only, no fallback).
  /// Segment size is cosmetic (the estimate is marked `isEstimated = true`),
  /// so a single fast HEAD suffices — the Range-GET + WebView JS ladder
  /// was removed to avoid up to 64 redundant probes on multi-variant pages.
  Future<int?> _probeSegmentContentLength(
    Uri segmentUri,
    Map<String, String> headers,
  ) async {
    try {
      final headResult = await _probeInIsolate(
        method: 'HEAD',
        url: segmentUri.toString(),
        headers: headers,
        timeoutSeconds: 5,
        onlySuccess: true,
      );
      if (headResult != null) {
        final len = headResult['contentLength'] as int?;
        if (len != null && len > 0) return len;
      }
    } catch (_) {}
    return null;
  }

  /// Runs an HTTP probe (HEAD or GET with optional Range) via the persistent
  /// worker pool so network I/O never blocks the UI thread. Returns a map
  /// with `statusCode`, `contentType`, `contentLength`, `contentRange`,
  /// `headers`, and `bodyBytes`, or null on failure.
  Future<Map<String, dynamic>?> _probeInIsolate({
    required String method,
    required String url,
    required Map<String, String> headers,
    String? range,
    int timeoutSeconds = 10,
    bool onlySuccess = false,
  }) async {
    if (_isTestEnvironment()) {
      return _runProbeDirect(method, url, headers,
          range: range, timeoutSeconds: timeoutSeconds, onlySuccess: onlySuccess);
    }
    try {
      final result = await WorkerIsolatePool.instance.execute('probe', {
        'method': method,
        'url': url,
        'headers': headers,
        if (range != null) 'range': range,
        'timeoutSeconds': timeoutSeconds,
        'onlySuccess': onlySuccess,
      });
      return result as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// Runs the probe directly on the calling thread (test mode). Uses
  /// [host.client] which is the mock client in tests.
  Future<Map<String, dynamic>?> _runProbeDirect(
    String method,
    String url,
    Map<String, String> headers, {
    String? range,
    int timeoutSeconds = 10,
    bool onlySuccess = false,
  }) async {
    final client = host.client;
    try {
      final uri = Uri.parse(url);
      final request = http.Request(method, uri);
      request.headers.addAll(headers);
      if (range != null) request.headers['Range'] = range;
      request.followRedirects = true;
      final streamedResponse = await client
          .send(request)
          .timeout(Duration(seconds: timeoutSeconds));
      final response = await http.Response.fromStream(streamedResponse);
      if (onlySuccess &&
          (response.statusCode < 200 || response.statusCode >= 400)) {
        return null;
      }
      return {
        'statusCode': response.statusCode,
        'contentType': response.headers['content-type'] ?? '',
        'contentLength':
            int.tryParse(response.headers['content-length'] ?? ''),
        'contentRange': response.headers['content-range'] ?? '',
        'headers': Map<String, String>.from(response.headers),
        'bodyBytes': response.bodyBytes,
      };
    } catch (_) {
      return null;
    }
  }
}
