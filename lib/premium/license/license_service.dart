import 'dart:async';

import 'package:flutter/foundation.dart';

import '../pro_entitlement.dart';
import 'aurora_license.dart';
import 'install_id_store.dart';
import 'license_api_client.dart';
import 'license_config.dart';
import 'license_store.dart';

/// Where the app's entitlement currently stands relative to the license host.
enum LicenseState {
  /// Licensing is not configured for this build — the app uses Play's
  /// client-side answer exactly as it did before this system existed.
  disabled,

  /// Not loaded yet.
  unknown,

  /// A signed, unexpired license for this install is held.
  licensed,

  /// No license yet, but this install owned Pro/Ultra before licensing shipped
  /// and is inside the one-time migration window (plan section 15, gap 4).
  legacyGrace,

  /// A license was held and has run out of offline grace without a refresh.
  expired,

  /// The server says nothing is owned.
  unlicensed,

  /// A previously valid purchase was refunded or revoked.
  revoked,
}

/// Server-side entitlement for the Play channel.
///
/// Responsibilities, in the order they happen:
///
/// 1. **Cold start** — [load] reads the cached JWT and validates it offline.
/// 2. **Purchase / restore** — [activate] trades Play purchase tokens for a
///    signed license.
/// 3. **Upkeep** — [refreshIfDue] re-checks with the server roughly daily,
///    which is what catches refunds.
///
/// Two invariants run through all of it:
///
/// - A **transient** failure (offline, timeout, 5xx) must never downgrade a
///   paying user. Only an authoritative denial or an expired license does.
/// - The app never trusts a tier the server did not sign. `pro_entitlement.json`
///   remains a cache for *products owned*, not a grant of entitlement.
class LicenseService extends ChangeNotifier {
  /// [enabled], [packageName], [legacyGraceDays] and [installIdProvider] exist
  /// so tests can drive the service without dart-defines or platform plugins.
  /// Production code passes none of them and inherits [LicenseConfig].
  LicenseService({
    required this.entitlement,
    LicenseApiClient? apiClient,
    LicenseStore store = const LicenseStore(),
    LicenseVerifier verifier = const LicenseVerifier(),
    DateTime Function()? clock,
    bool? enabled,
    String? packageName,
    int? legacyGraceDays,
    Future<String> Function()? installIdProvider,
  })  : _api = apiClient ?? LicenseApiClient(),
        _store = store,
        _verifier = verifier,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _enabledOverride = enabled,
        _packageName = packageName ?? LicenseConfig.packageName,
        _legacyGraceDays = legacyGraceDays ?? LicenseConfig.legacyGraceDays,
        _installIdProvider = installIdProvider ?? InstallIdStore.get;

  final ProEntitlement entitlement;
  final LicenseApiClient _api;
  final LicenseStore _store;
  final LicenseVerifier _verifier;
  final DateTime Function() _clock;
  final bool? _enabledOverride;
  final String _packageName;
  final int _legacyGraceDays;
  final Future<String> Function() _installIdProvider;

  /// Called when the server has no record of this install and the app needs to
  /// re-send a full Play ownership snapshot. Wired to
  /// `PlayBillingService.reconcileEntitlements`.
  Future<void> Function()? onReactivationNeeded;

  LicenseState _state = LicenseState.unknown;
  AuroraLicense? _license;
  LicenseCacheData _cache = const LicenseCacheData();
  String? _installId;
  bool _busy = false;
  bool _reactivating = false;

  LicenseState get state => _state;
  AuroraLicense? get license => _license;
  bool get isBusy => _busy;
  String? get installId => _installId;
  DateTime? get lastRefreshAt => _cache.lastRefreshAt;
  DateTime? get expiresAt => _license?.expiresAt;

  bool get isEnabled => _enabledOverride ?? LicenseConfig.isEnabled;

  /// Tier the license grants, or null when there is no valid license.
  EntitlementTier? get licensedTier {
    switch (_state) {
      case LicenseState.licensed:
        return _license?.tier;
      case LicenseState.legacyGrace:
        return entitlement.storeTier;
      case LicenseState.disabled:
      case LicenseState.unknown:
      case LicenseState.expired:
      case LicenseState.unlicensed:
      case LicenseState.revoked:
        return null;
    }
  }

  /// User-facing explanation, or null when nothing needs saying.
  ///
  /// Plan section 11: a user whose license lapsed while the host was down must
  /// be told why, not silently dropped to free.
  String? get statusMessage {
    switch (_state) {
      case LicenseState.expired:
        return "Couldn't verify your purchase recently. Connect to the "
            'internet and open Settings to restore it.';
      case LicenseState.revoked:
        return 'This purchase is no longer active on your Google account.';
      case LicenseState.unlicensed:
        return entitlement.storeTier == EntitlementTier.free
            ? null
            : "Couldn't verify your purchase yet. Tap Restore purchase.";
      case LicenseState.disabled:
      case LicenseState.unknown:
      case LicenseState.licensed:
      case LicenseState.legacyGrace:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Cold start
  // ---------------------------------------------------------------------------

  /// Load and validate the cached license.
  ///
  /// Call **after** `ProEntitlement.loadCachedEntitlement()` so the migration
  /// window can see whether this install already owned something.
  Future<void> load() async {
    if (!isEnabled) {
      _state = LicenseState.disabled;
      entitlement.applyLicensedTier(null, gating: false);
      _log(
        'license gating off (${LicenseConfig.disabledReason})',
        level: _LogLevel.info,
      );
      notifyListeners();
      return;
    }

    _installId = await _installIdProvider();
    _cache = await _store.read();

    // A cache issued to a different install (restored backup, cleared data)
    // is unusable — its `sub` will never match.
    if (_cache.installId != null && _cache.installId != _installId) {
      _cache = _cache.copyWith(clearLicense: true, installId: _installId);
      await _store.write(_cache);
      _log(
        'discarded license bound to a previous install',
        level: _LogLevel.warn,
      );
    }

    await _maybeOpenLegacyGrace();
    _evaluate();
  }

  /// Grant users who already owned Pro/Ultra before licensing shipped a bounded
  /// window to backfill a real license, instead of dropping them to free on
  /// update day (plan section 15, gap 4).
  Future<void> _maybeOpenLegacyGrace() async {
    if (_cache.license != null) return;
    if (_cache.legacyGraceUntil != null) return;
    // Licensed successfully at some point, so this is not a migration case.
    if (_cache.lastRefreshAt != null) return;
    if (entitlement.storeTier == EntitlementTier.free) return;

    final until = _clock().add(Duration(days: _legacyGraceDays));
    _cache = _cache.copyWith(installId: _installId, legacyGraceUntil: until);
    await _store.write(_cache);
    _log(
      'opened migration grace for existing ${entitlement.storeTier.name} owner '
      'until ${until.toIso8601String()}',
      level: _LogLevel.info,
    );
  }

  /// Recompute [state] from the cached JWT + grace window, and push the
  /// resulting tier into [ProEntitlement].
  void _evaluate() {
    final now = _clock();
    final installId = _installId;
    final raw = _cache.license;

    if (raw != null && installId != null) {
      final result = _verifier.verify(raw, installId: installId, now: now);
      if (result.isValid) {
        _license = result.license;
        _state = LicenseState.licensed;
        _publish();
        return;
      }
      _license = null;
      final rejection = result.rejection;
      if (rejection == LicenseRejection.expired) {
        _state = LicenseState.expired;
        _log('cached license expired', level: _LogLevel.warn);
      } else {
        // Anything other than expiry means the blob is not one we can trust —
        // a tampered file, or a key we no longer ship.
        _state = LicenseState.unlicensed;
        _log(
          'cached license rejected: ${rejection?.name}',
          level: _LogLevel.warn,
        );
      }
      _publish();
      return;
    }

    _license = null;
    if (_legacyGraceActive(now)) {
      _state = LicenseState.legacyGrace;
    } else if (_state != LicenseState.revoked) {
      _state = LicenseState.unlicensed;
    }
    _publish();
  }

  bool _legacyGraceActive(DateTime now) {
    final until = _cache.legacyGraceUntil;
    if (until == null) return false;
    if (!now.isBefore(until)) return false;
    return entitlement.storeTier != EntitlementTier.free;
  }

  void _publish() {
    entitlement.applyLicensedTier(licensedTier, gating: true);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Activate (after purchase / restore)
  // ---------------------------------------------------------------------------

  /// Trade Play purchase tokens for a signed license.
  ///
  /// Safe to call with a partial batch: the server unions the submitted tokens
  /// with everything already linked to this install, so activating only the
  /// Ultra-upgrade SKU still resolves to Ultra alongside the earlier Pro
  /// purchase.
  ///
  /// Returns true when a license was issued.
  Future<bool> activate(
    List<PlayPurchase> purchases, {
    required String reason,
  }) async {
    if (!isEnabled) return false;
    if (purchases.isEmpty) {
      // An empty snapshot is not evidence of anything — never treat it as a
      // denial, or a signed-out Play account would revoke a paying user.
      _log(
        'activate skipped: no purchase tokens ($reason)',
        level: _LogLevel.info,
      );
      return false;
    }
    final installId = _installId ??= await _installIdProvider();

    _setBusy(true);
    try {
      final result = await _api.activate(
        packageName: _packageName,
        installId: installId,
        purchases: purchases,
      );
      _log(
        'activate($reason) -> ${result.outcome.name}'
        '${result.errorCode != null ? ' [${result.errorCode}]' : ''}',
        level: result.outcome == LicenseApiOutcome.ok
            ? _LogLevel.info
            : _LogLevel.warn,
      );
      return await _applyResult(result);
    } finally {
      _setBusy(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Refresh (upkeep + refund detection)
  // ---------------------------------------------------------------------------

  /// Re-check entitlement with the server when enough time has passed.
  ///
  /// [force] bypasses the schedule (used by the explicit "Restore purchase"
  /// action). Failures are silent and non-destructive.
  Future<void> refreshIfDue({bool force = false}) async {
    if (!isEnabled) return;
    if (_busy) return;
    final now = _clock();
    if (!force && !_isRefreshDue(now)) return;

    final installId = _installId ??= await _installIdProvider();

    _setBusy(true);
    try {
      final result = await _api.refresh(
        packageName: _packageName,
        installId: installId,
      );
      _log(
        'refresh -> ${result.outcome.name}'
        '${result.errorCode != null ? ' [${result.errorCode}]' : ''}',
        level: result.outcome == LicenseApiOutcome.ok
            ? _LogLevel.info
            : _LogLevel.warn,
      );

      if (result.outcome == LicenseApiOutcome.unknownInstall) {
        await _recordAttempt(result);
        await _requestReactivation();
        return;
      }
      await _applyResult(result);
    } finally {
      _setBusy(false);
    }
  }

  bool _isRefreshDue(DateTime now) {
    // Never licensed and no grace to lose — nothing to refresh against.
    if (_cache.license == null &&
        _cache.lastRefreshAt == null &&
        _state != LicenseState.legacyGrace) {
      return false;
    }
    final lastAttempt = _cache.lastAttemptAt;
    final lastSuccess = _cache.lastRefreshAt;
    if (lastSuccess != null &&
        now.difference(lastSuccess) < LicenseConfig.refreshInterval) {
      return false;
    }
    if (lastAttempt != null &&
        now.difference(lastAttempt) < LicenseConfig.retryInterval) {
      return false;
    }
    return true;
  }

  Future<void> _requestReactivation() async {
    final callback = onReactivationNeeded;
    if (callback == null || _reactivating) return;
    _reactivating = true;
    try {
      await callback();
    } catch (e) {
      _log('reactivation callback failed: $e', level: _LogLevel.warn);
    } finally {
      _reactivating = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Result handling
  // ---------------------------------------------------------------------------

  Future<bool> _applyResult(LicenseApiResult result) async {
    final now = _clock();

    switch (result.outcome) {
      case LicenseApiOutcome.ok:
        final raw = result.license!;
        final installId = _installId!;
        // Verify what the server just handed us. If it does not check out, the
        // server is signing with a key this build does not trust — usually a
        // rotation shipped in the wrong order. Keep the old license.
        final verified = _verifier.verify(raw, installId: installId, now: now);
        if (!verified.isValid) {
          _log(
            'server license failed verification (${verified.rejection?.name}) — '
            'keeping previous license',
            level: _LogLevel.error,
          );
          await _recordAttempt(result);
          return false;
        }
        _license = verified.license;
        _state = LicenseState.licensed;
        _cache = _cache.copyWith(
          license: raw,
          installId: installId,
          lastRefreshAt: now,
          lastAttemptAt: now,
          lastOutcome: 'ok',
          clearLegacyGrace: true, // migration complete
        );
        await _store.write(_cache);
        _publish();
        return true;

      case LicenseApiOutcome.noValidPurchase:
      case LicenseApiOutcome.revoked:
        // Authoritative: Google says this account owns nothing.
        _license = null;
        _state = result.outcome == LicenseApiOutcome.revoked
            ? LicenseState.revoked
            : LicenseState.unlicensed;
        _cache = _cache.copyWith(
          clearLicense: true,
          installId: _installId,
          lastAttemptAt: now,
          lastOutcome: result.errorCode ?? 'denied',
          clearLegacyGrace: true,
        );
        await _store.write(_cache);
        _publish();
        return false;

      case LicenseApiOutcome.unknownInstall:
      case LicenseApiOutcome.rejected:
      case LicenseApiOutcome.transient:
        // Keep whatever we have. The cached license carries the user until it
        // expires; that is exactly what the offline grace window is for.
        await _recordAttempt(result);
        return false;
    }
  }

  Future<void> _recordAttempt(LicenseApiResult result) async {
    _cache = _cache.copyWith(
      installId: _installId,
      lastAttemptAt: _clock(),
      lastOutcome: result.errorCode ?? result.outcome.name,
    );
    await _store.write(_cache);
  }

  void _setBusy(bool value) {
    if (_busy == value) return;
    _busy = value;
    notifyListeners();
  }

  /// Wipe local license state. Used by tests and "sign out"-style flows.
  Future<void> clear() async {
    _license = null;
    _cache = const LicenseCacheData();
    _state = isEnabled ? LicenseState.unlicensed : LicenseState.disabled;
    await _store.clear();
    _publish();
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  void _log(String message, {required _LogLevel level}) {
    switch (level) {
      case _LogLevel.info:
        debugPrint('[License] $message');
      case _LogLevel.warn:
        debugPrint('[License] $message');
      case _LogLevel.error:
        debugPrint('[License] $message');
    }
  }
}

enum _LogLevel { info, warn, error }
