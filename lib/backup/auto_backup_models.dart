
/// How often the app automatically backs up its data.
enum AutoBackupInterval {
  onBackground(Duration.zero, 'When app is backgrounded'),
  hourly(const Duration(hours: 1), 'Every hour'),
  every6h(const Duration(hours: 6), 'Every 6 hours'),
  every12h(const Duration(hours: 12), 'Every 12 hours'),
  daily(const Duration(days: 1), 'Daily'),
  every3d(const Duration(days: 3), 'Every 3 days'),
  weekly(const Duration(days: 7), 'Weekly');

  const AutoBackupInterval(this.duration, this.label);

  final Duration duration;
  final String label;

  static AutoBackupInterval fromName(String? name) {
    if (name == null) return AutoBackupInterval.daily;
    for (final value in AutoBackupInterval.values) {
      if (value.name == name) return value;
    }
    return AutoBackupInterval.daily;
  }
}

/// A single file inside a backup snapshot, as reported by the native layer.
class AutoBackupFile {
  const AutoBackupFile({
    required this.timestamp,
    required this.name,
    required this.uri,
  });

  /// The snapshot folder name (e.g. `2026-07-14_15-30-00`).
  final String timestamp;

  /// File name inside the snapshot (e.g. `download_queue.json`).
  final String name;

  /// MediaStore content URI used to read the file back during restore.
  final String uri;
}
