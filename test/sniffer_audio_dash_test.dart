import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/sniffer/dash_playlist_parser.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';

/// Build a minimal MP3 byte stream with an ID3v2 header followed by a
/// single MPEG-1 Layer 3 frame header for 128 kbps, 44.1 kHz, stereo.
Uint8List _buildMp3Bytes128kbpsStereo() {
  final bytes = <int>[];

  // ID3v2.3 header: "ID3"(3) + major(1) + revision(1) + flags(1) + size(4)
  bytes.addAll([0x49, 0x44, 0x33]); // "ID3"
  bytes.add(0x03); // major version
  bytes.add(0x00); // revision
  bytes.add(0x00); // flags
  bytes.addAll([0, 0, 0, 0]); // synchsafe size 0

  // Frame header (4 bytes) for 128 kbps, 44.1 kHz, stereo, MPEG-1 Layer 3.
  // Bits 31-21: 0b11111111111 (sync)        = FF
  // Bit 20-19: 0b11 (MPEG-1)                = E
  // Bits 18-17: 0b01 (Layer 3)              = 4
  // Bit 16: 1 (no CRC)                     = 0
  // Bits 15-12: 0b1001 (bitrate index 9)    = 9 -> 128 kbps
  // Bits 11-10: 0b00 (sample rate 0)        = 0 -> 44100 Hz
  // Bit 9: 0 (no padding)                  = 0
  // Bit 8: 0 (private)                     = 0
  // Bits 7-6: 0b00 (stereo)                = 0
  // Bit 5-4: 0b00 (mode ext + copyright)   = 0
  // Bits 3-0: 0b0000 (original + emphasis)  = 0
  bytes.addAll([0xFF, 0xFB, 0x90, 0x00]);

  // Pad to 256 bytes so the parser's 32KB range request returns the
  // frame header.
  while (bytes.length < 256) {
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

/// Build a FLAC file with a valid STREAMINFO block.
Uint8List _buildFlacStreamInfo({
  required int sampleRate,
  required int channels,
  required int bitsPerSample,
  required int totalSamples,
}) {
  final bytes = <int>[];
  // "fLaC" magic
  bytes.addAll([0x66, 0x4C, 0x61, 0x43]);
  // 1 metadata block header byte: 0 (last), 0 (type = STREAMINFO)
  bytes.add(0x00);
  // 3 bytes length (STREAMINFO is always 34)
  bytes.addAll([0x00, 0x00, 0x22]);

  // STREAMINFO (34 bytes):
  // min block size (2) + max block size (2) + min frame size (3) +
  // max frame size (3) + sample rate (20 bits) + channels (3 bits) +
  // bps (5 bits) + total samples (36 bits) + MD5 (16)
  bytes.addAll([0x00, 0x10]); // min block size 16
  bytes.addAll([0xFF, 0xFF]); // max block size 65535
  bytes.addAll([0x00, 0x00, 0x00]); // min frame size
  bytes.addAll([0x00, 0x00, 0x00]); // max frame size
  // sample rate 20 bits + channels 3 bits + bps 5 bits
  // byte 10: upper 8 bits of sample rate
  // byte 11: next 8 bits of sample rate
  // byte 12: lower 4 bits of sample rate (high nibble) +
  //          channels-1 (3 bits) + bps-1 LSB (1 bit, low nibble)
  // byte 13: bps-1 bits 4..1 (high nibble) + total samples bits 35..32 (low nibble)
  // bytes 14-17: total samples bits 31..0
  final sr20 = sampleRate & 0xFFFFF;
  final ch3 = (channels - 1) & 0x7;
  final bps5 = (bitsPerSample - 1) & 0x1F;
  bytes.add((sr20 >> 12) & 0xFF); // byte 10
  bytes.add((sr20 >> 4) & 0xFF); // byte 11
  bytes.add(((sr20 & 0x0F) << 4) | (ch3 << 1) | (bps5 & 0x01)); // byte 12
  bytes.add(((bps5 >> 1) << 4) | ((totalSamples >> 32) & 0x0F)); // byte 13
  // total samples bits 31..0
  bytes.add((totalSamples >> 24) & 0xFF);
  bytes.add((totalSamples >> 16) & 0xFF);
  bytes.add((totalSamples >> 8) & 0xFF);
  bytes.add(totalSamples & 0xFF);
  // 16 bytes of MD5 zeros
  for (var i = 0; i < 16; i++) {
    bytes.add(0);
  }
  // Pad
  while (bytes.length < 256) {
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

/// Build a minimal OGG stream with a single Vorbis identification header.
Uint8List _buildOggVorbisHeader({
  required int sampleRate,
  required int channels,
  required int nominalBitrateBps,
}) {
  final bytes = <int>[];

  // OGG page header
  bytes.addAll([0x4F, 0x67, 0x67, 0x53]); // "OggS"
  bytes.add(0x00); // stream structure version 0
  bytes.add(0x00); // header type flags
  // granule position (8 bytes) — 0 for first page
  for (var i = 0; i < 8; i++) {
    bytes.add(0);
  }
  // serial number (4)
  bytes.addAll([0x00, 0x00, 0x00, 0x01]);
  // page sequence number (4)
  bytes.addAll([0x00, 0x00, 0x00, 0x00]);
  // checksum (4) — leave as zero (valid enough for our parser)
  bytes.addAll([0x00, 0x00, 0x00, 0x00]);
  // number of segments
  bytes.add(0x01);
  // segment table: one segment of 30 bytes
  bytes.add(30);

  // Vorbis identification packet (30 bytes)
  bytes.add(0x01); // packet type 1
  bytes.addAll('vorbis'.codeUnits);
  bytes.addAll([0x00, 0x00, 0x00, 0x00]); // version
  bytes.add(channels);
  // sample rate (4 bytes little-endian)
  bytes.add((sampleRate) & 0xFF);
  bytes.add((sampleRate >> 8) & 0xFF);
  bytes.add((sampleRate >> 16) & 0xFF);
  bytes.add((sampleRate >> 24) & 0xFF);
  // max bitrate
  bytes.addAll([0x00, 0x00, 0x00, 0x00]);
  // nominal bitrate
  bytes.add(nominalBitrateBps & 0xFF);
  bytes.add((nominalBitrateBps >> 8) & 0xFF);
  bytes.add((nominalBitrateBps >> 16) & 0xFF);
  bytes.add((nominalBitrateBps >> 24) & 0xFF);
  // min bitrate
  bytes.addAll([0x00, 0x00, 0x00, 0x00]);
  // blocksize_0 (4 bits) | blocksize_1 (4 bits) = 8 | 8 -> 0x88
  bytes.add(0x88);
  // framing flag
  bytes.add(0x01);

  // Pad
  while (bytes.length < 256) {
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

/// Build a minimal ISO BMFF (M4A) stream with a `moov` containing
/// `mvhd` (duration 10s at 1000 Hz timescale) and a single `trak`
/// with `mdhd` (timescale 48000), `mp4a` (channels=2, sample rate=48000).
Uint8List _buildM4ABytes() {
  // For brevity, hand-craft a small valid-ish stream: a `ftyp` box, then
  // a `moov` box that contains a `mvhd` and a `trak` with the audio
  // atoms we need. The exact box sizes matter for production files,
  // but the sniffer's MP4 scan only looks for the 4-byte type sigs, so
  // we keep things simple.
  final result = <int>[];

  void writeU32(List<int> out, int value) {
    out.add((value >> 24) & 0xFF);
    out.add((value >> 16) & 0xFF);
    out.add((value >> 8) & 0xFF);
    out.add(value & 0xFF);
  }

  void writeU16(List<int> out, int value) {
    out.add((value >> 8) & 0xFF);
    out.add(value & 0xFF);
  }

  void writeBox(List<int> out, String type, List<int> body) {
    writeU32(out, 8 + body.length);
    out.addAll(type.codeUnits);
    out.addAll(body);
  }

  // ftyp box
  writeBox(result, 'ftyp', [
    ...'isom'.codeUnits,
    0x00, 0x00, 0x00, 0x00, // minor version
    ...'isom'.codeUnits,
  ]);

  // moov content
  final moov = <int>[];

  // mvhd v0: timescale=1000, duration=10000 (10s)
  final mvhd = <int>[];
  mvhd.add(0); // version
  mvhd.addAll([0, 0, 0]); // flags
  writeU32(mvhd, 0); // creation
  writeU32(mvhd, 0); // modification
  writeU32(mvhd, 1000); // timescale
  writeU32(mvhd, 10000); // duration
  writeU32(mvhd, 0x00010000); // rate
  writeU16(mvhd, 0x0100); // volume
  mvhd.addAll(List.filled(10, 0)); // reserved
  // matrix 36 bytes (identity)
  mvhd.addAll(List.filled(36, 0));
  // pre_defined 24 bytes
  mvhd.addAll(List.filled(24, 0));
  writeU32(mvhd, 2); // next track id
  writeBox(moov, 'mvhd', mvhd);

  // trak content
  final trak = <int>[];

  // mdhd v0: timescale=48000, duration=480000
  final mdhd = <int>[];
  mdhd.add(0); // version
  mdhd.addAll([0, 0, 0]); // flags
  writeU32(mdhd, 0); // creation
  writeU32(mdhd, 0); // modification
  writeU32(mdhd, 48000); // timescale
  writeU32(mdhd, 480000); // duration
  writeU16(mdhd, 0x55C4); // language (und)
  writeU16(mdhd, 0); // pre_defined
  writeBox(trak, 'mdhd', mdhd);

  // mp4a box — audio sample entry
  final mp4a = <int>[];
  // 6 reserved bytes
  mp4a.addAll([0, 0, 0, 0, 0, 0]);
  writeU16(mp4a, 1); // data_ref_index
  // 8 reserved bytes
  mp4a.addAll([0, 0, 0, 0, 0, 0, 0, 0]);
  writeU16(mp4a, 2); // channel_count
  writeU16(mp4a, 16); // sample_size
  writeU16(mp4a, 0); // compression_id
  writeU16(mp4a, 0); // packet_size
  // sample rate as 16.16 fixed point
  mp4a.add((48000 >> 8) & 0xFF);
  mp4a.add(48000 & 0xFF);
  mp4a.add(0);
  mp4a.add(0);
  writeBox(trak, 'mp4a', mp4a);

  writeBox(moov, 'trak', trak);
  writeBox(result, 'moov', moov);

  // Pad to 256 bytes so the parser's 32KB range request returns the
  // full byte stream.
  while (result.length < 256) {
    result.add(0);
  }
  return Uint8List.fromList(result);
}

void main() {
  setUp(() {
    MediaSnifferEngine.clearGlobalCache();
  });

  group('containerFormatForExtension', () {
    test('mp4 extensions map to mp4', () {
      expect(MediaSnifferEngine.containerFormatForExtension('.mp4'), 'mp4');
      expect(MediaSnifferEngine.containerFormatForExtension('.m4v'), 'mp4');
      expect(MediaSnifferEngine.containerFormatForExtension('.m4a'), 'mp4');
    });

    test('other common formats map correctly', () {
      expect(MediaSnifferEngine.containerFormatForExtension('.webm'), 'webm');
      expect(MediaSnifferEngine.containerFormatForExtension('.mkv'), 'matroska');
      expect(MediaSnifferEngine.containerFormatForExtension('.mp3'), 'mp3');
      expect(MediaSnifferEngine.containerFormatForExtension('.flac'), 'flac');
      expect(MediaSnifferEngine.containerFormatForExtension('.ogg'), 'ogg');
      expect(MediaSnifferEngine.containerFormatForExtension('.ts'), 'mpeg-ts');
      expect(MediaSnifferEngine.containerFormatForExtension('.avi'), 'avi');
      expect(MediaSnifferEngine.containerFormatForExtension('.mov'), 'quicktime');
    });

    test('unknown extensions return null', () {
      expect(MediaSnifferEngine.containerFormatForExtension('.zip'), isNull);
      expect(MediaSnifferEngine.containerFormatForExtension('.exe'), isNull);
      expect(MediaSnifferEngine.containerFormatForExtension(''), isNull);
    });
  });

  group('sniff() sets containerFormat', () {
    test('mp4 URL gets containerFormat=mp4', () {
      final client = http.Client();
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);
      engine.sniff('https://example.com/movie.mp4');
      expect(engine.detectedMedia.length, 1);
      expect(engine.detectedMedia.first.containerFormat, 'mp4');
    });

    test('flac URL gets containerFormat=flac', () {
      final client = http.Client();
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);
      engine.sniff('https://example.com/song.flac');
      expect(engine.detectedMedia.first.containerFormat, 'flac');
    });

    test('mpd URL gets containerFormat=null (no extension match)', () {
      final client = http.Client();
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);
      engine.sniff('https://example.com/manifest.mpd');
      // .mpd is intentionally not in the map; the enricher sets the
      // DASH-specific container label after parsing.
      expect(engine.detectedMedia.first.containerFormat, isNull);
    });
  });

  group('MP3 audio probe', () {
    test('MP3 frame header yields sample rate, channels, and duration',
        () async {
      final mp3Bytes = _buildMp3Bytes128kbpsStereo();
      final mp3Length = 5 * 1024 * 1024; // 5 MB at 128 kbps = ~5 minutes
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {
              'content-length': mp3Length.toString(),
              'content-type': 'audio/mpeg',
            },
          );
        }
        return http.Response.bytes(
          mp3Bytes,
          206,
          headers: {
            'content-range': 'bytes 0-${mp3Bytes.length - 1}/$mp3Length',
            'content-type': 'audio/mpeg',
          },
        );
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.type == MediaType.audio && item.sampleRate != null,
      );

      engine.sniff('https://example.com/song.mp3');

      final enriched = await enrichedFuture;
      expect(enriched.sampleRate, 44100);
      expect(enriched.channels, 2);
      expect(enriched.audioCodec, 'mp3');
      expect(enriched.containerFormat, 'mp3');
      // 5 MB at 128 kbps ≈ 327.68 s
      expect(
        enriched.duration!.inSeconds,
        inInclusiveRange(325, 330),
      );
    });
  });

  group('FLAC audio probe', () {
    test('FLAC STREAMINFO yields sample rate, channels, and duration',
        () async {
      final flacBytes = _buildFlacStreamInfo(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
        totalSamples: 48000 * 30, // 30 seconds
      );
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {
              'content-length': '${flacBytes.length * 100}',
              'content-type': 'audio/flac',
            },
          );
        }
        return http.Response.bytes(
          flacBytes,
          206,
          headers: {
            'content-range': 'bytes 0-${flacBytes.length - 1}/${flacBytes.length * 100}',
            'content-type': 'audio/flac',
          },
        );
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.type == MediaType.audio && item.audioCodec == 'flac',
      );

      engine.sniff('https://example.com/track.flac');

      final enriched = await enrichedFuture;
      expect(enriched.sampleRate, 48000);
      expect(enriched.channels, 2);
      expect(enriched.containerFormat, 'flac');
      expect(enriched.duration, const Duration(seconds: 30));
    });
  });

  group('OGG Vorbis audio probe', () {
    test('OGG Vorbis header yields sample rate, channels', () async {
      final oggBytes = _buildOggVorbisHeader(
        sampleRate: 44100,
        channels: 2,
        nominalBitrateBps: 128000,
      );
      final flacLength = 5 * 1024 * 1024; // 5 MB
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {
              'content-length': flacLength.toString(),
              'content-type': 'audio/ogg',
            },
          );
        }
        return http.Response.bytes(
          oggBytes,
          206,
          headers: {
            'content-range': 'bytes 0-${oggBytes.length - 1}/$flacLength',
            'content-type': 'audio/ogg',
          },
        );
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.type == MediaType.audio && item.audioCodec == 'vorbis',
      );

      engine.sniff('https://example.com/track.ogg');

      final enriched = await enrichedFuture;
      expect(enriched.sampleRate, 44100);
      expect(enriched.channels, 2);
      expect(enriched.audioCodec, 'vorbis');
      expect(enriched.containerFormat, 'ogg');
    });
  });

  group('M4A audio probe', () {
    test('M4A mp4a atom yields sample rate, channels, and duration',
        () async {
      final m4aBytes = _buildM4ABytes();
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {
              'content-length': '${m4aBytes.length * 100}',
              'content-type': 'audio/mp4',
            },
          );
        }
        return http.Response.bytes(
          m4aBytes,
          206,
          headers: {
            'content-range': 'bytes 0-${m4aBytes.length - 1}/${m4aBytes.length * 100}',
            'content-type': 'audio/mp4',
          },
        );
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.type == MediaType.audio && item.sampleRate == 48000,
      );

      engine.sniff('https://example.com/song.m4a');

      final enriched = await enrichedFuture;
      expect(enriched.channels, 2);
      expect(enriched.audioCodec, 'aac');
      expect(enriched.containerFormat, 'mp4');
      expect(enriched.duration, const Duration(seconds: 10));
    });
  });

  group('DashPlaylistParser', () {
    test('parses multi-variant MPD with bandwidth, dimensions, codecs',
        () {
      const body = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1M30S" minBufferTime="PT2S">
  <Period duration="PT1M30S">
    <AdaptationSet contentType="video" mimeType="video/mp4" minWidth="640" maxWidth="1920" minHeight="360" maxHeight="1080">
      <Representation id="v1080" bandwidth="5000000" width="1920" height="1080" frameRate="30" codecs="avc1.640028">
        <SegmentTemplate media="video/1080/seg-\$Number\$.m4s" initialization="video/1080/init.mp4" timescale="90000" duration="90000" startNumber="1"/>
      </Representation>
      <Representation id="v720" bandwidth="2500000" width="1280" height="720" frameRate="30000/1001" codecs="avc1.4d401f">
        <SegmentTemplate media="video/720/seg-\$Number\$.m4s" initialization="video/720/init.mp4" timescale="90000" duration="90000" startNumber="1"/>
      </Representation>
    </AdaptationSet>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation id="a1" bandwidth="128000" audioSamplingRate="48000" codecs="mp4a.40.2">
        <SegmentTemplate media="audio/seg-\$Number\$.m4s" initialization="audio/init.mp4" timescale="48000" duration="48000"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';
      final uri = Uri.parse('https://example.com/manifest.mpd');
      final playlist = DashPlaylistParser.parse(body, uri);
      expect(playlist.mpdType, 'static');
      expect(playlist.isLive, isFalse);
      expect(playlist.durationSeconds, 90.0);
      expect(playlist.representations.length, 3);

      final v1080 = playlist.representations
          .firstWhere((r) => r.id == 'v1080');
      expect(v1080.bandwidth, 5000000);
      expect(v1080.width, 1920);
      expect(v1080.height, 1080);
      expect(v1080.frameRate, 30.0);
      expect(v1080.codecs, 'avc1.640028');
      expect(v1080.isVideo, isTrue);

      final v720 = playlist.representations
          .firstWhere((r) => r.id == 'v720');
      // 30000/1001 ≈ 29.97
      expect(v720.frameRate!, closeTo(29.97, 0.01));
      expect(v720.isVideo, isTrue);

      final audio = playlist.representations
          .firstWhere((r) => r.id == 'a1');
      expect(audio.audioSamplingRate, 48000);
      expect(audio.isAudio, isTrue);
      expect(audio.isVideo, isFalse);
    });

    test('parses dynamic (live) MPD', () {
      const body = '''<?xml version="1.0"?>
<MPD type="dynamic" mediaPresentationDuration="PT0H0M0S">
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="v1" bandwidth="1000000" width="640" height="360">
        <SegmentTemplate media="v/seg-\$Number\$.m4s" initialization="v/init.mp4"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';
      final playlist = DashPlaylistParser.parse(
        body,
        Uri.parse('https://example.com/live.mpd'),
      );
      expect(playlist.isLive, isTrue);
      expect(playlist.representations.length, 1);
      expect(playlist.representations.first.width, 640);
    });

    test('handles non-MPD body gracefully', () {
      final playlist = DashPlaylistParser.parse(
        'not xml',
        Uri.parse('https://example.com/bad.mpd'),
      );
      expect(playlist.representations, isEmpty);
    });
  });

  group('DASH MPD enrichment', () {
    test('multi-variant MPD creates one SniffedMedia per Representation',
        () async {
      const mpdBody = '''<?xml version="1.0"?>
<MPD type="static" mediaPresentationDuration="PT30S">
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="v1080" bandwidth="4000000" width="1920" height="1080" codecs="avc1.640028">
        <SegmentTemplate media="v1080/seg-\$Number\$.m4s" initialization="v1080/init.mp4" timescale="90000" duration="90000"/>
      </Representation>
      <Representation id="v720" bandwidth="2000000" width="1280" height="720" codecs="avc1.4d401f">
        <SegmentTemplate media="v720/seg-\$Number\$.m4s" initialization="v720/init.mp4" timescale="90000" duration="90000"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {
              'content-length': '${mpdBody.length}',
              'content-type': 'application/dash+xml',
            },
          );
        }
        return http.Response(mpdBody, 200);
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final variantFuture = engine.onMediaChanged.firstWhere(
        (item) => item.bandwidth == 4000000,
      );

      engine.sniff('https://example.com/manifest.mpd');

      final variant = await variantFuture;
      expect(variant.width, 1920);
      expect(variant.height, 1080);
      expect(variant.bandwidth, 4000000);
      expect(variant.videoCodec, 'avc1.640028');
      // 4 Mbps * 30s / 8 = 15 MB
      expect(variant.contentLengthBytes, 15000000);
      expect(variant.isSizeEstimated, isTrue);
    });
  });
}
