import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

import '../logging/aurora_log.dart';
import 'build_channel.dart';
import 'pro_entitlement.dart';

/// One-time Play product that unlocks Aurora Pro.
const String kAuroraProProductId = 'aurora_pro_unlock';

/// Wraps Google Play Billing for the Play channel only.
///
/// GitHub builds construct this service but [isAvailable] stays false and
/// purchase/restore are no-ops so free-tier gates still apply without
/// external checkout links.
class PlayBillingService {
  PlayBillingService(this.entitlement);

  final ProEntitlement entitlement;

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  bool _initialized = false;
  bool _storeAvailable = false;
  ProductDetails? _proProduct;
  String? _lastError;

  bool get isAvailable =>
      BuildChannel.isPlay && _storeAvailable && _proProduct != null;

  bool get storeAvailable => _storeAvailable;
  ProductDetails? get proProduct => _proProduct;
  String? get lastError => _lastError;
  String get productId => kAuroraProProductId;

  /// Price string from the store (e.g. "$4.99") or null if unknown.
  String? get localizedPrice => _proProduct?.price;

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
    await _iap.restorePurchases();
  }

  Future<void> _queryProducts() async {
    final response = await _iap.queryProductDetails({kAuroraProProductId});
    if (response.error != null) {
      _lastError = response.error!.message;
      AuroraLog.instance.warn(
        'PlayBilling queryProductDetails: ${response.error}',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.error,
      );
    }
    if (response.productDetails.isEmpty) {
      _proProduct = null;
      _lastError ??=
          'Product $kAuroraProProductId not found. Create it in Play Console.';
      return;
    }
    _proProduct = response.productDetails.first;
    _lastError = null;
  }

  Future<void> refreshProducts() => _queryProducts();

  /// Launch the one-time purchase sheet. Returns false if billing cannot run.
  Future<bool> buyPro() async {
    if (!BuildChannel.isPlay) {
      _lastError =
          'Aurora Pro is sold only through the Google Play edition of this app.';
      return false;
    }
    if (!_storeAvailable) {
      _lastError = 'Play Store billing is not available.';
      return false;
    }
    if (_proProduct == null) {
      await _queryProducts();
    }
    final product = _proProduct;
    if (product == null) {
      _lastError =
          'Could not load product $kAuroraProProductId from Play Console.';
      return false;
    }

    final param = PurchaseParam(productDetails: product);
    try {
      // Non-consumable one-time unlock.
      final ok = await _iap.buyNonConsumable(purchaseParam: param);
      if (!ok) {
        _lastError = 'Purchase was not started.';
      }
      return ok;
    } catch (e, s) {
      _lastError = e.toString();
      AuroraLog.instance.error(
        'PlayBilling buyPro failed: $e',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.error,
        stackTrace: s,
      );
      return false;
    }
  }

  Future<void> restorePurchases() async {
    if (!BuildChannel.isPlay) {
      _lastError =
          'Restore is only available on the Google Play edition of this app.';
      return;
    }
    if (!_storeAvailable) {
      _lastError = 'Play Store billing is not available.';
      return;
    }
    try {
      await _iap.restorePurchases();
    } catch (e, s) {
      _lastError = e.toString();
      AuroraLog.instance.error(
        'PlayBilling restore failed: $e',
        category: LogCategory.app,
        screen: LogScreen.settings,
        eventType: LogEventType.error,
        stackTrace: s,
      );
    }
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID != kAuroraProProductId) continue;

      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await entitlement.grantPro(source: 'play');
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          _lastError = null;
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

  Future<void> dispose() async {
    await _purchaseSub?.cancel();
    _purchaseSub = null;
  }
}
