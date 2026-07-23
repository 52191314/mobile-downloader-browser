import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// First-launch app tour (spotlight coachmarks).
///
/// **Product default:** show the tour once per install until the user
/// finishes or skips. Optional compile-time / local overrides remain for
/// debugging and tests:
///
/// - `--dart-define=AURORA_ENABLE_ONBOARDING=false` → never auto-show
/// - `--dart-define=AURORA_ENABLE_ONBOARDING=true` → force available (default)
/// - [setExperimentOverride] → local force on/off + reset when enabling
class OnboardingExperiment {
  OnboardingExperiment._();

  static const String _fileName = 'onboarding_experiment.json';

  /// Compile-time gate. Default **true** so first install shows the tour.
  /// Set `AURORA_ENABLE_ONBOARDING=false` to disable auto-show (e.g. demos).
  static const bool compileTimeFlag = bool.fromEnvironment(
    'AURORA_ENABLE_ONBOARDING',
    defaultValue: true,
  );

  /// Whether the tour feature is available (override → else compile flag).
  static Future<bool> isEnabled() async {
    final override = await getExperimentOverride();
    if (override != null) {
      return override;
    }
    return compileTimeFlag;
  }

  /// True when the tour should auto-present (enabled and not completed).
  static Future<bool> shouldAutoShowTour() async {
    if (!await isEnabled()) return false;
    return !await hasCompletedOnboarding();
  }

  /// Check if the user has already completed or dismissed the onboarding tutorial.
  static Future<bool> hasCompletedOnboarding() async {
    try {
      final data = await _readState();
      return data['hasCompletedOnboarding'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Mark onboarding as completed.
  static Future<void> markCompleted({bool completed = true}) async {
    final data = await _readState();
    data['hasCompletedOnboarding'] = completed;
    await _writeState(data);
  }

  /// Reset onboarding state so it can be shown again (user-facing "Show tour").
  ///
  /// Also clears a stale local disable override so the product tour can run
  /// after the old experiment switch was turned off.
  static Future<void> resetOnboarding() async {
    final data = await _readState();
    data['hasCompletedOnboarding'] = false;
    data.remove('experimentOverride');
    await _writeState(data);
  }

  /// Override the enabled state locally (debug / tests). Enabling also resets
  /// completion so the tour can run immediately.
  static Future<void> setExperimentOverride(bool? enabled) async {
    final data = await _readState();
    if (enabled == null) {
      data.remove('experimentOverride');
    } else {
      data['experimentOverride'] = enabled;
      if (enabled) {
        data['hasCompletedOnboarding'] = false;
      }
    }
    await _writeState(data);
  }

  /// Get the current override state (null = using default build logic).
  static Future<bool?> getExperimentOverride() async {
    try {
      final data = await _readState();
      return data['experimentOverride'] as bool?;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> _readState() async {
    try {
      final file = await _getConfigFile();
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _writeState(Map<String, dynamic> data) async {
    try {
      final file = await _getConfigFile();
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  static Future<File> _getConfigFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }
}
