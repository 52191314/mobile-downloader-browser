/// Runtime application of [SiteProfile]s during navigation and download
/// enqueue (R-PR-04).
///
/// ## Design
///
/// 1. Profiles are loaded lazily from disk and cached in memory.
/// 2. On URL commit (main-frame navigation), the first enabled matching
///    profile is applied to the **active tab only** (no global mutation).
/// 3. On enqueue, the download folder and custom headers are sourced from
///    the matching profile for the media source page host.
/// 4. Restricted hosts (Play YouTube, etc.) always win regardless of profile.
library;

import 'dart:async';

import '../models/site_profile.dart';
import 'site_profile_matcher.dart';

/// In-memory cache of loaded site profiles.
List<SiteProfile>? _cached;

/// Whether the store has been loaded at least once.
bool _loaded = false;

/// Mutex for concurrent loads.
Completer<void>? _loadMutex;

/// Loads site profiles from disk, caching them in memory. Safe to call
/// multiple times — subsequent calls return the cached list immediately.
Future<List<SiteProfile>> loadProfiles() async {
  if (_loaded) return _cached ?? const [];
  if (_loadMutex != null) {
    await _loadMutex!.future;
    return _cached ?? const [];
  }
  _loadMutex = Completer<void>();
  try {
    const store = SiteProfileStore();
    _cached = await store.load();
    _loaded = true;
    return _cached!;
  } finally {
    _loadMutex!.complete();
    _loadMutex = null;
  }
}

/// Forces a reload from disk on the next [loadProfiles] call.
void invalidateCache() {
  _loaded = false;
  _cached = null;
}

/// Finds the first enabled matching profile for [url].
SiteProfile? findProfile(String url, List<SiteProfile> profiles) {
  return findMatchingProfile(url, profiles);
}

/// Result of applying a site profile to a navigation event.
class SiteProfileNavOverride {
  final String? userAgent;
  final bool? desktopMode;
  final bool? adblockEnabled;
  final bool? replaceSitePlayer;

  const SiteProfileNavOverride({
    this.userAgent,
    this.desktopMode,
    this.adblockEnabled,
    this.replaceSitePlayer,
  });

  /// True if any override is set (non-null).
  bool get hasOverrides =>
      userAgent != null ||
      desktopMode != null ||
      adblockEnabled != null ||
      replaceSitePlayer != null;
}

/// Result of applying a site profile to a download enqueue event.
class SiteProfileEnqueueOverride {
  final String? downloadFolder;
  final Map<String, String>? customHeaders;

  const SiteProfileEnqueueOverride({
    this.downloadFolder,
    this.customHeaders,
  });

  /// True if any override is set.
  bool get hasOverrides => downloadFolder != null || customHeaders != null;
}

/// Computes the navigation overrides from [profiles] for [url].
///
/// Returns `null` when no enabled profile matches.
SiteProfileNavOverride? navOverrideFor(String url, List<SiteProfile> profiles) {
  final profile = findMatchingProfile(url, profiles);
  if (profile == null) return null;
  return SiteProfileNavOverride(
    userAgent: profile.userAgentProfile,
    desktopMode: profile.desktopMode,
    adblockEnabled: profile.adblockEnabled,
    replaceSitePlayer: profile.replaceSitePlayer,
  );
}

/// Computes the enqueue overrides from [profiles] for [url].
///
/// Returns `null` when no enabled profile matches.
SiteProfileEnqueueOverride? enqueueOverrideFor(
    String url, List<SiteProfile> profiles) {
  final profile = findMatchingProfile(url, profiles);
  if (profile == null) return null;
  return SiteProfileEnqueueOverride(
    downloadFolder: profile.downloadFolder,
    customHeaders:
        profile.customHeaders?.map((k, v) => MapEntry(k, v)),
  );
}
