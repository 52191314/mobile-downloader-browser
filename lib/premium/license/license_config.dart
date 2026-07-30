import '../build_channel.dart';

/// An RSA public key the app trusts for license signatures.
///
/// [modulus] and [exponent] are the base64url `n` / `e` values straight out of
/// the server's JWKS document — no PEM parsing needed on device.
class LicensePublicKey {
  const LicensePublicKey({
    required this.kid,
    required this.modulus,
    required this.exponent,
  });

  final String kid;
  final String modulus;
  final String exponent;
}

/// Compile-time configuration for server-side license verification.
///
/// **Licensing stays off unless it is fully configured.** [isEnabled] requires
/// the Play channel, a base URL *and* at least one trusted key. A build that
/// ships without those behaves exactly as it did before this system existed —
/// so an update can never brick paying users just because the license host
/// isn't deployed yet.
///
/// See `license_server/README.md` and
/// `docs/server_side_play_entitlement_plan.md`.
class LicenseConfig {
  LicenseConfig._();

  /// e.g. `https://license.example.com`. Empty disables licensing.
  static const String baseUrl = String.fromEnvironment(
    'AURORA_LICENSE_URL',
    defaultValue: '',
  );

  /// Must match the Play listing exactly and be in the server's
  /// `ALLOWED_PACKAGE_NAMES`.
  static const String packageName = String.fromEnvironment(
    'AURORA_PACKAGE_NAME',
    defaultValue: 'com.personal.aurora_downloader',
  );

  static const String issuer = String.fromEnvironment(
    'AURORA_LICENSE_ISSUER',
    defaultValue: 'aurora-license',
  );

  static const String audience = String.fromEnvironment(
    'AURORA_LICENSE_AUDIENCE',
    defaultValue: 'aurora-app',
  );

  /// How long a paid user who predates this system keeps their cached tier
  /// while the app tries to backfill a real license (plan §15 gap 4).
  static const int legacyGraceDays = int.fromEnvironment(
    'AURORA_LICENSE_LEGACY_GRACE_DAYS',
    defaultValue: 14,
  );

  /// Minimum spacing between successful refreshes.
  static const Duration refreshInterval = Duration(hours: 24);

  /// Spacing between retries after a failed refresh — short enough to recover
  /// quickly, long enough not to hammer a struggling host.
  static const Duration retryInterval = Duration(minutes: 30);

  static const Duration requestTimeout = Duration(seconds: 20);

  /// Keys compiled into the binary.
  ///
  /// Populate from `npm run keys:generate` in `license_server/`, which prints
  /// this exact literal. Keep **two** entries during a key rotation so
  /// licenses signed by the outgoing key keep verifying until they expire.
  static const List<LicensePublicKey> _bakedKeys = <LicensePublicKey>[
    // LicensePublicKey(kid: 'aurora-20260725', modulus: '...', exponent: 'AQAB'),
  ];

  // Staging / CI override so a test build can point at a throwaway key
  // without editing source.
  static const String _definedKid = String.fromEnvironment('AURORA_LICENSE_KID');
  static const String _definedModulus =
      String.fromEnvironment('AURORA_LICENSE_KEY_N');
  static const String _definedExponent = String.fromEnvironment(
    'AURORA_LICENSE_KEY_E',
    defaultValue: 'AQAB',
  );

  static List<LicensePublicKey> get trustedKeys => <LicensePublicKey>[
        ..._bakedKeys,
        if (_definedKid.isNotEmpty && _definedModulus.isNotEmpty)
          LicensePublicKey(
            kid: _definedKid,
            modulus: _definedModulus,
            exponent: _definedExponent,
          ),
      ];

  /// True only when licensing is fully configured for a Play build.
  static bool get isEnabled =>
      BuildChannel.isPlay && baseUrl.isNotEmpty && trustedKeys.isNotEmpty;

  static Uri endpoint(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path');
  }

  /// Human-readable reason licensing is inactive (diagnostics only).
  static String get disabledReason {
    if (!BuildChannel.isPlay) return 'not a Play build';
    if (baseUrl.isEmpty) return 'AURORA_LICENSE_URL not set';
    if (trustedKeys.isEmpty) return 'no trusted license keys compiled in';
    return 'enabled';
  }
}
