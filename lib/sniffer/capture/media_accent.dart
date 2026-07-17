import 'package:flutter/material.dart';

import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_tokens.dart';

/// True when the media looks like an HLS stream (URL or content-type).
bool isHlsMedia(SniffedMedia m) {
  return m.url.contains('.m3u8') ||
      (m.contentType?.contains('m3u8') ?? false) ||
      (m.contentType?.contains('apple/mpegurl') ?? false);
}

/// Theme-aware accent color for a sniffed media item.
///
/// HLS always wins over [MediaType]. Torrent maps to [AColors.mediaOther]
/// until a dedicated `mediaTorrent` token lands (PR2).
Color mediaAccentFor(AColors ac, SniffedMedia item, {required bool isHls}) {
  if (isHls) return ac.mediaHls;
  return switch (item.type) {
    MediaType.video => ac.mediaVideo,
    MediaType.audio => ac.mediaAudio,
    MediaType.image => ac.mediaImage,
    // PR1: mediaTorrent does not exist yet — use mediaOther (not amber).
    // PR2: change this arm to ac.mediaTorrent only.
    MediaType.torrent => ac.mediaOther,
    _ => ac.mediaOther,
  };
}
