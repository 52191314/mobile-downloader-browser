import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'license_config.dart';

/// One Play purchase as the client knows it, before the server verifies it.
class PlayPurchase {
  const PlayPurchase({required this.productId, required this.purchaseToken});

  final String productId;
  final String purchaseToken;

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'purchaseToken': purchaseToken,
      };

  @override
  bool operator ==(Object other) =>
      other is PlayPurchase &&
      other.productId == productId &&
      other.purchaseToken == purchaseToken;

  @override
  int get hashCode => Object.hash(productId, purchaseToken);

  /// Purchase tokens must never reach logs or crash reports.
  @override
  String toString() => 'PlayPurchase($productId, token: <redacted>)';
}

/// What the server said, reduced to the outcomes the app acts on.
enum LicenseApiOutcome {
  /// A license was issued.
  ok,

  /// Google says nothing is owned — drop to free.
  noValidPurchase,

  /// A previously valid entitlement is gone (refund) — clear and drop to free.
  revoked,

  /// Server has no record of this install; activate with a full snapshot.
  unknownInstall,

  /// Client-side bug (bad payload, wrong package). Do not retry unchanged.
  rejected,

  /// Network failure, timeout, rate limit, or server fault.
  ///
  /// **Must never downgrade a paying user** — keep the cached license.
  transient,
}

class LicenseApiResult {
  const LicenseApiResult({
    required this.outcome,
    this.license,
    this.tier,
    this.products = const <String>{},
    this.expiresAt,
    this.errorCode,
    this.message,
  });

  final LicenseApiOutcome outcome;
  final String? license;
  final String? tier;
  final Set<String> products;
  final DateTime? expiresAt;
  final String? errorCode;
  final String? message;

  bool get isOk => outcome == LicenseApiOutcome.ok && license != null;

  /// True when the answer is authoritative enough to remove entitlement.
  bool get isDenial =>
      outcome == LicenseApiOutcome.noValidPurchase ||
      outcome == LicenseApiOutcome.revoked;
}

/// Thin HTTP client for the Aurora license service.
///
/// Endpoint contract: `license_server/README.md` §2.
class LicenseApiClient {
  LicenseApiClient({http.Client? httpClient, Duration? timeout})
      : _http = httpClient ?? http.Client(),
        _timeout = timeout ?? LicenseConfig.requestTimeout;

  final http.Client _http;
  final Duration _timeout;

  Future<LicenseApiResult> activate({
    required String packageName,
    required String installId,
    required List<PlayPurchase> purchases,
  }) =>
      _post('/v1/license/activate', {
        'packageName': packageName,
        'installId': installId,
        'purchases': [for (final p in purchases) p.toJson()],
      });

  Future<LicenseApiResult> refresh({
    required String packageName,
    required String installId,
    List<PlayPurchase> purchases = const <PlayPurchase>[],
  }) =>
      _post('/v1/license/refresh', {
        'packageName': packageName,
        'installId': installId,
        if (purchases.isNotEmpty)
          'purchases': [for (final p in purchases) p.toJson()],
      });

  Future<LicenseApiResult> _post(String path, Map<String, dynamic> body) async {
    try {
      final response = await _http
          .post(
            LicenseConfig.endpoint(path),
            headers: const {
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      return _mapResponse(response);
    } on TimeoutException {
      return const LicenseApiResult(
        outcome: LicenseApiOutcome.transient,
        errorCode: 'timeout',
      );
    } on SocketException {
      return const LicenseApiResult(
        outcome: LicenseApiOutcome.transient,
        errorCode: 'offline',
      );
    } on http.ClientException {
      return const LicenseApiResult(
        outcome: LicenseApiOutcome.transient,
        errorCode: 'network',
      );
    } catch (e) {
      return LicenseApiResult(
        outcome: LicenseApiOutcome.transient,
        errorCode: 'unexpected',
        message: e.toString(),
      );
    }
  }

  LicenseApiResult _mapResponse(http.Response response) {
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // Fall through — status code alone decides below.
    }

    if (response.statusCode == 200) {
      final license = json['license'];
      if (license is! String || license.isEmpty) {
        return const LicenseApiResult(
          outcome: LicenseApiOutcome.transient,
          errorCode: 'malformed_response',
        );
      }
      final rawProducts = json['products'];
      return LicenseApiResult(
        outcome: LicenseApiOutcome.ok,
        license: license,
        tier: json['tier'] is String ? json['tier'] as String : null,
        products: {
          if (rawProducts is List)
            for (final p in rawProducts)
              if (p is String) p,
        },
        expiresAt: json['expiresAt'] is String
            ? DateTime.tryParse(json['expiresAt'] as String)
            : null,
      );
    }

    final code = json['error'] is String ? json['error'] as String : null;
    final message = json['message'] is String ? json['message'] as String : null;

    final outcome = switch (code) {
      'no_valid_purchase' => LicenseApiOutcome.noValidPurchase,
      'entitlement_revoked' => LicenseApiOutcome.revoked,
      'unknown_install' => LicenseApiOutcome.unknownInstall,
      'invalid_request' ||
      'invalid_json' ||
      'unknown_product' ||
      'package_not_allowed' =>
        LicenseApiOutcome.rejected,
      // 429 and 5xx are explicitly transient: the user paid, the host is just
      // unhappy right now.
      _ => response.statusCode >= 400 && response.statusCode < 500 &&
              response.statusCode != 429
          ? LicenseApiOutcome.rejected
          : LicenseApiOutcome.transient,
    };

    return LicenseApiResult(
      outcome: outcome,
      errorCode: code ?? 'http_${response.statusCode}',
      message: message,
    );
  }

  void dispose() => _http.close();
}
