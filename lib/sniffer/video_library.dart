import 'package:aurora_downloader/premium/free_taste.dart';
import 'package:aurora_downloader/premium/pro_entitlement.dart';
import 'package:aurora_downloader/premium/pro_features.dart';

import 'browser_library.dart';

/// Outcome of trying to save a video to the library.
enum VideoSaveOutcome {
  /// Stored.
  saved,

  /// Already in the list — nothing changed, and the caller should say so
  /// rather than silently doing nothing.
  duplicate,

  /// Free inventory cap reached. The caller shows the upsell.
  capped,
}

class VideoSaveResult {
  const VideoSaveResult(this.outcome, this.library);

  final VideoSaveOutcome outcome;

  /// The library to persist. Unchanged from the input for
  /// [VideoSaveOutcome.duplicate] and [VideoSaveOutcome.capped].
  final BrowserLibrary library;

  bool get changed => outcome == VideoSaveOutcome.saved;
}

/// Saved videos and watch history, and the free-tier cap that governs them.
///
/// Kept out of the widgets so the gate is decided in exactly one place. The two
/// lists deliberately behave differently at the cap:
///
///  * **Favourites are explicit.** Refusing loudly with an upsell is right —
///    silently dropping something the user deliberately saved would read as
///    data loss.
///  * **History is automatic.** Trimming to the newest N is right — refusing to
///    record would freeze the list at whatever ten videos happened to come
///    first, which is worse than a rolling window and looks broken.
class VideoLibrary {
  VideoLibrary._();

  static const ProFeature feature = ProFeature.videoLibrary;

  /// Free cap applied to each list separately. Null once the user is Pro+.
  static int? freeLimitFor(EntitlementTier tier) =>
      tier.isAtLeastPro ? null : ProFeatures.freeVideoLibraryItems;

  /// True when [tier] may hold more saved videos.
  static Future<bool> canSaveAnother(
    EntitlementTier tier,
    BrowserLibrary library,
  ) async {
    final decision = await FreeTaste.evaluate(
      feature: feature,
      tier: tier,
      inventoryCount: library.videoFavorites.length,
    );
    return decision.allowed;
  }

  /// Adds a saved video, honouring the free inventory cap.
  static Future<VideoSaveResult> addFavorite({
    required BrowserLibrary library,
    required EntitlementTier tier,
    required String url,
    required String title,
    String? thumbnailUrl,
    String? sourcePageUrl,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return VideoSaveResult(VideoSaveOutcome.duplicate, library);
    }

    final already = library.videoFavorites.any((f) => f.url == trimmed);
    if (already) {
      return VideoSaveResult(VideoSaveOutcome.duplicate, library);
    }

    if (!await canSaveAnother(tier, library)) {
      return VideoSaveResult(VideoSaveOutcome.capped, library);
    }

    final entry = BrowserFavorite(
      id: 'vid_${DateTime.now().microsecondsSinceEpoch}',
      title: title.trim().isEmpty ? trimmed : title.trim(),
      url: trimmed,
      createdAt: DateTime.now(),
      kind: LibraryEntryKind.video,
      thumbnailUrl: thumbnailUrl,
      sourcePageUrl: sourcePageUrl,
    );

    return VideoSaveResult(
      VideoSaveOutcome.saved,
      library.copyWith(favorites: [...library.favorites, entry]),
    );
  }

  static BrowserLibrary removeFavorite(
    BrowserLibrary library,
    String id,
  ) {
    return library.copyWith(
      favorites:
          library.favorites.where((f) => f.id != id).toList(growable: false),
    );
  }

  /// Records a playback in watch history, newest first.
  ///
  /// Replaying the same URL moves the existing entry to the top rather than
  /// stacking duplicates — a watch list of the same video ten times is noise.
  /// Free users keep a rolling window of the newest
  /// [ProFeatures.freeVideoLibraryItems]; Pro+ keeps everything, subject to the
  /// same overall history bound the browser already applies.
  static BrowserLibrary recordPlay({
    required BrowserLibrary library,
    required EntitlementTier tier,
    required String url,
    required String title,
    String? thumbnailUrl,
    String? sourcePageUrl,
    int maxVideoEntries = 500,
  }) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return library;

    final entry = BrowserHistoryEntry(
      title: title.trim().isEmpty ? trimmed : title.trim(),
      url: trimmed,
      visitedAt: DateTime.now(),
      kind: LibraryEntryKind.video,
      thumbnailUrl: thumbnailUrl,
      sourcePageUrl: sourcePageUrl,
    );

    // Site history is untouched — it is free and uncapped, and rebuilding the
    // combined list must not reorder or drop any of it.
    final sites = library.history
        .where((h) => h.kind == LibraryEntryKind.site)
        .toList(growable: false);

    final videos = library.history
        .where((h) => h.kind == LibraryEntryKind.video && h.url != trimmed)
        .toList()
      ..insert(0, entry)
      ..sort((a, b) => b.visitedAt.compareTo(a.visitedAt));

    final limit = freeLimitFor(tier) ?? maxVideoEntries;
    final capped =
        videos.length > limit ? videos.sublist(0, limit) : videos;

    return library.copyWith(history: [...sites, ...capped]);
  }

  static BrowserLibrary clearVideoHistory(BrowserLibrary library) {
    return library.copyWith(
      history: library.history
          .where((h) => h.kind == LibraryEntryKind.site)
          .toList(growable: false),
    );
  }
}
