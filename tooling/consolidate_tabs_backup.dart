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

  print('Reading ${files.length} backup files from D:\\Download\\AyuGram Desktop...\n');

  // Track unique URLs with their best human-readable title
  final Map<String, String> urlToTitle = {};
  final Map<String, String> urlToSource = {};

  void processUrl(String? rawUrl, String? rawTitle, String sourceName) {
    if (rawUrl == null) return;
    final url = rawUrl.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return;

    // Filter out internal chunk / video segment blob URLs if they are not browsing pages
    // Keep all regular web pages, video pages, and direct URLs
    final cleanTitle = (rawTitle != null && rawTitle.trim().isNotEmpty)
        ? rawTitle.trim()
        : '';

    if (!urlToTitle.containsKey(url)) {
      urlToTitle[url] = cleanTitle.isNotEmpty ? cleanTitle : url;
      urlToSource[url] = sourceName;
    } else if (cleanTitle.isNotEmpty &&
        (urlToTitle[url] == url || urlToTitle[url]!.isEmpty)) {
      // Upgrade title if a better one was found
      urlToTitle[url] = cleanTitle;
    }
  }

  for (final f in files) {
    final fileName = f.path.split(Platform.pathSeparator).last;
    final content = jsonDecode(f.readAsStringSync());
    final data = content is Map<String, dynamic> && content.containsKey('data')
        ? content['data'] as Map<String, dynamic>
        : content as Map<String, dynamic>;

    // 1. Favorites
    if (data['favorites'] is List) {
      for (final item in data['favorites']) {
        if (item is Map) {
          processUrl(item['url'] as String?, item['title'] as String?, 'Favorites');
          processUrl(item['sourcePageUrl'] as String?, item['title'] as String?, 'Favorites');
        }
      }
    }

    // 2. Saved Pages
    if (data['savedPages'] is List) {
      for (final item in data['savedPages']) {
        if (item is Map) {
          processUrl(item['sourceUrl'] as String?, item['title'] as String?, 'SavedPages');
        }
      }
    }

    // 3. History
    if (data['history'] is List) {
      for (final item in data['history']) {
        if (item is Map) {
          processUrl(item['url'] as String?, item['title'] as String?, 'History');
          processUrl(item['sourcePageUrl'] as String?, item['title'] as String?, 'History');
        }
      }
    }

    // 4. Download Queue
    if (data['downloadQueue'] is List) {
      for (final item in data['downloadQueue']) {
        if (item is Map) {
          processUrl(item['sourcePageUrl'] as String?, null, 'DownloadQueueSource');
          processUrl(item['url'] as String?, null, 'DownloadQueueDirect');
        }
      }
    }

    // 5. Tabs (if present in any)
    if (data['tabs'] is List) {
      for (final item in data['tabs']) {
        if (item is Map) {
          processUrl(item['url'] as String?, item['title'] as String?, 'Tabs');
        }
      }
    }
  }

  print('Total Unique URLs extracted: ${urlToTitle.length}');

  // Separate browsing web pages from raw video stream/hls chunks
  final List<Map<String, dynamic>> tabsList = [];
  final List<String> textLines = [];

  int index = 1;
  urlToTitle.forEach((url, title) {
    final tabId = 'tab_restored_${index.toString().padLeft(5, '0')}';
    tabsList.add({
      'id': tabId,
      'url': url,
      'title': title,
      'groupName': 'Restored 2026 Tabs',
      'groupColorIndex': 0,
      'createdAt': DateTime.now().toIso8601String(),
    });

    textLines.add('$index. [$title] ($url)');
    index++;
  });

  // Construct official Aurora Unified Backup Payload (Version 2)
  final now = DateTime.now();
  final timestampStr = now.toIso8601String();
  
  final backupPayload = {
    'version': 2,
    'timestamp': timestampStr,
    'data': {
      'tabs': tabsList,
      'tabGroups': [
        {
          'id': 'group_restored_2026',
          'name': 'Restored 2026 Tabs',
          'colorIndex': 0,
          'autoHost': null,
          'createdAt': timestampStr,
        }
      ],
    },
  };

  // Output paths in D:\Download\AyuGram Desktop\
  final outputBackupFile = File(
      r'D:\Download\AyuGram Desktop\aurora_backup_consolidated_tabs_2026.json');
  outputBackupFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(backupPayload));

  final outputTxtFile =
      File(r'D:\Download\AyuGram Desktop\unique_links_2026.txt');
  outputTxtFile.writeAsStringSync(textLines.join('\n'));

  print('\nSUCCESS!');
  print('================================================================');
  print('1. Created Aurora Backup File:');
  print('   -> ${outputBackupFile.path}');
  print('   -> Contains ${tabsList.length} unique tabs ready to restore in Aurora!');
  print('   -> Size: ${outputBackupFile.lengthSync()} bytes');
  print('2. Created Plaintext Link List:');
  print('   -> ${outputTxtFile.path}');
  print('================================================================');
}
