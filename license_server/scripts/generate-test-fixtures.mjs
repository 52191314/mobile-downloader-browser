#!/usr/bin/env node
/**
 * Emits a Dart fixture file containing real licenses signed by the server's own
 * issuer, so the Flutter verifier is tested against genuine server output
 * instead of a Dart-side re-implementation of the same assumptions.
 *
 *   npm run build && node scripts/generate-test-fixtures.mjs
 *
 * Writes ../test/premium/license/license_fixtures.dart (deterministic content
 * except for the freshly generated keypair).
 */
import { createPublicKey, generateKeyPairSync } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { KeyRing } from '../dist/keys.js';
import { LicenseIssuer } from '../dist/licenseIssuer.js';

const here = dirname(fileURLToPath(import.meta.url));
const outPath = resolve(here, '../../test/premium/license/license_fixtures.dart');

const ISSUER = 'aurora-license';
const AUDIENCE = 'aurora-app';
const PACKAGE = 'com.personal.aurora_downloader';
const INSTALL_ID = 'test-install-0001';
const OTHER_INSTALL_ID = 'test-install-0002';
const KID = 'test-fixture-key';
const DAY = 24 * 60 * 60 * 1000;

function keypair(kid) {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  return { kid, privateKeyPem: privateKey, publicKeyPem: publicKey };
}

const key = keypair(KID);
const strangerKey = keypair(KID); // same kid, different key => forged signature
const jwk = createPublicKey(key.publicKeyPem).export({ format: 'jwk' });

const issuerFor = (signingKey, opts = {}) =>
  new LicenseIssuer(KeyRing.fromKeys([signingKey]), {
    issuer: opts.issuer ?? ISSUER,
    audience: opts.audience ?? AUDIENCE,
    ttlSeconds: opts.ttlSeconds ?? 30 * 24 * 60 * 60,
  });

const now = new Date('2026-07-25T12:00:00.000Z');
const standard = issuerFor(key);

const ultra = standard.issue({
  installId: INSTALL_ID,
  packageName: PACKAGE,
  tier: 'ultra',
  products: ['aurora_pro_unlock', 'aurora_ultra_upgrade'],
  now,
});

const pro = standard.issue({
  installId: INSTALL_ID,
  packageName: PACKAGE,
  tier: 'pro',
  products: ['aurora_pro_unlock'],
  now,
});

// Issued 40 days ago with a 30-day TTL => expired 10 days before `now`.
const expired = standard.issue({
  installId: INSTALL_ID,
  packageName: PACKAGE,
  tier: 'ultra',
  products: ['aurora_ultra_unlock'],
  now: new Date(now.getTime() - 40 * DAY),
});

const otherInstall = standard.issue({
  installId: OTHER_INSTALL_ID,
  packageName: PACKAGE,
  tier: 'ultra',
  products: ['aurora_ultra_unlock'],
  now,
});

const wrongIssuer = issuerFor(key, { issuer: 'evil-license' }).issue({
  installId: INSTALL_ID,
  packageName: PACKAGE,
  tier: 'ultra',
  products: ['aurora_ultra_unlock'],
  now,
});

const wrongAudience = issuerFor(key, { audience: 'some-other-app' }).issue({
  installId: INSTALL_ID,
  packageName: PACKAGE,
  tier: 'ultra',
  products: ['aurora_ultra_unlock'],
  now,
});

// Correct kid, correct claims, signed by a key we do not trust.
const forged = issuerFor(strangerKey).issue({
  installId: INSTALL_ID,
  packageName: PACKAGE,
  tier: 'ultra',
  products: ['aurora_ultra_unlock'],
  now,
});

/** Re-encode the payload with tier bumped to ultra, keeping the old signature. */
function tamperTier(token) {
  const [header, payload, signature] = token.split('.');
  const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  decoded.tier = 'ultra';
  const rewritten = Buffer.from(JSON.stringify(decoded)).toString('base64url');
  return `${header}.${rewritten}.${signature}`;
}

/** Strip the signature and claim alg:none — the classic JWT downgrade. */
function algNone(token) {
  const [, payload] = token.split('.');
  const header = Buffer.from(
    JSON.stringify({ alg: 'none', typ: 'JWT', kid: KID }),
  ).toString('base64url');
  return `${header}.${payload}.`;
}

const dart = `// GENERATED FILE — do not edit by hand.
//
// Produced by license_server/scripts/generate-test-fixtures.mjs using the
// server's own LicenseIssuer, so these are byte-for-byte what the deployed
// service emits. Regenerate with:
//
//   cd license_server && npm run build && node scripts/generate-test-fixtures.mjs

import 'package:aurora_downloader/premium/license/license_config.dart';

const String kFixtureKid = '${KID}';
const String kFixtureInstallId = '${INSTALL_ID}';
const String kFixtureOtherInstallId = '${OTHER_INSTALL_ID}';
const String kFixturePackageName = '${PACKAGE}';

/// 2026-07-25T12:00:00Z — the instant every fixture was signed at.
final DateTime kFixtureNow = DateTime.utc(2026, 7, 25, 12);

const LicensePublicKey kFixtureKey = LicensePublicKey(
  kid: kFixtureKid,
  modulus:
      '${jwk.n}',
  exponent: '${jwk.e}',
);

/// Valid, unexpired, tier=ultra, products=[pro, upgrade].
const String kUltraLicense =
    '${ultra.token}';

/// Valid, unexpired, tier=pro.
const String kProLicense =
    '${pro.token}';

/// Signed 40 days before [kFixtureNow] with a 30-day TTL.
const String kExpiredLicense =
    '${expired.token}';

/// Valid in every way except it was issued to a different install.
const String kOtherInstallLicense =
    '${otherInstall.token}';

/// iss = "evil-license".
const String kWrongIssuerLicense =
    '${wrongIssuer.token}';

/// aud = "some-other-app".
const String kWrongAudienceLicense =
    '${wrongAudience.token}';

/// Well-formed and correctly claimed, but signed with an untrusted key that
/// advertises the same kid.
const String kForgedLicense =
    '${forged.token}';

/// [kProLicense] with the tier claim rewritten to "ultra".
const String kTamperedTierLicense =
    '${tamperTier(pro.token)}';

/// [kUltraLicense] downgraded to alg:none with the signature stripped.
const String kAlgNoneLicense =
    '${algNone(ultra.token)}';
`;

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, dart, 'utf8');

console.log(`Wrote ${outPath}`);
console.log(`  kid:        ${KID}`);
console.log(`  installId:  ${INSTALL_ID}`);
console.log(`  fixtures:   9 licenses`);
console.log('');
console.log('Sanity check (server verifies its own valid token):');
console.log(`  ${JSON.stringify(standard.verify(ultra.token))}`);
void join;
