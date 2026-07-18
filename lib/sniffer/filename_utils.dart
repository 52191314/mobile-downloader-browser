import '../downloader/filename_service.dart';

/// Public utility — wraps [FilenameService.truncate] so that widgets,
/// dialogs, and controllers can truncate filenames to the Android
/// filesystem byte limit without reaching into `_SnifferScreenState`.
///
/// Previously this lived as both a private instance method and a public
/// static method on `_SnifferScreenState`. Extracted here so that
/// formerly-`part` widgets (add_queue_dialog, rename_file_dialog, etc.)
/// can import it directly.
String truncateFilename(
  String name, {
  int maxLength = FilenameService.defaultMaxFileNameBytes,
}) {
  return FilenameService.truncate(name, maxBytes: maxLength);
}
