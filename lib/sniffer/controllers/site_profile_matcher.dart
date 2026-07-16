import '../models/site_profile.dart';

/// Finds the first enabled [SiteProfile] whose [hostPattern] matches [url].
///
/// Returns `null` when no profile matches.
///
/// Matching rules:
/// - `*.example.com` matches `sub.example.com` and `deep.sub.example.com`
///   but NOT `example.com`.
/// - `example.com` matches `example.com` exactly (no subdomains).
/// - Literal IP addresses and non-HTTP URLs return `null`.
SiteProfile? findMatchingProfile(String url, List<SiteProfile> profiles) {
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return null;
  for (final profile in profiles) {
    if (!profile.enabled) continue;
    if (_hostMatches(host, profile.hostPattern)) return profile;
  }
  return null;
}

/// Returns `true` when [host] matches [pattern].
///
/// Pattern syntax:
/// - `*.suffix` — matches any subdomain of `suffix` (including multiple
///   levels), but NOT the bare `suffix` itself.
/// - Anything else — exact match against the full host.
bool _hostMatches(String host, String pattern) {
  final trimmedPattern = pattern.trim().toLowerCase();
  final trimmedHost = host.trim().toLowerCase();

  if (trimmedPattern.startsWith('*.')) {
    final suffix = trimmedPattern.substring(2);
    if (suffix.isEmpty) return false;
    // *.example.com matches sub.example.com but NOT example.com
    return trimmedHost.endsWith('.$suffix');
  }

  return trimmedHost == trimmedPattern;
}
