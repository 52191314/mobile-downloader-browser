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

  print('Found ${files.length} backup files starting with 2026:');
  for (final f in files) {
    print(' - ${f.path.split(Platform.pathSeparator).last} (${f.lengthSync()} bytes)');
  }

  if (files.isEmpty) {
    print('No files found!');
    return;
  }

  // Inspect first file
  final firstFile = files.first;
  final content = jsonDecode(firstFile.readAsStringSync());
  final data = content is Map<String, dynamic> && content.containsKey('data')
      ? content['data'] as Map<String, dynamic>
      : content as Map<String, dynamic>;

  print('\nKeys in first backup payload data: ${data.keys.toList()}');
  if (data['tabs'] != null && data['tabs'] is List) {
    final tabs = data['tabs'] as List;
    print('First backup has ${tabs.length} tabs.');
    if (tabs.isNotEmpty) {
      print('Sample tab: ${jsonEncode(tabs.first)}');
    }
  }
}
