import 'dart:convert';
import 'dart:io';

void main() {
  final dir = Directory(r'D:\Download\AyuGram Desktop');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) =>
          f.path.contains('aurora_backup_2026') && f.path.endsWith('.json'))
      .toList();

  files.sort((a, b) => a.path.compareTo(b.path));

  print('Processing ${files.length} backup files...\n');

  final Map<String, String> uniqueUrlsToTitle = {};
  final Set<String> favUrls = {};
  final Set<String> historyUrls = {};
  final Set<String> queueSourceUrls = {};
  final Set<String> queueDirectUrls = {};
  final Set<String> savedPagesUrls = {};
  final Set<String> tabsUrls = {};

  void addUrl(String? rawUrl, String? rawTitle, String sourceCategory) {
    if (rawUrl == null) return;
    final url = rawUrl.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return;

    final lower = url.toLowerCase();
    // Prefer browser page URLs over internal m3u8/video direct segment URLs if possible,
    // but keep all valid web URLs.
    if (!uniqueUrlsToTitle.containsKey(url)) {
      uniqueUrlsToTitle[url] = (rawTitle != null && rawTitle.trim().isNotEmpty)
          ? rawTitle.trim()
          : url;
    }

    switch (sourceCategory) {
      case 'favorites':
        favUrls.add(url);
        break;
      case 'history':
        historyUrls.add(url);
        break;
      case 'queueSource':
        queueSourceUrls.add(url);
        break;
      case 'queueDirect':
        queueDirectUrls.add(url);
        break;
      case 'savedPages':
        savedPagesUrls.add(url);
        break;
      case 'tabs':
        tabsUrls.add(url);
        break;
    }
  }

  for (final f in files) {
    final content = jsonDecode(f.readAsStringSync());
    final data = content is Map<String, dynamic> && content.containsKey('data')
        ? content['data'] as Map<String, dynamic>
        : content as Map<String, dynamic>;

    // 1. Tabs
    if (data['tabs'] is List) {
      for (final t in data['tabs']) {
        if (t is Map) {
          addUrl(t['url'] as String?, t['title'] as String?, 'tabs');
        }
      }
    }

    // 2. Favorites
    if (data['favorites'] is List) {
      for (final fav in data['favorites']) {
        if (fav is Map) {
          addUrl(fav['url'] as String?, fav['title'] as String?, 'favorites');
          addUrl(fav['sourcePageUrl'] as String?, fav['title'] as String?, 'favorites');
        }
      }
    }

    // 3. Saved Pages
    if (data['savedPages'] is List) {
      for (final sp in data['savedPages']) {
        if (sp is Map) {
          addUrl(sp['sourceUrl'] as String?, sp['title'] as String?, 'savedPages');
        }
      }
    }

    // 4. History
    if (data['history'] is List) {
      for (final h in data['history']) {
        if (h is Map) {
          addUrl(h['url'] as String?, h['title'] as String?, 'history');
          addUrl(h['sourcePageUrl'] as String?, h['title'] as String?, 'history');
        }
      }
    }

    // 5. Download Queue
    if (data['downloadQueue'] is List) {
      for (final q in data['downloadQueue']) {
        if (q is Map) {
          addUrl(q['sourcePageUrl'] as String?, null, 'queueSource');
          addUrl(q['url'] as String?, null, 'queueDirect');
        }
      }
    }
  }

  print('Summary of links found:');
  print(' - From Tabs: ${tabsUrls.length}');
  print(' - From Favorites / Bookmarks: ${favUrls.length}');
  print(' - From History (Pages visited): ${historyUrls.length}');
  print(' - From Download Queue Source Pages: ${queueSourceUrls.length}');
  print(' - From Download Queue Media URLs: ${queueDirectUrls.length}');
  print(' - From Saved Pages: ${savedPagesUrls.length}');
  print(' TOTAL UNIQUE WEB URLs across all 9 backups: ${uniqueUrlsToTitle.length}');

  // Separate page URLs from raw media stream URLs (.m3u8, .mp4, .ts, etc.)
  final pageUrls = <String, String>{};
  final directMediaUrls = <String, String>{};

  uniqueUrlsToTitle.forEach((url, title) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') ||
        lower.contains('.mp4') ||
        lower.contains('.ts') ||
        lower.contains('/hls/') ||
        lower.contains('/seg-') ||
        lower.contains('surrit.com')) {
      directMediaUrls[url] = title;
    } else {
      pageUrls[url] = title;
    }
  });

  print('\nBreakdown:');
  print(' - Web Pages / Site URLs (Browsing): ${pageUrls.length}');
  print(' - Direct Media / Stream URLs: ${directMediaUrls.length}');

  print('\nSample Web Page URLs:');
  pageUrls.entries.take(15).forEach((e) {
    print('   * [${e.value}] -> ${e.key}');
  });
}
