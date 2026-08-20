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

  final Map<String, String> allUrls = {};

  for (final f in files) {
    final content = jsonDecode(f.readAsStringSync());
    final data = content is Map<String, dynamic> && content.containsKey('data')
        ? content['data'] as Map<String, dynamic>
        : content as Map<String, dynamic>;

    void check(String? url, String? title) {
      if (url == null) return;
      final u = url.trim();
      if (!u.startsWith('http://') && !u.startsWith('https://')) return;
      final t = (title != null && title.trim().isNotEmpty) ? title.trim() : u;
      if (!allUrls.containsKey(u) || allUrls[u] == u) {
        allUrls[u] = t;
      }
    }

    if (data['favorites'] is List) {
      for (final item in data['favorites']) {
        if (item is Map) check(item['url'] as String?, item['title'] as String?);
      }
    }
    if (data['history'] is List) {
      for (final item in data['history']) {
        if (item is Map) check(item['url'] as String?, item['title'] as String?);
      }
    }
    if (data['downloadQueue'] is List) {
      for (final item in data['downloadQueue']) {
        if (item is Map) {
          check(item['sourcePageUrl'] as String?, null);
          check(item['url'] as String?, null);
        }
      }
    }
  }

  // Keywords
  final pussyKeywords = ['逼', '穴', '阴', 'pussy', 'vagina', 'clit'];
  final europeKeywords = ['欧美', '洋', '白人', '洋马', 'europe', 'european', 'euro', 'western'];
  final orgyKeywords = ['3p', '3P', '群交', '多p', '多P', '多人', '双飞', '两男', 'orgy', 'threesome', 'gangbang', 'group'];

  final pussyMatches = <Map<String, String>>[];
  final europeMatches = <Map<String, String>>[];
  final orgyMatches = <Map<String, String>>[];

  allUrls.forEach((url, title) {
    final combined = '$title $url'.toLowerCase();
    
    if (pussyKeywords.any((k) => combined.contains(k.toLowerCase()))) {
      pussyMatches.add({'title': title, 'url': url});
    }
    if (europeKeywords.any((k) => combined.contains(k.toLowerCase()))) {
      europeMatches.add({'title': title, 'url': url});
    }
    if (orgyKeywords.any((k) => combined.contains(k.toLowerCase()))) {
      orgyMatches.add({'title': title, 'url': url});
    }
  });

  print('=== RESULTS FROM ALL 9 BACKUPS (2,878 LINKS) ===');
  print('1. Orgy / 3P / Threesome / Group matches: ${orgyMatches.length}');
  print('2. Europe / Western matches: ${europeMatches.length}');
  print('3. Pussy / Intimate matches: ${pussyMatches.length}');

  print('\n--- TOP ORGY / 3P / MULTI-PERSON MATCHES ---');
  for (var i = 0; i < orgyMatches.length && i < 20; i++) {
    print('${i + 1}. [${orgyMatches[i]['title']}] -> ${orgyMatches[i]['url']}');
  }

  print('\n--- TOP EUROPE / WESTERN MATCHES ---');
  for (var i = 0; i < europeMatches.length && i < 20; i++) {
    print('${i + 1}. [${europeMatches[i]['title']}] -> ${europeMatches[i]['url']}');
  }

  print('\n--- TOP PUSSY / INTIMATE MATCHES ---');
  for (var i = 0; i < pussyMatches.length && i < 20; i++) {
    print('${i + 1}. [${pussyMatches[i]['title']}] -> ${pussyMatches[i]['url']}');
  }
}
