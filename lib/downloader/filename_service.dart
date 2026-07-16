import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'media_file_types.dart';

/// Shared download filename helpers: sanitize, truncate, quality labels,
/// error-title rejection, and on-disk collision avoidance.
class FilenameService {
  FilenameService._();

  /// Android / most Linux filesystems limit a single path component to 255
  /// **bytes** (UTF-8). Leave a small margin for collision suffixes like
  /// ` (99)` that [uniquePath] may append later.
  static const int androidMaxFileNameBytes = 255;
  static const int defaultMaxFileNameBytes = 240;

  static final Set<String> _errorPageTitles = <String>{
    'web page not available',
    'this page could not be loaded',
    'this site can\'t be reached',
    'page not found',
    'universal widget',
    'this page has been blocked',
    'access denied',
    'site cannot be reached',
    'the page has been blocked',
    'just a moment...',
    'just a moment',
    'attention required!',
    'attention required',
    'checking your browser',
    'please wait',
    'cloudflare',
    '403 forbidden',
    '404 not found',
    '500 internal server error',
    '502 bad gateway',
    '503 service unavailable',
  };

  static final RegExp _errorPagePattern = RegExp(
    r'^(err_|error\s|http\s?\d{3}\s|403\s|404\s|500\s|502\s|503\s)|'
    r'(cloudflare|captcha|access denied|not available|blocked by|'
    r'checking your browser|just a moment|ddos-guard|please wait\.\.\.)',
    caseSensitive: false,
  );

  /// Generic site-chrome titles that make poor download names.
  static final RegExp _genericSiteTitlePattern = RegExp(
    r'^(home|index|main page|welcome|watch free|free videos?|video streaming|'
    r'login|sign in|register|search results?)$',
    caseSensitive: false,
  );

  /// Trailing site brand suffixes: ` | MissAV`, ` - Pornhub`, ` — Site`.
  static final RegExp _siteBrandSuffixPattern = RegExp(
    r'\s*[\|\u2013\u2014\-–—]\s*[^|]{1,40}$',
  );

  /// True when [title] is a WebView error page, WAF interstitial, or
  /// generic site chrome that should not be used as a download filename.
  static bool isUnusableTitle(String title) {
    final low = title.trim().toLowerCase();
    if (low.isEmpty) return true;
    if (low.length < 2) return true;
    if (_errorPageTitles.contains(low)) return true;
    if (_errorPagePattern.hasMatch(low)) return true;
    if (_genericSiteTitlePattern.hasMatch(low)) return true;
    // Very short brand-only titles with no alphanumerics of substance.
    if (low.length < 4 && !RegExp(r'[a-z0-9]{3,}').hasMatch(low)) {
      return true;
    }
    return false;
  }

  /// @deprecated Prefer [isUnusableTitle]. Kept for call-site compatibility.
  static bool isErrorPageTitle(String title) => isUnusableTitle(title);

  /// Strip characters illegal on common filesystems.
  static String sanitize(String name) {
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'[\u0000-\u001F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        // Windows / some MediaStore paths reject trailing dots/spaces.
        .replaceAll(RegExp(r'[\. ]+$'), '');
  }

  /// Clean a page/media title for use as a filename base: strip site brand
  /// suffixes and collapse whitespace. Does not apply [isUnusableTitle].
  static String cleanTitle(String title) {
    var t = title.trim();
    if (t.isEmpty) return t;
    // Strip repeated brand suffixes (e.g. `Title | Site | Site`).
    for (var i = 0; i < 3; i++) {
      final match = _siteBrandSuffixPattern.firstMatch(t);
      if (match == null) break;
      final next = t.substring(0, match.start).trim();
      if (next.isEmpty) break;
      // Only strip short tails that look like site brands, not long
      // descriptive clauses after an em-dash.
      final brand = match.group(0)!
          .replaceFirst(RegExp(r'^\s*[\|\u2013\u2014\-–—]\s*'), '')
          .trim();
      final looksLikeBrand = brand.length <= 32 &&
          !brand.contains(',') &&
          brand.split(RegExp(r'\s+')).length <= 4;
      if (looksLikeBrand) {
        t = next;
      } else {
        break;
      }
    }
    return sanitize(t);
  }

  /// Pick the best usable title from candidates (longest meaningful first).
  static String? pickBestTitle(Iterable<String?> candidates) {
    String? best;
    var bestScore = -1;
    for (final raw in candidates) {
      if (raw == null) continue;
      final cleaned = cleanTitle(raw);
      if (cleaned.isEmpty || isUnusableTitle(cleaned)) continue;
      // Prefer longer descriptive titles; small bonus for containing a
      // product-style code like LULU-172 / FC2-PPV-123.
      var score = cleaned.length;
      if (RegExp(r'[A-Za-z]{2,10}-\d{2,}', caseSensitive: false)
          .hasMatch(cleaned)) {
        score += 20;
      }
      if (score > bestScore) {
        bestScore = score;
        best = cleaned;
      }
    }
    return best;
  }

  /// Split [name] into `(base, extension)` where [extension] includes the
  /// leading dot when it looks like a real short file extension.
  static (String base, String ext) splitExtension(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex <= 0) return (name, '');
    final ext = name.substring(dotIndex);
    // Real extensions: 1–8 alnum chars (mp4, jpeg, m4a, webm, …).
    if (!RegExp(r'^\.[A-Za-z0-9]{1,8}$').hasMatch(ext)) {
      return (name, '');
    }
    // Avoid treating decimal versions like "file.2" as extensions when the
    // "ext" is purely numeric and the rest is short — still treat short
    // numeric tails as non-extensions only if longer than 4? Keep simple:
    // pure-digit extensions (e.g. `.2`) are not media extensions.
    if (RegExp(r'^\.\d+$').hasMatch(ext)) return (name, '');
    return (name.substring(0, dotIndex), ext);
  }

  /// UTF-8 byte length of [s].
  static int utf8ByteLength(String s) => utf8.encode(s).length;

  /// Truncate [name] so the full string fits in [maxBytes] UTF-8 bytes,
  /// always keeping a recognized trailing extension immediately after the
  /// (possibly shortened) base name. No fixed column for the extension —
  /// it rides at the end of whatever base fits.
  ///
  /// [maxBytes] defaults to [defaultMaxFileNameBytes] (Android-safe).
  static String truncate(
    String name, {
    int maxBytes = defaultMaxFileNameBytes,
    @Deprecated('Use maxBytes') int? maxLength,
  }) {
    final limit = maxLength ?? maxBytes;
    if (limit <= 0) return '';
    if (utf8ByteLength(name) <= limit) return name;

    final (base, ext) = splitExtension(name);
    final extBytes = utf8ByteLength(ext);
    // If even the extension alone exceeds the limit, hard-cut the whole name.
    if (extBytes >= limit) {
      return _truncateUtf8(name, limit);
    }
    final baseBudget = limit - extBytes;
    final trimmedBase = _truncateUtf8(base, baseBudget).trimRight();
    // Avoid leaving a dangling space or dot before the extension.
    final cleanBase = trimmedBase.replaceAll(RegExp(r'[\. ]+$'), '');
    if (cleanBase.isEmpty) {
      // Base evaporated — fall back to a minimal name + ext if it fits.
      final fallback = 'download$ext';
      if (utf8ByteLength(fallback) <= limit) return fallback;
      return _truncateUtf8(name, limit);
    }
    return '$cleanBase$ext';
  }

  /// Truncate [s] to at most [maxBytes] UTF-8 bytes without splitting a
  /// multi-byte code unit / rune.
  static String _truncateUtf8(String s, int maxBytes) {
    if (maxBytes <= 0) return '';
    if (utf8ByteLength(s) <= maxBytes) return s;
    // Binary search over character offsets so we never cut mid-rune.
    var low = 0;
    var high = s.length;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (utf8ByteLength(s.substring(0, mid)) <= maxBytes) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return s.substring(0, low);
  }

  /// Extract a quality label like `"720"` (no "p") from URL, height, or
  /// an explicit quality string such as `"720p"` / `"1080p"`.
  static String? qualityLabelFrom({
    String? url,
    int? width,
    int? height,
    String? explicitQuality,
    int? bandwidth,
  }) {
    if (explicitQuality != null && explicitQuality.trim().isNotEmpty) {
      final m = RegExp(r'(\d+)\s*p?', caseSensitive: false)
          .firstMatch(explicitQuality.trim());
      if (m != null) return m.group(1);
    }
    if (url != null) {
      final m = RegExp(r'(?<!\d)(2160|1440|1080|720|540|480|360|240)p(?!\d)',
              caseSensitive: false)
          .firstMatch(url);
      if (m != null) return m.group(1);
    }
    final h = height ?? width;
    if (h != null && h > 0) {
      // Map pixel dimension to common ladder.
      if (h >= 2000) return '2160';
      if (h >= 1300) return '1440';
      if (h >= 900) return '1080';
      if (h >= 650) return '720';
      if (h >= 500) return '540';
      if (h >= 400) return '480';
      if (h >= 300) return '360';
      if (h >= 180) return '240';
    }
    if (bandwidth != null && bandwidth > 0) {
      // Rough bandwidth ladder (bits/s).
      if (bandwidth >= 8000000) return '1080';
      if (bandwidth >= 3500000) return '720';
      if (bandwidth >= 1500000) return '480';
      if (bandwidth >= 700000) return '360';
    }
    return null;
  }

  /// Compose `base + optional quality + extension`, then sanitize/truncate.
  ///
  /// Extension is always immediately after the (quality-suffixed) base —
  /// never placed at a fixed column. Truncation shortens the base only.
  static String composeFileName({
    required String baseName,
    String extension = '',
    String? qualityLabel,
    bool includeQualitySuffix = true,
    int maxBytes = defaultMaxFileNameBytes,
  }) {
    var base = sanitize(baseName);
    if (base.isEmpty) base = 'download';

    var ext = extension.trim();
    if (ext.isNotEmpty && !ext.startsWith('.')) ext = '.$ext';
    // Normalize known playlist extensions away (caller may re-add container).
    final lowExt = ext.toLowerCase();
    if (lowExt == '.m3u8' || lowExt == '.mpd') ext = '';

    final q = includeQualitySuffix &&
            qualityLabel != null &&
            qualityLabel.trim().isNotEmpty
        ? ' (${qualityLabel.trim().replaceAll(RegExp(r'p$', caseSensitive: false), '')}p)'
        : '';

    // Prefer: base + quality + ext. If that exceeds budget, drop quality
    // first so the descriptive title + extension survive longer titles.
    final full = sanitize('$base$q$ext');
    if (utf8ByteLength(full) <= maxBytes) return full;

    final withoutQuality = sanitize('$base$ext');
    if (utf8ByteLength(withoutQuality) <= maxBytes) return withoutQuality;

    return truncate(withoutQuality, maxBytes: maxBytes);
  }

  /// Build a suggested download filename from page/media context.
  ///
  /// Priority for base name:
  /// 1. Best usable page/media title (og/title/structured/media)
  /// 2. Source page path id (e.g. `lulu-172-uncensored-leak`)
  /// 3. [mediaName] cleaned
  /// 4. URL last segment / fallback
  ///
  /// Playlist extensions (`.m3u8`, `.mpd`) are stripped so the downloader
  /// can pick the final container. Quality suffix is optional and always
  /// sits immediately before the file extension.
  static String buildSuggestedFilename({
    required String mediaName,
    String? mediaUrl,
    String? pageTitle,
    String? mediaPageTitle,
    String? structuredName,
    String? sourcePageUrl,
    int? width,
    int? height,
    int? bandwidth,
    String? explicitQuality,
    bool includeQualitySuffix = true,
    bool defaultMp4ForVideoHosts = false,
    bool isPlaylist = false,
    int maxBytes = defaultMaxFileNameBytes,
  }) {
    // Strip parenthetical metadata before extension parse (resolution
    // annotations etc. on mediaName — not quality we want to keep).
    final cleanName = mediaName.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
    final (_, rawExt) = splitExtension(cleanName);
    final hasRealExt = rawExt.isNotEmpty;

    final base = hasRealExt
        ? cleanName.substring(0, cleanName.length - rawExt.length).trim()
        : cleanName;

    var ext = hasRealExt ? rawExt : '';
    final lowExt = ext.toLowerCase();
    if (lowExt == '.m3u8' || lowExt == '.mpd' || isPlaylist) {
      ext = '';
    }
    // Prefer URL path extension when media name lacks one.
    if (ext.isEmpty && mediaUrl != null) {
      final urlExt = MediaFileTypes.extensionFromUrlPath(mediaUrl);
      if (urlExt.isNotEmpty &&
          urlExt != '.m3u8' &&
          urlExt != '.mpd' &&
          urlExt != '.html' &&
          urlExt != '.htm') {
        ext = urlExt;
      }
    }

    String sourceId = '';
    if (sourcePageUrl != null && sourcePageUrl.isNotEmpty) {
      final srcUri = Uri.tryParse(sourcePageUrl);
      if (srcUri != null) {
        final segments = srcUri.pathSegments
            .where((s) =>
                s.isNotEmpty &&
                s != 'en' &&
                s != 'ja' &&
                s != 'cn' &&
                s != 'zh' &&
                s != 'ko' &&
                s != 'dm' &&
                !RegExp(r'^dm\d+$').hasMatch(s))
            .toList();
        if (segments.isNotEmpty) {
          sourceId = segments.last;
        }
      }
    }

    final quality = qualityLabelFrom(
      url: mediaUrl,
      width: width,
      height: height,
      explicitQuality: explicitQuality,
      bandwidth: bandwidth,
    );

    String finalExtFor(String candidateExt) {
      if (candidateExt.isNotEmpty) return candidateExt;
      if (defaultMp4ForVideoHosts) return '.mp4';
      return '';
    }

    final e = finalExtFor(ext);

    // 1) Best descriptive title from page / media / structured data.
    final bestTitle = pickBestTitle([
      pageTitle,
      mediaPageTitle,
      structuredName,
    ]);
    if (bestTitle != null && bestTitle.isNotEmpty) {
      return composeFileName(
        baseName: bestTitle,
        extension: e,
        qualityLabel: quality,
        includeQualitySuffix: includeQualitySuffix,
        maxBytes: maxBytes,
      );
    }

    // 2) Source page path id (e.g. missav slug).
    if (sourceId.isNotEmpty) {
      return composeFileName(
        baseName: sourceId,
        extension: e,
        qualityLabel: quality,
        includeQualitySuffix: includeQualitySuffix,
        maxBytes: maxBytes,
      );
    }

    // 3) Media base name.
    final qBase = base.isNotEmpty ? base : 'video';
    return composeFileName(
      baseName: qBase,
      extension: e.isNotEmpty ? e : (defaultMp4ForVideoHosts ? '.mp4' : ''),
      qualityLabel: quality,
      includeQualitySuffix: includeQualitySuffix,
      maxBytes: maxBytes,
    );
  }

  /// Lighter helper for generic label + URL naming (non-capture paths).
  static String downloadFilenameFor({
    String? label,
    required String targetUrl,
    bool includeQualitySuffix = true,
    int maxBytes = defaultMaxFileNameBytes,
  }) {
    final quality = qualityLabelFrom(url: targetUrl);

    final uri = Uri.tryParse(targetUrl);
    final segments = uri?.pathSegments
            .where((segment) => segment.trim().isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    var filename = label?.trim();
    if (filename == null || filename.isEmpty) {
      filename = segments.isNotEmpty ? segments.last : uri?.host ?? 'download';
    }
    final lowFilename = filename.toLowerCase();
    if (lowFilename.endsWith('.m3u8')) {
      filename = filename.substring(0, filename.length - 5);
    } else if (lowFilename.endsWith('.mpd')) {
      filename = filename.substring(0, filename.length - 4);
    }

    // If label already includes an extension, keep it at the end.
    final (base, ext) = splitExtension(filename);
    return composeFileName(
      baseName: base.isNotEmpty ? base : filename,
      extension: ext,
      qualityLabel: quality,
      includeQualitySuffix: includeQualitySuffix,
      maxBytes: maxBytes,
    );
  }

  /// If [desiredPath] already exists on disk (or collides with [reservedPaths]),
  /// returns a path with ` (1)`, ` (2)`, … before the extension.
  static String uniquePath(
    String desiredPath, {
    Iterable<String>? reservedPaths,
  }) {
    final reserved = <String>{
      if (reservedPaths != null)
        ...reservedPaths.map((p) => p.replaceAll('\\', '/').toLowerCase()),
    };

    bool taken(String path) {
      final n = path.replaceAll('\\', '/');
      if (reserved.contains(n.toLowerCase())) return true;
      try {
        return File(path).existsSync() || Directory(path).existsSync();
      } catch (_) {
        return false;
      }
    }

    if (!taken(desiredPath)) return desiredPath;

    final dir = p.dirname(desiredPath);
    final base = p.basenameWithoutExtension(desiredPath);
    final ext = p.extension(desiredPath);
    for (var i = 1; i < 1000; i++) {
      final candidate = p.join(dir, '$base ($i)$ext');
      if (!taken(candidate)) return candidate;
    }
    // Extremely unlikely; fall back to timestamp.
    final ts = DateTime.now().millisecondsSinceEpoch;
    return p.join(dir, '$base $ts$ext');
  }

  /// Unique filename only (no directory), given existing sibling names.
  static String uniqueFileName(
    String fileName, {
    required Iterable<String> existingNames,
  }) {
    final existing = existingNames.map((n) => n.toLowerCase()).toSet();
    if (!existing.contains(fileName.toLowerCase())) return fileName;
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    for (var i = 1; i < 1000; i++) {
      final candidate = '$base ($i)$ext';
      if (!existing.contains(candidate.toLowerCase())) return candidate;
    }
    return '$base ${DateTime.now().millisecondsSinceEpoch}$ext';
  }
}
