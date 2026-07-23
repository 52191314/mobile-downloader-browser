import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import '../logging/aurora_log.dart';
import 'build_channel.dart';
import 'local_funnel_store.dart';
import 'pro_entitlement.dart';

/// Optional hook for local funnel analytics (wired by PR-04b). Kept as a
/// static callback so PR-03 has no hard dependency on [LocalFunnelStore].
void Function(String event, {Map<String, dynamic>? props})? auroraFunnelRecorder =
    (event, {props}) => LocalFunnelStore.record(event, props: props);

/// Wraps Google Play Billing for the Play channel only.
///
/// GitHub builds construct this service but [isAvailable] stays false and
/// purchase/restore are no-ops so free-tier gates still apply without
/// external checkout links.
///
/// Three one-time SKUs are supported: Pro ($1.99), Ultra ($9.99), and the
/// Pro→Ultra upgrade ($7.99). The upgrade SKU is **hard-gated** to Pro owners
/// on honest clients; if a purchase of it is observed anyway (e.g. patched
/// client / Console misconfig), we still grant Ultra and record the
/// `upgrade_arbitrage` funnel event.
class PlayBillingService {
  PlayBillingService(this.entitlement);

  final ProEntitlement entitlement;

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  bool _initialized = false;
  bool _storeAvailable = false;
  ProductDetails? _proProduct;
  ProductDetails? _ultraProduct;
  ProductDetails? _ultraUpgradeProduct;
  String? _lastError;

  /// Compile-time kill-switch for Ultra CTAs until Play Console is ready.
  static const bool _ultraUiDisabled = bool.fromEnvironment(
    'AURORA_DISABLE_ULTRA_UI',
    defaultValue: false,
  );

  bool get isAvailable =>
      BuildChannel.isPlay && _storeAvailable && _proProduct != null;

  bool get storeAvailable => _storeAvailable;
  ProductDetails? get proProduct => _proProduct;
  ProductDetails? get ultraProduct => _ultraProduct;
  ProductDetails? get ultraUpgradeProduct => _ultraUpgradeProduct;
  String? get lastError => _lastError;

  /// Pro sees the upgrade CTA when the upgrade SKU is loaded.
  bool get showUltraUpgrade =>
      entitlement.tier == EntitlementTier.pro &&
      ultraUpgradeProduct != null &&
      !_ultraUiDisabled;

  /// Full-price Ultra CTA:
  /// - free: always when the Ultra product is loaded.
  /// - pro: **fallback** when the upgrade SKU is missing/inactive but the
  ///   full Ultra product is live (Console misconfig must not leave Pro with
  ///   zero Ultra CTA).
  bool get showUltraFull =>
      ultraProduct != null &&
      !_ultraUiDisabled &&
      (entitlement.tier == EntitlementTier.free ||
          (entitlement.tier == EntitlementTier.pro &&
              ultraUpgradeProduct == null));

  String? get localizedProPrice => _proProduct?.price;
  String? get localizedUltraPrice => _ultraProduct?.price;
  String? get localizedUltraUpgradePrice => _ultraUpgradeProduct?.price;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Always restore last-known cache (works offline; GitHub builds may
    // still load a cached grant if the user migrated, but GitHub does not
    // sell Pro in-app).
    await entitlement.loadCachedEntitlement();

    if (!BuildChannel.isPlay) {
      AuroraLog.instance.info(
        'PlayBilling skipped (channel=${BuildChannel.label})',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.stateChange,
      );
      return;
    }

    try {
      _storeAvailable = await _iap.isAvailable();
    } catch (e, s) {
      _storeAvailable = false;
      _lastError = e.toString();
      AuroraLog.instance.error(
        'PlayBilling isAvailable failed: $e',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.error,
        stackTrace: s,
      );
      return;
    }

    if (!_storeAvailable) {
      _lastError = 'Play Store billing unavailable on this device.';
      return;
    }

    _purchaseSub = _iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (Object e, StackTrace s) {
        _lastError = e.toString();
        AuroraLog.instance.error(
          'PlayBilling purchaseStream error: $e',
          category: LogCategory.app,
          screen: LogScreen.settings,
          eventType: LogEventType.error,
          stackTrace: s,
        );
      },
    );

    await _queryProducts();
    // Deliver any unconsumed/pending purchases (restore path on cold start).
    await reconcileEntitlements(reason: 'cold_start');
  }

  Future<void> _queryProducts() async {
    final response = await _iap.queryProductDetails({
      kAuroraProProductId,
      kAuroraUltraProductId,
      kAuroraUltraUpgradeProductId,
    });
    if (response.error != null) {
      _lastError = response.error!.message;
      AuroraLog.instance.warn(
        'PlayBilling queryProductDetails: ${response.error}',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.error,
      );
    }
    ProductDetails? find(String id) {
      try {
        return response.productDetails.firstWhere((p) => p.id == id);
      } on StateError {
        return null;
      }
    }

    _proProduct = find(kAuroraProProductId);
    _ultraProduct = find(kAuroraUltraProductId);
    _ultraUpgradeProduct = find(kAuroraUltraUpgradeProductId);

    if (_proProduct == null) {
      _lastError ??= 'Product $kAuroraProProductId not found. '
          'Create it in Play Console.';
    } else {
      _lastError = null;
    }
  }

  Future<void> refreshProducts() => _queryProducts();

  // -------------------------------------------------------------------------
  // Purchases
  // -------------------------------------------------------------------------

  /// Launch the one-time Pro purchase sheet.
  Future<bool> buyPro() => _buy(_proProduct, kAuroraProProductId);

  /// Launch the full-price Ultra purchase. Free **or** Pro may buy (Pro uses
  /// this when the upgrade SKU is unavailable).
  Future<bool> buyUltra() => _buy(_ultraProduct, kAuroraUltraProductId);

  /// HARD GATE: returns false without launching the Play sheet unless the
  /// current tier is Pro. Preferred: also require the Pro SKU in the owned
  /// set when the owned set is non-empty (post-reconcile). Residual risk:
  /// a patched APK can call buyNonConsumable directly — accepted (GPL honor).
  Future<bool> buyUltraUpgrade() async {
    if (!BuildChannel.isPlay) {
      _lastError =
          'Aurora Ultra is sold only through the Google Play edition of this app.';
      return false;
    }
    if (entitlement.tier != EntitlementTier.pro) {
      _lastError = 'Upgrade is only available to Aurora Pro owners.';
      return false;
    }
    if (entitlement.ownedProductIds.isNotEmpty &&
        !entitlement.ownedProductIds.contains(kAuroraProProductId)) {
      // Owned set is populated but lacks Pro — refuse to avoid double-pay
      // confusion. The user can still buy full Ultra.
      _lastError = 'Upgrade is only available to Aurora Pro owners.';
      return false;
    }
    return _buy(_ultraUpgradeProduct, kAuroraUltraUpgradeProductId);
  }

  Future<bool> _buy(ProductDetails? product, String productId) async {
    if (!BuildChannel.isPlay) {
      _lastError =
          'Aurora is sold only through the Google Play edition of this app.';
      return false;
    }
    if (!_storeAvailable) {
      _lastError = 'Play Store billing is not available.';
      return false;
    }
    if (product == null) {
      await _queryProducts();
    }
    final resolved = product ?? _productById(productId);
    if (resolved == null) {
      _lastError = 'Could not load product $productId from Play Console.';
      return false;
    }

    final param = PurchaseParam(productDetails: resolved);
    try {
      final ok = await _iap.buyNonConsumable(purchaseParam: param);
      if (!ok) _lastError = 'Purchase was not started.';
      return ok;
    } catch (e, s) {
      _lastError = e.toString();
      AuroraLog.instance.error(
        'PlayBilling buy($productId) failed: $e',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.error,
        stackTrace: s,
      );
      return false;
    }
  }

  ProductDetails? _productById(String id) {
    switch (id) {
      case kAuroraProProductId:
        return _proProduct;
      case kAuroraUltraProductId:
        return _ultraProduct;
      case kAuroraUltraUpgradeProductId:
        return _ultraUpgradeProduct;
    }
    return null;
  }

  Future<void> restorePurchases() async {
    await reconcileEntitlements(reason: 'user_restore');
  }

  // -------------------------------------------------------------------------
  // Purchase stream (GRANT-ONLY, UNION)
  // -------------------------------------------------------------------------

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (!kAllProductIds.contains(purchase.productID)) continue;

      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // UNION grant only — never applyOwnedProducts(partialBatch).
          await entitlement.grantFromProductId(purchase.productID);
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          _lastError = null;
          auroraFunnelRecorder?.call(
            'upsell_accepted',
            props: {'product': purchase.productID},
          );
          break;
        case PurchaseStatus.pending:
          // Wait for a terminal update.
          break;
        case PurchaseStatus.error:
          _lastError = purchase.error?.message ?? 'Purchase error';
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          break;
        case PurchaseStatus.canceled:
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          break;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Reconcile (BillingClient ownership query may REVOKE; fallback is
  // GRANT-ONLY and never revokes)
  // -------------------------------------------------------------------------

  /// Reconcile entitlements from the authoritative Play ownership state.
  ///
  /// Only a definitive Android BillingClient ownership query may set
  /// `querySucceeded=true` and therefore may downgrade. The restore+settle
  /// fallback is GRANT-ONLY: an empty settle window does **not** mean the
  /// user owns nothing, so it never revokes.
  Future<void> reconcileEntitlements({required String reason}) async {
    if (!BuildChannel.isPlay) return;
    if (!_storeAvailable) {
      await entitlement.recordReconcileFailure();
      return; // keep cache; do not revoke
    }

    try {
      // (1) Android BillingClient ownership query — MANDATORY for any path
      //     that may REVOKE / REPLACE the owned set. If this succeeds we
      //     return early. If it throws or returns an error we fall through to
      //     the GRANT-ONLY fallback below (never revoke).
      bool usedBillingClient = false;
      try {
        final addition =
            _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
        final result = await addition.queryPastPurchases();
        if (result.error != null) {
          await entitlement.recordReconcileFailure();
        } else {
          usedBillingClient = true;
          final owned = <String>{
            for (final p in result.pastPurchases)
              if (kAllProductIds.contains(p.productID) &&
                  (p.status == PurchaseStatus.purchased ||
                      p.status == PurchaseStatus.restored))
                p.productID,
          };
          // Complete any pending purchases discovered.
          for (final p in result.pastPurchases) {
            if (p.pendingCompletePurchase) {
              try {
                await _iap.completePurchase(p);
              } catch (e) {
                AuroraLog.instance.warn(
                  'PlayBilling completePurchase failed: $e',
                  category: LogCategory.app,
                  screen: LogScreen.settings,
                  eventType: LogEventType.error,
                );
              }
            }
          }

          final previousOwned = entitlement.ownedProductIds;
          await entitlement.applyOwnedProducts(
            owned,
            source: EntitlementSource.play,
            reconcileSucceeded: true, // may free if owned empty
          );

          if (owned.contains(kAuroraUltraUpgradeProductId) &&
              !previousOwned.contains(kAuroraUltraUpgradeProductId)) {
            auroraFunnelRecorder?.call('upgrade_arbitrage');
          }
          return;
        }
      } catch (e, s) {
        // BillingClient unavailable / threw — fall through to grant-only.
        AuroraLog.instance.warn(
          'PlayBilling BillingClient query failed, using fallback: $e',
          category: LogCategory.app,
          screen: LogScreen.settings,
          eventType: LogEventType.error,
          stackTrace: s,
        );
      }

      if (usedBillingClient) return; // BC ran but reported error; keep cache.

      // (2) FALLBACK: restorePurchases() + stream settle (~10s).
      //     GRANT-ONLY. querySucceeded is ALWAYS false here. Empty settle ≠
      //     ownership empty — NEVER revoke / NEVER applyOwnedProducts.
      await _iap.restorePurchases();
      final settleTimeout = const Duration(seconds: 10);
      final collected = <PurchaseDetails>[];
      final done = Completer<void>();
      late final StreamSubscription<List<PurchaseDetails>> sub;
      sub = _iap.purchaseStream.listen(
        (events) {
          for (final e in events) {
            if (kAllProductIds.contains(e.productID)) collected.add(e);
          }
        },
        onError: (_) => done.complete(),
      );
      await Future.any([
        Future.delayed(settleTimeout, () => done.complete()),
        done.future,
      ]);
      await sub.cancel();

      for (final e in collected) {
        if (e.status == PurchaseStatus.purchased ||
            e.status == PurchaseStatus.restored) {
          await entitlement.grantFromProductId(e.productID); // UNION grant
        }
      }
      await entitlement.recordReconcileFailure(); // not authoritative
      AuroraLog.instance.info(
        'reconcile used grant-only restore fallback (reason=$reason)',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.stateChange,
      );
    } catch (e, s) {
      await entitlement.recordReconcileFailure();
      AuroraLog.instance.error(
        'PlayBilling reconcile failed: $e',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.error,
        stackTrace: s,
      );
      // never revoke
    }
  }

  Future<void> dispose() async {
    await _purchaseSub?.cancel();
    _purchaseSub = null;
  }
}
