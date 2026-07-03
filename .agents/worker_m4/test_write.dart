import 'dart:io';
import 'dart:typed_data';

Future<void> testMode(FileMode mode, String modeName) async {
  final file = File('test_output_$modeName.bin');
  if (file.existsSync()) {
    try {
      file.deleteSync();
    } catch (_) {}
  }

  final data1 = Uint8List.fromList(List.generate(10, (i) => i));
  final data2 = Uint8List.fromList(List.generate(10, (i) => i + 10));

  // Write initial data in write mode
  final raf0 = await file.open(mode: FileMode.write);
  await raf0.setPosition(0);
  await raf0.writeFrom(data1);
  await raf0.close();

  RandomAccessFile? raf;
  try {
    raf = await file.open(mode: mode);
    await raf.setPosition(10);
    await raf.writeFrom(data2);
    print('$modeName: ${file.readAsBytesSync()}');
  } catch (e) {
    print('$modeName error: $e');
  } finally {
    if (raf != null) {
      await raf.close();
    }
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }
}

void main() async {
  await testMode(FileMode.append, 'append');
  await testMode(FileMode.writeOnly, 'writeOnly');
  await testMode(FileMode.writeOnlyAppend, 'writeOnlyAppend');
}
