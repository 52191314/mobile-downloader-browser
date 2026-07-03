import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/idm_backup_parser.dart';

void main() {
  test("IdmBackupParser parses today's backup successfully", () async {
    const path = r"D:\Download\AyuGram Desktop\1DM_Data_2026-06-25-08-15-53.1dmbak";
    final decoded = await IdmBackupParser.parse(path);
    
    expect(decoded.containsKey('downloadQueue'), isTrue);
    expect(decoded.containsKey('favorites'), isTrue);
    expect(decoded.containsKey('folders'), isTrue);
    expect(decoded.containsKey('history'), isTrue);
    
    final queue = decoded['downloadQueue'] as List;
    final favorites = decoded['favorites'] as List;
    final folders = decoded['folders'] as List;
    final history = decoded['history'] as List;
    
    expect(queue.length, 68);
    expect(favorites.length, 2);
    expect(folders.length, 1);
    expect(history.length, 0);
    
    // Check favorite structures
    final fav = favorites.first;
    expect(fav['id'], isNotNull);
    expect(fav['title'], isNotNull);
    expect(fav['url'], isNotNull);
    expect(fav['createdAt'], isNotNull);
    
    // Check folder structures
    final folder = folders.first;
    expect(folder['id'], 'folder_1');
    expect(folder['name'], 'Great CN');
  });

  test("IdmBackupParser parses older backup containing history successfully", () async {
    const path = r"D:\00_Inbox\Downloads\AyuGram Desktop\1DM_Data_2026-06-14-07-44-59 (1).1dmbak";
    final decoded = await IdmBackupParser.parse(path);
    
    expect(decoded.containsKey('downloadQueue'), isTrue);
    expect(decoded.containsKey('favorites'), isTrue);
    expect(decoded.containsKey('folders'), isTrue);
    expect(decoded.containsKey('history'), isTrue);
    
    final queue = decoded['downloadQueue'] as List;
    final favorites = decoded['favorites'] as List;
    final folders = decoded['folders'] as List;
    final history = decoded['history'] as List;
    
    expect(queue.length, 285);
    expect(favorites.length, 3);
    expect(folders.length, 0);
    expect(history.length, 1569);
    
    // Check history structures
    final hist = history.first;
    expect(hist['title'], isNotNull);
    expect(hist['url'], isNotNull);
    expect(hist['visitedAt'], isNotNull);
  });
}
