import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Pure binary-parsing helpers extracted from media_enricher.dart.
// These are top-level functions usable from the worker isolate without any
// dependency on the rest of the enrichment pipeline.
// ---------------------------------------------------------------------------

/// Result of parsing an MPEG audio frame header.
class Mp3FrameInfo {
  final int bitrateKbps;
  final int sampleRate;
  final int channels;
  const Mp3FrameInfo({
    required this.bitrateKbps,
    required this.sampleRate,
    required this.channels,
  });
}

/// Result of the lightweight MP4 audio-atom scan.
class Mp4AudioInfo {
  final String? codec;
  final int? sampleRate;
  final int? channels;
  final Duration? duration;
  const Mp4AudioInfo({
    this.codec,
    this.sampleRate,
    this.channels,
    this.duration,
  });
}

/// Returns true if [b] starting at [offset] contains the ASCII bytes of
/// [ascii] (case-sensitive, length must match).
bool startsWithAscii(List<int> b, int offset, String ascii) {
  if (offset < 0 || offset + ascii.length > b.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (b[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

/// Parses a 4-byte MPEG audio frame header to extract bitrate, sample
/// rate, and channel count. Returns null when the header is reserved or
/// otherwise invalid.
Mp3FrameInfo? parseMp3FrameHeader(int header) {
  if ((header & 0xFFE00000) != 0xFFE00000) return null;

  final versionBits = (header >> 19) & 0x03;
  final layerBits = (header >> 17) & 0x03;
  if (versionBits == 1 || layerBits == 0) return null;

  final bitrateIdx = (header >> 12) & 0x0F;
  final sampleRateIdx = (header >> 10) & 0x03;
  final channelMode = (header >> 6) & 0x03;
  final channels = channelMode == 3 ? 1 : 2;

  // clang-format off
  const bitrateTable = <List<List<int>>>[
    [ // v2.5
      [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160,0],
      [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160,0],
      [0,32,48,56,64,80,96,112,128,144,160,176,192,224,256,0],
    ],
    [ // reserved
      [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
    ],
    [ // v2
      [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160,0],
      [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160,0],
      [0,32,48,56,64,80,96,112,128,144,160,176,192,224,256,0],
    ],
    [ // v1
      [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320,0],
      [0,32,48,56,64,80,96,112,128,160,192,224,256,320,384,0],
      [0,32,64,96,128,160,192,224,256,288,320,352,384,416,448,0],
    ],
  ];
  // clang-format on
  final bitrateKbps = bitrateTable[versionBits][layerBits][bitrateIdx];

  const sampleRateTable = <List<int>>[
    [11025, 12000, 8000, 0], // v2.5
    [0, 0, 0, 0], // reserved
    [22050, 24000, 16000, 0], // v2
    [44100, 48000, 32000, 0], // v1
  ];
  final sampleRate = sampleRateTable[versionBits][sampleRateIdx];

  if (bitrateKbps <= 0 || sampleRate <= 0) return null;
  return Mp3FrameInfo(
    bitrateKbps: bitrateKbps,
    sampleRate: sampleRate,
    channels: channels,
  );
}

/// Scans the leading bytes of an MP4/ISO BMFF stream for audio-specific
/// atoms: `mvhd` (movie duration), `mdhd` (track timescale), and `mp4a`
/// (channel count + sample rate).
Mp4AudioInfo? parseMp4AudioAtoms(List<int> b) {
  int? movieTimescale;
  int? movieDuration;
  int? mdhdTimescale;
  int? mp4aSampleRate;
  int? mp4aChannels;
  bool foundMp4a = false;

  for (var i = 0; i < b.length - 40; i++) {
    // mvhd
    if (b[i] == 0x6D &&
        b[i + 1] == 0x76 &&
        b[i + 2] == 0x68 &&
        b[i + 3] == 0x64) {
      final ver = b[i + 4];
      if (ver == 1) {
        if (i + 36 <= b.length) {
          movieTimescale = (b[i + 24] << 24) |
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
          movieTimescale = (b[i + 16] << 24) |
              (b[i + 17] << 16) |
              (b[i + 18] << 8) |
              b[i + 19];
          movieDuration = (b[i + 20] << 24) |
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
        mdhdTimescale = (b[tsOff] << 24) |
            (b[tsOff + 1] << 16) |
            (b[tsOff + 2] << 8) |
            b[tsOff + 3];
      }
    }
    // mp4a
    if (b[i] == 0x6D &&
        b[i + 1] == 0x70 &&
        b[i + 2] == 0x34 &&
        b[i + 3] == 0x61) {
      if (i + 32 <= b.length) {
        mp4aChannels = (b[i + 20] << 8) | b[i + 21];
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

  if (!foundMp4a && mdhdTimescale == null && movieDuration == null) {
    return null;
  }

  return Mp4AudioInfo(
    codec: foundMp4a ? 'aac' : null,
    sampleRate: mp4aSampleRate,
    channels: mp4aChannels,
    duration: dur,
  );
}

/// Parse image dimensions (JPEG/PNG/GIF/WEBP) from raw bytes.
/// Returns `{width, height}` or null.
Map<String, int>? parseImageDimensions(Uint8List bytes) {
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
}

/// Parse audio binary headers (MP3/ID3v2, FLAC, OGG Vorbis, M4A/mp4a).
/// Returns a map with keys: codec, container, sampleRate, channels,
/// durationMs — any may be null.
Map<String, dynamic>? parseAudioHeaders(Uint8List b) {
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
    final mp3Parsed = parseMp3FrameHeader(mp3Header);
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
            startsWithAscii(b, payloadStart + 1, 'vorbis')) {
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
    final audioMp4 = parseMp4AudioAtoms(b);
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
}

/// Parse MP4 atoms (tkhd, mvhd, mdhd, stts) to extract video dimensions,
/// framerate, duration, and codec hints.
/// Returns a map with keys: width, height, videoCodec, audioCodec, frameRate,
/// durationMs — any may be null.
Map<String, dynamic>? parseVideoMp4Atoms(Uint8List b) {
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
}
