import '../../sync/sync.dart';

String driveStatusText(DriveConnectionStatus status) {
  return switch (status) {
    DriveConnectionStatus.connected => 'Google Drive linked',
    DriveConnectionStatus.syncing => 'Syncing to Google Drive',
    DriveConnectionStatus.error => 'Google Drive needs attention',
    DriveConnectionStatus.connecting => 'Linking Google Drive',
    DriveConnectionStatus.disconnected => 'Google Drive disconnected',
  };
}

const _sizeKbPresets = [0, 100, 500, 1024, 5120, 10240, 51200, 102400];
const _durationPresets = [0, 10, 30, 60, 120, 300, 600, 900];

String formatSizeKb(int kb) {
  if (kb == 0) return 'Off';
  if (kb < 1024) return '${kb}KB';
  if (kb == 1024) return '1MB';
  return '${(kb / 1024).toStringAsFixed(0)}MB';
}

int sizeKbToSliderIndex(int kb) {
  final idx = _sizeKbPresets.indexOf(kb);
  return idx < 0 ? 0 : idx;
}

int sliderIndexToSizeKb(int index) {
  if (index < 0 || index >= _sizeKbPresets.length) return 0;
  return _sizeKbPresets[index];
}

String formatDurationSeconds(int seconds) {
  if (seconds == 0) return 'Off';
  if (seconds < 60) return '${seconds}s';
  if (seconds == 60) return '1min';
  return '${(seconds / 60).toStringAsFixed(0)}min';
}

int durationSecondsToSliderIndex(int seconds) {
  final idx = _durationPresets.indexOf(seconds);
  return idx < 0 ? 0 : idx;
}

int sliderIndexToDurationSeconds(int index) {
  if (index < 0 || index >= _durationPresets.length) return 0;
  return _durationPresets[index];
}

// Stall-detection speed threshold presets (0 = Off, values in KB/s)
const _speedKbpsPresets = [0, 50, 100, 200, 500, 1000, 2000, 5000];

int speedKbpsToSliderIndex(int kbps) {
  final idx = _speedKbpsPresets.indexOf(kbps);
  return idx < 0 ? 0 : idx;
}

int sliderIndexToSpeedKbps(int index) {
  if (index < 0 || index >= _speedKbpsPresets.length) return 0;
  return _speedKbpsPresets[index];
}
