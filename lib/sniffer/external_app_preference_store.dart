import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart';

/// Remembered choice for a given external app / scheme.
enum ExternalAppDecision {
  /// No saved preference — always prompt.
  ask,

  /// Open without prompting.
  alwaysAllow,

  /// Never open (still cancel WebView load).
  alwaysDeny,
}

/// Persists "don't ask again" decisions for external app opens
/// (`tg:`, `intent://`, `market://`, …).
///
/// Keys are stable app identifiers from [externalAppKeyForUri].
class ExternalAppPreferenceStore {
  ExternalAppPreferenceStore._();
  static final ExternalAppPreferenceStore instance =
      ExternalAppPreferenceStore._();

  static const _fileName = 'external_app_preferences.json';

  Map<String, ExternalAppDecision>? _cache;
  Future<void>? _loadFuture;

  @visibleForTesting
  static void resetForTesting([Map<String, ExternalAppDecision>? initialCache]) {
    instance._cache = initialCache ?? {};
    instance._loadFuture = null;
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    _loadFuture ??= _load();
    await _loadFuture;
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        _cache ??= {};
        return;
      }
      final raw = jsonDecode(await f.readAsString());
      final map = <String, ExternalAppDecision>{};
      if (raw is Map) {
        raw.forEach((k, v) {
          final key = k.toString();
          final name = v.toString();
          if (name == ExternalAppDecision.alwaysAllow.name) {
            map[key] = ExternalAppDecision.alwaysAllow;
          } else if (name == ExternalAppDecision.alwaysDeny.name) {
            map[key] = ExternalAppDecision.alwaysDeny;
          }
        });
      }
      _cache = map;
    } catch (_) {
      _cache ??= {};
    }
  }

  Future<void> _save() async {
    final cache = _cache;
    if (cache == null) return;
    final out = <String, String>{};
    cache.forEach((k, v) {
      if (v != ExternalAppDecision.ask) {
        out[k] = v.name;
      }
    });
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(out));
    } catch (_) {
      // In-memory cache is retained even if disk I/O is unavailable (e.g. test environment).
    }
  }

  Future<ExternalAppDecision> decisionFor(String appKey) async {
    await _ensureLoaded();
    return _cache![appKey] ?? ExternalAppDecision.ask;
  }

  Future<void> setDecision(String appKey, ExternalAppDecision decision) async {
    await _ensureLoaded();
    if (decision == ExternalAppDecision.ask) {
      _cache!.remove(appKey);
    } else {
      _cache![appKey] = decision;
    }
    await _save();
  }

  /// Snapshot of non-ask preferences (for settings UI).
  Future<Map<String, ExternalAppDecision>> allDecisions() async {
    await _ensureLoaded();
    return Map<String, ExternalAppDecision>.from(_cache!);
  }

  Future<void> clearAll() async {
    _cache = {};
    await _save();
  }
}

/// Stable key for preference storage.
///
/// Prefers Android package from `intent://` when present; otherwise scheme.
String externalAppKeyForUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'intent') {
    final raw = uri.toString();
    final pkg = RegExp(
      r'[;?]package=([^;]+)',
      caseSensitive: false,
    ).firstMatch(raw)?.group(1);
    if (pkg != null && pkg.isNotEmpty) {
      return 'package:${pkg.trim()}';
    }
    final host = uri.host;
    if (host.isNotEmpty) return 'intent:$host';
    return 'scheme:intent';
  }
  if (scheme == 'android-app') {
    // android-app://com.example.app/...
    final host = uri.host;
    if (host.isNotEmpty) return 'package:$host';
  }
  if (scheme.isEmpty) return 'scheme:unknown';
  return 'scheme:$scheme';
}

/// Human-readable label for dialogs.
String externalAppDisplayNameForUri(Uri uri) =>
    externalAppDisplayNameForKey(externalAppKeyForUri(uri));

/// Human-readable label for a stored key from [externalAppKeyForUri].
///
/// The settings UI only has keys (that is what is persisted), so this is the
/// key-side half of [externalAppDisplayNameForUri].
String externalAppDisplayNameForKey(String key) {
  if (key.startsWith('package:')) {
    final pkg = key.substring('package:'.length);
    return _knownPackageLabels[pkg] ?? pkg;
  }
  if (key.startsWith('scheme:')) {
    final scheme = key.substring('scheme:'.length);
    return _knownSchemeLabels[scheme] ?? scheme;
  }
  if (key.startsWith('intent:')) {
    return key.substring('intent:'.length);
  }
  return key;
}

/// Secondary line for the settings UI: the raw key, when it differs from the
/// friendly label. Returns null when the label already says everything.
String? externalAppSubtitleForKey(String key) {
  final label = externalAppDisplayNameForKey(key);
  return label == key ? null : key;
}

const _knownPackageLabels = <String, String>{
  'org.telegram.messenger': 'Telegram',
  'org.telegram.messenger.web': 'Telegram',
  'com.whatsapp': 'WhatsApp',
  'com.instagram.android': 'Instagram',
  'com.facebook.katana': 'Facebook',
  'com.facebook.orca': 'Messenger',
  'com.twitter.android': 'X (Twitter)',
  'com.google.android.youtube': 'YouTube',
  'com.android.vending': 'Play Store',
  'com.spotify.music': 'Spotify',
  'com.discord': 'Discord',
  'com.snapchat.android': 'Snapchat',
  'com.zhiliaoapp.musically': 'TikTok',
  'com.ss.android.ugc.trill': 'TikTok',
  'com.viber.voip': 'Viber',
  'jp.naver.line.android': 'LINE',
  'com.skype.raider': 'Skype',
  'com.ubercab': 'Uber',
  'com.google.android.apps.maps': 'Google Maps',
};

const _knownSchemeLabels = <String, String>{
  'tg': 'Telegram',
  'telegram': 'Telegram',
  'whatsapp': 'WhatsApp',
  'mailto': 'Email',
  'tel': 'Phone',
  'sms': 'Messages',
  'smsto': 'Messages',
  'market': 'Play Store',
  'intent': 'External app',
  'vnd.youtube': 'YouTube',
  'spotify': 'Spotify',
  'fb': 'Facebook',
  'fb-messenger': 'Messenger',
  'twitter': 'X (Twitter)',
  'instagram': 'Instagram',
  'snapchat': 'Snapchat',
  'geo': 'Maps',
  'google.navigation': 'Maps',
  'maps': 'Maps',
  'uber': 'Uber',
  'discord': 'Discord',
  'line': 'LINE',
  'viber': 'Viber',
};
