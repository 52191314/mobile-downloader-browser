import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../pro_entitlement.dart';
import 'license_config.dart';

/// Why a license blob was rejected. Never shown raw to users — logged only.
enum LicenseRejection {
  malformed,
  unsupportedAlgorithm,
  unknownKey,
  badSignature,
  wrongIssuer,
  wrongAudience,
  wrongInstall,
  expired,
  unknownTier,
}

/// A verified license. Constructing one outside [LicenseVerifier] is not
/// possible by design — if you hold an [AuroraLicense], the signature and all
/// claims were checked.
class AuroraLicense {
  const AuroraLicense._({
    required this.raw,
    required this.keyId,
    required this.tier,
    required this.products,
    required this.installId,
    required this.packageName,
    required this.jti,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String raw;
  final String keyId;
  final EntitlementTier tier;
  final Set<String> products;
  final String installId;
  final String packageName;
  final String jti;
  final DateTime issuedAt;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  Duration remainingAt(DateTime now) =>
      isExpiredAt(now) ? Duration.zero : expiresAt.difference(now);

  @override
  String toString() =>
      'AuroraLicense(tier: ${tier.name}, kid: $keyId, exp: '
      '${expiresAt.toIso8601String()})';
}

/// Result of a verification attempt.
class LicenseVerificationResult {
  const LicenseVerificationResult.valid(this.license)
      : rejection = null;
  const LicenseVerificationResult.invalid(this.rejection) : license = null;

  final AuroraLicense? license;
  final LicenseRejection? rejection;

  bool get isValid => license != null;
}

/// Verifies RS256 license blobs against the keys compiled into the app.
///
/// Every one of these checks matters:
/// - **signature** — proves the server issued it.
/// - **`kid`** — must be a key we ship; an attacker cannot introduce their own.
/// - **`iss` / `aud`** — stops a token minted for something else being replayed.
/// - **`sub` == our install id** — without this, one buyer's license file
///   unlocks every device it is copied to, which defeats the whole system.
/// - **`exp`** — the offline grace window.
class LicenseVerifier {
  const LicenseVerifier({List<LicensePublicKey>? keys, this.clockSkew = const Duration(minutes: 2)})
      : _overrideKeys = keys;

  final List<LicensePublicKey>? _overrideKeys;

  /// Tolerance applied to `exp` only, for device clocks that run fast.
  final Duration clockSkew;

  List<LicensePublicKey> get _keys => _overrideKeys ?? LicenseConfig.trustedKeys;

  LicenseVerificationResult verify(
    String jwt, {
    required String installId,
    required DateTime now,
    String issuer = LicenseConfig.issuer,
    String audience = LicenseConfig.audience,
  }) {
    final parts = jwt.split('.');
    if (parts.length != 3) {
      return const LicenseVerificationResult.invalid(LicenseRejection.malformed);
    }

    final Map<String, dynamic> header;
    final Map<String, dynamic> payload;
    try {
      header = _decodeJsonSegment(parts[0]);
      payload = _decodeJsonSegment(parts[1]);
    } catch (_) {
      return const LicenseVerificationResult.invalid(LicenseRejection.malformed);
    }

    // Reject "alg": "none" and any algorithm swap outright.
    if (header['alg'] != 'RS256') {
      return const LicenseVerificationResult.invalid(
        LicenseRejection.unsupportedAlgorithm,
      );
    }

    final kid = header['kid'];
    if (kid is! String || kid.isEmpty) {
      return const LicenseVerificationResult.invalid(LicenseRejection.unknownKey);
    }
    LicensePublicKey? key;
    for (final candidate in _keys) {
      if (candidate.kid == kid) {
        key = candidate;
        break;
      }
    }
    if (key == null) {
      return const LicenseVerificationResult.invalid(LicenseRejection.unknownKey);
    }

    final Uint8List signature;
    try {
      signature = _base64UrlDecode(parts[2]);
    } catch (_) {
      return const LicenseVerificationResult.invalid(LicenseRejection.malformed);
    }

    final signedBytes =
        Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}'));
    if (!_verifyRs256(signedBytes, signature, key)) {
      return const LicenseVerificationResult.invalid(
        LicenseRejection.badSignature,
      );
    }

    // --- claims (only meaningful once the signature checks out) ---

    if (payload['iss'] != issuer) {
      return const LicenseVerificationResult.invalid(
        LicenseRejection.wrongIssuer,
      );
    }
    if (!_audienceMatches(payload['aud'], audience)) {
      return const LicenseVerificationResult.invalid(
        LicenseRejection.wrongAudience,
      );
    }
    if (payload['sub'] != installId) {
      return const LicenseVerificationResult.invalid(
        LicenseRejection.wrongInstall,
      );
    }

    final exp = payload['exp'];
    if (exp is! int) {
      return const LicenseVerificationResult.invalid(LicenseRejection.malformed);
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      exp * 1000,
      isUtc: true,
    );
    if (!now.subtract(clockSkew).isBefore(expiresAt)) {
      return const LicenseVerificationResult.invalid(LicenseRejection.expired);
    }

    final tier = _tierFromName(payload['tier']);
    if (tier == null || tier == EntitlementTier.free) {
      return const LicenseVerificationResult.invalid(
        LicenseRejection.unknownTier,
      );
    }

    final iat = payload['iat'];
    final issuedAt = iat is int
        ? DateTime.fromMillisecondsSinceEpoch(iat * 1000, isUtc: true)
        : expiresAt;

    final rawProducts = payload['products'];
    final products = <String>{
      if (rawProducts is List)
        for (final p in rawProducts)
          if (p is String) p,
    };

    return LicenseVerificationResult.valid(
      AuroraLicense._(
        raw: jwt,
        keyId: kid,
        tier: tier,
        products: products,
        installId: installId,
        packageName: payload['pkg'] is String ? payload['pkg'] as String : '',
        jti: payload['jti'] is String ? payload['jti'] as String : '',
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      ),
    );
  }

  static bool _audienceMatches(Object? aud, String expected) {
    if (aud is String) return aud == expected;
    if (aud is List) return aud.contains(expected);
    return false;
  }

  static EntitlementTier? _tierFromName(Object? name) {
    if (name is! String) return null;
    for (final tier in EntitlementTier.values) {
      if (tier.name == name) return tier;
    }
    return null;
  }

  static bool _verifyRs256(
    Uint8List signedBytes,
    Uint8List signature,
    LicensePublicKey key,
  ) {
    try {
      final modulus = _bigIntFromBytes(_base64UrlDecode(key.modulus));
      final exponent = _bigIntFromBytes(_base64UrlDecode(key.exponent));
      final publicKey = RSAPublicKey(modulus, exponent);
      // '0609608648016503040201' is the DER-encoded SHA-256 OID that PKCS#1
      // v1.5 requires inside the signature block.
      final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
      signer.init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
      return signer.verifySignature(signedBytes, RSASignature(signature));
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> _decodeJsonSegment(String segment) {
    final decoded = jsonDecode(utf8.decode(_base64UrlDecode(segment)));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.map((k, v) => MapEntry(k.toString(), v));
    throw const FormatException('JWT segment is not a JSON object');
  }

  static Uint8List _base64UrlDecode(String input) =>
      Uint8List.fromList(base64Url.decode(base64Url.normalize(input)));

  static BigInt _bigIntFromBytes(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }
}
