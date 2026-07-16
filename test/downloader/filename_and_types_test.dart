import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/downloader/file_classifier.dart';
import 'package:aurora_downloader/downloader/filename_service.dart';
import 'package:aurora_downloader/downloader/media_file_types.dart';

void main() {
  group('MediaFileTypes', () {
    test('extensionOf from path and URL', () {
      expect(MediaFileTypes.extensionOf('/a/b/video.mp4'), '.mp4');
      expect(
        MediaFileTypes.extensionOf('https://cdn.example.com/x.m3u8?t=1'),
        '.m3u8',
      );
      expect(MediaFileTypes.extensionOf('noext'), null);
    });

    test('mime and reverse maps stay in sync for common types', () {
      expect(MediaFileTypes.mimeTypeForName('a.mp4'), 'video/mp4');
      expect(MediaFileTypes.extensionForMime('video/mp4'), '.mp4');
      expect(MediaFileTypes.mimeTypeForName('a.srt'), 'application/x-subrip');
      expect(MediaFileTypes.extensionForMime('image/webp'), '.webp');
    });

    test('folderLabelForPath honors custom mappings', () {
      expect(
        MediaFileTypes.folderLabelForPath(
          'clip.mp4',
          customFolderMappings: {'.mp4': 'Movies'},
        ),
        'Movies',
      );
      expect(
        MediaFileTypes.folderLabelForPath(
          'clip.mp4',
          customFolderMappings: {'mp4': 'Films'},
        ),
        'Films',
      );
      expect(
        MediaFileTypes.folderLabelForPath('song.mp3'),
        'Audio',
      );
    });

    test('FileClassifier delegates to MediaFileTypes', () {
      expect(FileClassifier.classify('a.mp4'), FileCategory.videos);
      expect(FileClassifier.classify('a.unknownext'), FileCategory.other);
      expect(
        FileClassifier.folderLabelFor(
          'a.mkv',
          customMappings: {'.mkv': 'Cinema'},
        ),
        'Cinema',
      );
    });
  });

  group('FilenameService', () {
    test('truncate preserves extension at the end (UTF-8 budget)', () {
      final long = '${'a' * 200}.mp4';
      final t = FilenameService.truncate(long, maxBytes: 40);
      expect(t.endsWith('.mp4'), isTrue);
      expect(FilenameService.utf8ByteLength(t), lessThanOrEqualTo(40));
    });

    test('truncate never plants extension mid-name at a fixed column', () {
      final base =
          'LULU-172 Because I was trying to get pregnant, my daughter-in-law '
          'played me to refrain from masturbation, and I lost my reason on '
          'the verge of exploding my balls with sperm, and I made my '
          'deca-ass mother-in-law get pregnant and cummed all the juice I '
          'could. Sumire Kurokawa';
      final full = '$base.mp4';
      final t = FilenameService.truncate(
        full,
        maxBytes: FilenameService.defaultMaxFileNameBytes,
      );
      expect(t.endsWith('.mp4'), isTrue);
      expect(t.contains('.mp4'), isTrue);
      // Extension only once, at the end.
      expect(t.indexOf('.mp4'), t.lastIndexOf('.mp4'));
      expect(t.lastIndexOf('.mp4'), t.length - 4);
      expect(
        FilenameService.utf8ByteLength(t),
        lessThanOrEqualTo(FilenameService.defaultMaxFileNameBytes),
      );
      // Starts with the product code from the title, not a URL slug.
      expect(t.startsWith('LULU-172'), isTrue);
    });

    test('isUnusableTitle rejects error and chrome titles', () {
      expect(FilenameService.isUnusableTitle('Just a moment...'), isTrue);
      expect(FilenameService.isUnusableTitle('Cloudflare'), isTrue);
      expect(FilenameService.isUnusableTitle('Watch Free'), isTrue);
      expect(FilenameService.isUnusableTitle('FC2-PPV-4912494'), isFalse);
    });

    test('qualityLabelFrom uses height and bandwidth ladders', () {
      expect(FilenameService.qualityLabelFrom(height: 1080), '1080');
      expect(FilenameService.qualityLabelFrom(height: 720), '720');
      expect(
        FilenameService.qualityLabelFrom(
          url: 'https://cdn.example.com/master_480p.m3u8',
        ),
        '480',
      );
      expect(
        FilenameService.qualityLabelFrom(bandwidth: 5000000),
        '720',
      );
    });

    test('buildSuggestedFilename prefers page title and quality', () {
      final name = FilenameService.buildSuggestedFilename(
        mediaName: 'master.m3u8',
        mediaUrl: 'https://cdn.example.com/720p/index.m3u8',
        pageTitle: 'Cool Video Title',
        includeQualitySuffix: true,
        defaultMp4ForVideoHosts: true,
      );
      expect(name, contains('Cool Video Title'));
      expect(name, contains('(720p)'));
      expect(name.toLowerCase().endsWith('.m3u8'), isFalse);
      // Quality sits immediately before the extension.
      expect(name.endsWith('(720p).mp4'), isTrue);
    });

    test('buildSuggestedFilename uses MissAV-style full title not URL slug', () {
      // Captured via Playwright headless from missav.ws/en/lulu-172-uncensored-leak
      const fullTitle =
          'LULU-172 Because I was trying to get pregnant, my daughter-in-law '
          'played me to refrain from masturbation, and I lost my reason on '
          'the verge of exploding my balls with sperm, and I made my '
          'deca-ass mother-in-law get pregnant and cummed all the juice I '
          'could. Sumire Kurokawa';
      const truncatedDocTitle =
          'LULU-172 Because I was trying to get pregnant, my daugh';
      // pickBestTitle must prefer full og/h1 over truncated document.title
      final best = FilenameService.pickBestTitle([
        truncatedDocTitle,
        fullTitle,
      ]);
      expect(best, fullTitle);

      final name = FilenameService.buildSuggestedFilename(
        mediaName: 'index.m3u8',
        mediaUrl: 'https://surrit.com/abc/480p/video.m3u8',
        pageTitle: best,
        sourcePageUrl: 'https://missav.ws/en/lulu-172-uncensored-leak',
        includeQualitySuffix: true,
        defaultMp4ForVideoHosts: true,
      );
      expect(name.startsWith('LULU-172'), isTrue);
      expect(name, isNot(contains('lulu-172-uncensored-leak')));
      expect(name.endsWith('.mp4'), isTrue);
      // Full title is long; either actress name still fits or was truncated.
      expect(
        name.contains('Sumire') || name.contains('Because'),
        isTrue,
      );
      // Not the old slug_quality form.
      expect(name, isNot(matches(RegExp(r'lulu-172-uncensored-leak_480p'))));
      expect(
        FilenameService.utf8ByteLength(name),
        lessThanOrEqualTo(FilenameService.defaultMaxFileNameBytes),
      );
    });

    test('buildSuggestedFilename falls back to source path id', () {
      final name = FilenameService.buildSuggestedFilename(
        mediaName: 'index.m3u8',
        pageTitle: 'Just a moment...',
        sourcePageUrl: 'https://missav.ws/en/fc2-ppv-4912494',
        includeQualitySuffix: false,
        defaultMp4ForVideoHosts: true,
      );
      expect(name, contains('fc2-ppv-4912494'));
    });

    test('composeFileName drops quality first when title is long', () {
      final base = 'Word ' * 80; // very long descriptive title
      final withQ = FilenameService.composeFileName(
        baseName: base,
        extension: '.mp4',
        qualityLabel: '480',
        includeQualitySuffix: true,
        maxBytes: 80,
      );
      expect(withQ.endsWith('.mp4'), isTrue);
      // Quality dropped so more of the title can fit.
      expect(withQ.contains('(480p)'), isFalse);
      expect(FilenameService.utf8ByteLength(withQ), lessThanOrEqualTo(80));
    });

    test('cleanTitle strips short site brand suffixes', () {
      expect(
        FilenameService.cleanTitle('Cool Clip | ExampleSite'),
        'Cool Clip',
      );
    });

    test('uniqueFileName adds numeric suffixes', () {
      final existing = {'video.mp4', 'video (1).mp4'};
      expect(
        FilenameService.uniqueFileName('video.mp4', existingNames: existing),
        'video (2).mp4',
      );
      expect(
        FilenameService.uniqueFileName('other.mp4', existingNames: existing),
        'other.mp4',
      );
    });
  });
}
