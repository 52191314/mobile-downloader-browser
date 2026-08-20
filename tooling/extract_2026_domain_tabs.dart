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

  print('Searching 9 backups for URLs starting with http(s)://2026...\n');

  final Map<String, String> urlToTitle = {};

  bool is2026Url(String? url) {
    if (url == null) return false;
    final trimmed = url.trim().toLowerCase();
    return trimmed.startsWith('https://2026') ||
        trimmed.startsWith('http://2026') ||
        trimmed.startsWith('https://www.2026') ||
        trimmed.startsWith('http://www.2026');
  }

  void process(String? rawUrl, String? rawTitle) {
    if (rawUrl == null) return;
    final url = rawUrl.trim();
    if (!is2026Url(url)) return;

    final title = (rawTitle != null && rawTitle.trim().isNotEmpty)
        ? rawTitle.trim()
        : url;

    if (!urlToTitle.containsKey(url) || urlToTitle[url] == url) {
      urlToTitle[url] = title;
    }
  }

  for (final f in files) {
    final content = jsonDecode(f.readAsStringSync());
    final data = content is Map<String, dynamic> && content.containsKey('data')
        ? content['data'] as Map<String, dynamic>
        : content as Map<String, dynamic>;

    if (data['favorites'] is List) {
      for (final item in data['favorites']) {
        if (item is Map) {
          process(item['url'] as String?, item['title'] as String?);
          process(item['sourcePageUrl'] as String?, item['title'] as String?);
        }
      }
    }

    if (data['history'] is List) {
      for (final item in data['history']) {
        if (item is Map) {
          process(item['url'] as String?, item['title'] as String?);
          process(item['sourcePageUrl'] as String?, item['title'] as String?);
        }
      }
    }

    if (data['downloadQueue'] is List) {
      for (final item in data['downloadQueue']) {
        if (item is Map) {
          process(item['sourcePageUrl'] as String?, null);
          process(item['url'] as String?, null);
        }
      }
    }

    if (data['savedPages'] is List) {
      for (final item in data['savedPages']) {
        if (item is Map) {
          process(item['sourceUrl'] as String?, item['title'] as String?);
        }
      }
    }

    if (data['tabs'] is List) {
      for (final item in data['tabs']) {
        if (item is Map) {
          process(item['url'] as String?, item['title'] as String?);
        }
      }
    }
  }

  print('Found ${urlToTitle.length} UNIQUE links starting with 2026:');
  print('================================================================');

  final List<Map<String, dynamic>> tabsList = [];
  final List<String> textLines = [];

  int index = 1;
  urlToTitle.forEach((url, title) {
    print('$index. [$title] -> $url');
    tabsList.add({
      'id': 'tab_2026_${index.toString().padLeft(4, '0')}',
      'url': url,
      'title': title,
      'groupName': '2026 Sites',
      'groupColorIndex': 1,
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
          'id': 'group_2026_sites',
          'name': '2026 Sites',
          'colorIndex': 1,
          'autoHost': null,
          'createdAt': timestampStr,
        }
      ],
    },
  };

  final outputBackupFile = File(
      r'D:\Download\AyuGram Desktop\aurora_backup_2026_links_tabs_only.json');
  outputBackupFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(backupPayload));

  final outputTxtFile =
      File(r'D:\Download\AyuGram Desktop\links_starting_with_2026.txt');
  outputTxtFile.writeAsStringSync(textLines.join('\n'));

  print('================================================================');
  print('\nFiles created:');
  print('1. Backup JSON: ${outputBackupFile.path} (${outputBackupFile.lengthSync()} bytes)');
  print('2. Text file:   ${outputTxtFile.path}');
}
