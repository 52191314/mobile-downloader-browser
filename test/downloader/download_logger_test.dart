import 'dart:convert';
import 'dart:io';

import 'package:aurora_downloader/downloader/download_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late String logPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('download_logger_test');
    logPath = '${tempDir.path}/test_logs.json';
    await DownloadLogger.instance.initialize(logPath);
    DownloadLogger.instance.clear();
    await DownloadLogger.instance.pendingWrites;
  });

  tearDown(() async {
    DownloadLogger.instance.clear();
    await DownloadLogger.instance.pendingWrites;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('DownloadLogger persists logs to file and loads them', () async {
    final logger = DownloadLogger.instance;
    await logger.initialize(logPath);

    logger.error('First test error message');
    logger.error('Second test error message');

    await logger.pendingWrites;

    final file = File(logPath);
    expect(await file.exists(), isTrue);

    final content = await file.readAsString();
    final decoded = jsonDecode(content) as List;
    expect(decoded.length, equals(2));
    expect(decoded[0]['message'], equals('Second test error message'));
    expect(decoded[1]['message'], equals('First test error message'));

    // Create a new instance representation or re-initialize to verify loading
    logger.clear();
    await logger.pendingWrites;
    expect(logger.logs.isEmpty, isTrue);

    // Write manually into file to test initialization
    final sampleData = [
      {
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'ERROR',
        'message': 'Loaded from file',
      }
    ];
    await file.writeAsString(jsonEncode(sampleData));

    await logger.initialize(logPath);
    expect(logger.logs.length, equals(1));
    expect(logger.logs.first.message, equals('Loaded from file'));
  });

  test('DownloadLogger handles concurrent writes without crashes', () async {
    final logger = DownloadLogger.instance;
    await logger.initialize(logPath);

    // Call logging multiple times concurrently
    for (int i = 0; i < 20; i++) {
      logger.error('Concurrent error $i');
    }

    await logger.pendingWrites;

    final file = File(logPath);
    expect(await file.exists(), isTrue);

    final content = await file.readAsString();
    final decoded = jsonDecode(content) as List;
    expect(decoded.length, equals(20));
    expect(decoded.first['message'], equals('Concurrent error 19'));
  });
}
