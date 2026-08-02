import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';

/// Decodes one frame of the video at [url]. Returns null when no frame could be
/// read, which is an ordinary outcome rather than an error.
typedef FrameDecoder = Future<Uint8List?> Function(
  String url, {
  required Map<String, String> headers,
  required int maxWidth,
});

const MethodChannel _channel =
    MethodChannel('aurora_downloader/media_thumbnail');

Future<Uint8List?> _platformDecode(
  String url, {
  required Map<String, String> headers,
  required int maxWidth,
}) async {
  try {
    return await _channel.invokeMethod<Uint8List>('frameAt', {
      'url': url,
      'headers': headers,
      'maxWidth': maxWidth,
    });
  } on MissingPluginException {
    // iOS, desktop, or a test binding with no platform behind it. Callers fall
    // back to the scraped poster and then the type icon.
    return null;
  } on PlatformException {
    return null;
  }
}

/// Real frames for capture rows, decoded out of the remote stream.
///
/// Every other thumbnail source in the sniffer is artwork *scraped from the
/// page* — a `<video poster>` attribute, a nearby `<img>`, the page's
/// `og:image`. All three only cover pages that happen to publish an image, and
/// none of them is a frame of the file being downloaded. This decodes the file
/// itself, so a row can show its own content.
///
/// Three bounds keep that affordable: an LRU of decoded bytes, a cap on
/// in-flight decodes, and a permanent record of URLs that already failed. The
/// last one matters most — a CDN that refuses range requests refuses them every
/// time, and retrying on each rebuild would spend the battery for nothing.
class CaptureFrameCache {
  CaptureFrameCache({
    FrameDecoder? decoder,
    this.maxEntries = 64,
    this.maxConcurrent = 2,
    this.maxWidth = 320,
  }) : _decode = decoder ?? _platformDecode;

  /// Shared by every capture sheet, so scrolling away and back is free.
  static final CaptureFrameCache instance = CaptureFrameCache();

  final FrameDecoder _decode;

  /// Decoded frames retained before the least recently used is dropped.
  final int maxEntries;

  /// Decodes allowed to run at once. Each is a network read plus a hardware
  /// decode, so an unbounded fan-out would stall the scroll it is serving.
  final int maxConcurrent;

  /// Longest edge requested from the platform. The slot paints at 84dp.
  final int maxWidth;

  /// Insertion-ordered, so the first key is the least recently used.
  final LinkedHashMap<String, Uint8List> _frames =
      LinkedHashMap<String, Uint8List>();

  /// URLs with no frame to give. Bounded only because a long session on a
  /// hostile site could otherwise grow it without limit.
  final LinkedHashMap<String, bool> _failed = LinkedHashMap<String, bool>();

  /// One future per URL, so N rows asking at once produce one decode.
  final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};

  final List<Completer<void>> _waiting = <Completer<void>>[];
  int _active = 0;

  @visibleForTesting
  int get activeDecodes => _active;

  @visibleForTesting
  int get cachedCount => _frames.length;

  /// A frame already decoded for [url], or null. Safe to call from `build`.
  Uint8List? cached(String url) {
    final hit = _frames.remove(url);
    if (hit == null) return null;
    // Re-inserting moves it to the young end of the LRU.
    _frames[url] = hit;
    return hit;
  }

  /// True when [url] has been tried and has no frame to offer.
  bool hasFailed(String url) => _failed.containsKey(url);

  /// True when [item] is worth attempting at all.
  ///
  /// Only video: an audio file's embedded cover art would be a different
  /// retriever call, and a `blob:` URL was never a real stream in the first
  /// place, so there is nothing on the other side to decode.
  static bool canDecode(SniffedMedia item) {
    if (item.type != MediaType.video) return false;
    final uri = Uri.tryParse(item.url);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  /// Headers to replay when reading the stream.
  ///
  /// These links come out of a browsing session and most CDNs check the
  /// referer, so sending none of them means a 403 and no frame. Note that
  /// [SniffedMedia.headers] has already had `Cookie` and `Authorization`
  /// stripped by [sanitizeSniffedMediaHeaders] — a stream gated on the session
  /// cookie will therefore fail here and keep its type icon.
  @visibleForTesting
  static Map<String, String> headersFor(SniffedMedia item) {
    final out = Map<String, String>.from(item.headers);
    final page = item.sourcePageUrl?.trim();
    if (page != null &&
        page.isNotEmpty &&
        !out.keys.any((k) => k.toLowerCase() == 'referer')) {
      out['Referer'] = page;
    }
    return out;
  }

  /// Decodes a frame for [item], or returns null when there is none to be had.
  ///
  /// Coalesces concurrent callers, serves the LRU on a repeat, and never
  /// re-attempts a URL that already failed.
  Future<Uint8List?> frameFor(SniffedMedia item) {
    final url = item.url;
    final hit = cached(url);
    if (hit != null) return Future<Uint8List?>.value(hit);
    if (_failed.containsKey(url)) return Future<Uint8List?>.value(null);
    if (!canDecode(item)) return Future<Uint8List?>.value(null);

    final existing = _inFlight[url];
    if (existing != null) return existing;

    final future = _run(url, headersFor(item));
    _inFlight[url] = future;
    return future;
  }

  Future<Uint8List?> _run(String url, Map<String, String> headers) async {
    await _acquire();
    try {
      final bytes = await _decode(url, headers: headers, maxWidth: maxWidth);
      if (bytes == null || bytes.isEmpty) {
        _remember(_failed, url, true);
        return null;
      }
      _frames[url] = bytes;
      while (_frames.length > maxEntries) {
        _frames.remove(_frames.keys.first);
      }
      return bytes;
    } catch (_) {
      // A decoder that throws is a decoder that has no frame. Same outcome.
      _remember(_failed, url, true);
      return null;
    } finally {
      _inFlight.remove(url);
      _release();
    }
  }

  void _remember(LinkedHashMap<String, bool> into, String key, bool value) {
    into[key] = value;
    while (into.length > maxEntries * 4) {
      into.remove(into.keys.first);
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final gate = Completer<void>();
    _waiting.add(gate);
    return gate.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      // Hand the slot straight to the next waiter rather than dropping the
      // count, so a burst of rows cannot all wake at once and overshoot.
      _waiting.removeAt(0).complete();
      return;
    }
    _active--;
  }

  @visibleForTesting
  void reset() {
    _frames.clear();
    _failed.clear();
    _inFlight.clear();
    _waiting.clear();
    _active = 0;
  }
}
