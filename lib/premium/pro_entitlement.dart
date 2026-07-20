import 'dart:async';

import 'package:flutter/foundation.dart';

import 'pro_entitlement_store.dart';

/// Distribution tier derived from owned Play product IDs.
enum EntitlementTier { free, pro, ultra }

/// Where the current entitlement came from.
enum EntitlementSource { none, play, legacy, cache, debug }

extension EntitlementTierX on EntitlementTier {
  bool get isAtLeastPro => index >= EntitlementTier.pro.index;
  bool get isUltra => this == EntitlementTier.ultra;
  bool isAtLeast(EntitlementTier min) => index >= min.index;
}

/// Product IDs for the three one-time Aurora SKUs.
const String kAuroraProProductId = 'aurora_pro_unlock';
const String kAuroraUltraProductId = 'aurora_ultra_unlock';
const String kAuroraUltraUpgradeProductId = 'aurora_ultra_upgrade';

const Set<String> kAllProductIds = {
  kAuroraProProductId,
  kAuroraUltraProductId,
  kAuroraUltraUpgradeProductId,
};

/// Maps a Play product ID to the tier it grants, or null if unknown.
EntitlementTier? tierForProductId(String id) {
  switch (id) {
    case kAuroraProProductId:
      return EntitlementTier.pro;
    case kAuroraUltraProductId:
    case kAuroraUltraUpgradeProductId:
      return EntitlementTier.ultra;
    default:
      return null;
  }
}

/// Highest tier across a set of owned product IDs.
EntitlementTier maxTierForOwned(Iterable<String> owned) {
  var max = EntitlementTier.free;
  for (final id in owned) {
    final t = tierForProductId(id);
    if (t != null && t.index > max.index) max = t;
  }
  return max;
}

/// Pro entitlement service — the single source of truth for the user's
/// Aurora tier (free / pro / ultra) and the set of owned product IDs.
///
/// Tier is always **derived** from [ownedProductIds] as
/// `max(tierForProductId(id) for id in ownedProductIds)`. The [tier] field
/// is a fast cache of that maximum.
///
/// In **debug/profile** builds, you can override the tier for testing via
/// [setDebugTier]. The override is **never** persisted to disk and resets on
/// app restart. In **release** builds, the debug override is a no-op.
///
/// Play channel: [PlayBillingService] grants tiers after purchase or restore.
/// Last-known state is cached offline via [ProEntitlementStore].
class ProEntitlement extends ChangeNotifier {
  EntitlementTier _tier = EntitlementTier.free;
  EntitlementTier? _debugOverride; // null = none; never persisted
  EntitlementSource _source = EntitlementSource.none;
  Set<String> _ownedProductIds = {};
  DateTime? _lastReconcileAt;
  bool _lastReconcileOk = false;

  /// Serializes owned-set writes so concurrent stream + reconcile cannot
  /// interleave partial writes.
  Future<void>? _writeChain;

  EntitlementTier get tier => _debugOverride ?? _tier;

  /// Back-compat shim: Pro or Ultra counts as "Pro".
  bool get isPro => tier.isAtLeastPro;

  /// True only for the Ultra tier.
  bool get isUltra => tier.isUltra;

  /// Unmodifiable view of the owned product IDs.
  Set<String> get ownedProductIds => Set.unmodifiable(_ownedProductIds);

  EntitlementSource get source =>
      _debugOverride != null ? EntitlementSource.debug : _source;

  DateTime? get lastReconcileAt => _lastReconcileAt;
  bool get lastReconcileOk => _lastReconcileOk;

  /// Override the tier in debug/profile builds (no-op in release).
  void setDebugTier(EntitlementTier? tier) {
    if (kReleaseMode) return;
    if (_debugOverride == tier) return;
    _debugOverride = tier;
    notifyListeners();
  }

  /// Load last-known entitlement from disk (offline cache). Never throws.
  Future<void> loadCachedEntitlement() async {
    try {
      final data = await ProEntitlementStore.read();
      if (data == null) return;
      final tier = ProEntitlementStore.tierFromData(data);
      final owned = ProEntitlementStore.ownedFromData(data);
      final source = ProEntitlementStore.sourceFromData(data);
      final reconcileAt = ProEntitlementStore.reconcileAtFromData(data);
      final reconcileOk = ProEntitlementStore.reconcileOkFromData(data);
      if (tier == null) return;
      _tier = tier;
      _ownedProductIds = owned;
      _source = source;
      _lastReconcileAt = reconcileAt;
      _lastReconcileOk = reconcileOk;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ProEntitlement] loadCachedEntitlement failed: $e');
      }
    }
  }

  /// **REPLACE** path — only from a **full** ownership snapshot
  /// (Android BillingClient query). Must never be called with a partial
  /// `purchaseStream` batch.
  Future<void> applyOwnedProducts(
    Set<String> ownedProductIds, {
    required EntitlementSource source,
    required bool reconcileSucceeded,
  }) =>
      _enqueueWrite(() async {
        final previousOwned = _ownedProductIds;
        final previousTier = _tier;
        final previousSource = _source;
        _ownedProductIds = {...ownedProductIds};
        _tier = maxTierForOwned(_ownedProductIds);
        if (reconcileSucceeded) {
          _lastReconcileOk = true;
          _lastReconcileAt = DateTime.now();
        }
        _source = _ownedProductIds.isEmpty ? EntitlementSource.none : source;
        // Upgrade-only arbitrage is surfaced by the caller via the returned
        // flag; here we just persist + notify on change.
        final changed = !_setEquals(previousOwned, _ownedProductIds) ||
            previousTier != _tier ||
            previousSource != _source;
        await ProEntitlementStore.write(
          tier: _tier,
          source: _source,
          ownedProductIds: _ownedProductIds,
          lastReconcileAt: _lastReconcileAt,
          lastReconcileOk: _lastReconcileOk,
        );
        if (changed) notifyListeners();
      });

  /// **UNION** path — single purchase / stream event.
  /// Merges [productId] into the existing owned set (never replaces with a
  /// singleton). Then `tier = maxTierForOwned(union)`.
  Future<void> grantFromProductId(
    String productId, {
    EntitlementSource source = EntitlementSource.play,
  }) =>
      _enqueueWrite(() async {
        final previousOwned = _ownedProductIds;
        final previousTier = _tier;
        final previousSource = _source;
        _ownedProductIds = {..._ownedProductIds, productId};
        _tier = maxTierForOwned(_ownedProductIds);
        _source = source;
        // Do NOT set lastReconcileOk / lastReconcileAt here.
        final changed = !_setEquals(previousOwned, _ownedProductIds) ||
            previousTier != _tier ||
            previousSource != _source;
        await ProEntitlementStore.write(
          tier: _tier,
          source: _source,
          ownedProductIds: _ownedProductIds,
          lastReconcileAt: _lastReconcileAt,
          lastReconcileOk: _lastReconcileOk,
        );
        if (changed) notifyListeners();
      });

  /// Downgrade to free, clear owned set. Used only after a successful
  /// **empty** BillingClient ownership query.
  Future<void> revokeAll() => _enqueueWrite(() async {
        final changed = _tier != EntitlementTier.free || _ownedProductIds.isNotEmpty;
        _tier = EntitlementTier.free;
        _ownedProductIds = {};
        _source = EntitlementSource.none;
        await ProEntitlementStore.write(
          tier: _tier,
          source: _source,
          ownedProductIds: _ownedProductIds,
          lastReconcileAt: _lastReconcileAt,
          lastReconcileOk: _lastReconcileOk,
        );
        if (changed) notifyListeners();
      });

  /// Reconcile attempt failed or used grant-only fallback.
  /// Sets [lastReconcileOk] = false. Does **not** change tier/owned, and does
  /// **not** advance [lastReconcileAt] (timestamp advances only on success).
  Future<void> recordReconcileFailure() => _enqueueWrite(() async {
        _lastReconcileOk = false;
        await ProEntitlementStore.write(
          tier: _tier,
          source: _source,
          ownedProductIds: _ownedProductIds,
          lastReconcileAt: _lastReconcileAt,
          lastReconcileOk: _lastReconcileOk,
        );
      });

  // --- Migration wrappers (same PR-01; deprecate old names) ---

  @Deprecated('Use grantFromProductId / applyOwnedProducts')
  Future<void> grantPro({String source = 'play'}) =>
      grantFromProductId(kAuroraProProductId, source: _parseSource(source));

  @Deprecated('Use revokeAll')
  Future<void> revokePro() => revokeAll();

  // --- internals ---

  Future<void> _enqueueWrite(Future<void> Function() op) {
    final prev = _writeChain;
    final completer = Completer<void>();
    _writeChain = completer.future;
    return prev?.whenComplete(() async {
          try {
            await op();
          } finally {
            completer.complete();
          }
        }) ??
        (() async {
          try {
            await op();
          } finally {
            completer.complete();
          }
        })();
  }

  bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  EntitlementSource _parseSource(String source) {
    switch (source) {
      case 'play':
        return EntitlementSource.play;
      case 'legacy':
        return EntitlementSource.legacy;
      case 'cache':
        return EntitlementSource.cache;
      case 'debug':
        return EntitlementSource.debug;
      default:
        return EntitlementSource.none;
    }
  }
}
