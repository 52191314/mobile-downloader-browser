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

  for (final f in files) {
    final fileName = f.path.split(Platform.pathSeparator).last;
    final content = jsonDecode(f.readAsStringSync());
    final data = content is Map<String, dynamic> && content.containsKey('data')
        ? content['data'] as Map<String, dynamic>
        : content as Map<String, dynamic>;

    print('================================================================');
    print('File: $fileName');
    print('Keys: ${data.keys.toList()}');
    for (final key in data.keys) {
      final val = data[key];
      if (val is List) {
        print('  - $key: ${val.length} items');
        if (val.isNotEmpty && val.first is Map) {
          final firstMap = val.first as Map;
          print('    sample keys: ${firstMap.keys.toList()}');
          if (firstMap.containsKey('url')) {
            print('    sample url: ${firstMap['url']}');
          }
          if (firstMap.containsKey('originalUrl')) {
            print('    sample originalUrl: ${firstMap['originalUrl']}');
          }
        }
      } else if (val is Map) {
        print('  - $key (Map with ${val.length} keys)');
      }
    }
  }
}
