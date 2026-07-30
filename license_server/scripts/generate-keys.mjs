#!/usr/bin/env node
/**
 * Generates an RS256 license signing keypair.
 *
 *   npm run keys:generate            -> keys/<timestamp-kid>.{key,pub}.pem
 *   npm run keys:generate -- --kid k2 --dir ./keys
 *
 * Existing keys are never overwritten: rotation means adding a second key and
 * pointing LICENSE_ACTIVE_KID at it, so licenses signed by the outgoing key
 * stay verifiable until they expire.
 */
import { createPublicKey, generateKeyPairSync } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index !== -1 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const dir = resolve(arg('dir', './keys'));
const kid = arg('kid', `aurora-${new Date().toISOString().slice(0, 10).replace(/-/g, '')}`);
const bits = Number.parseInt(arg('bits', '2048'), 10);

if (!/^[A-Za-z0-9_-]{1,64}$/.test(kid)) {
  console.error(`Invalid --kid "${kid}" (allowed: A-Z a-z 0-9 _ -, max 64 chars)`);
  process.exit(1);
}

mkdirSync(dir, { recursive: true });

const privatePath = join(dir, `${kid}.key.pem`);
const publicPath = join(dir, `${kid}.pub.pem`);

for (const path of [privatePath, publicPath]) {
  if (existsSync(path)) {
    console.error(`Refusing to overwrite existing key: ${path}`);
    console.error('Pick a different --kid to rotate, or delete the file deliberately.');
    process.exit(1);
  }
}

const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: bits,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

// 0o600: the private key must not be world-readable on the host.
writeFileSync(privatePath, privateKey, { mode: 0o600 });
writeFileSync(publicPath, publicKey, { mode: 0o644 });

console.log(`Generated ${bits}-bit RS256 keypair`);
console.log(`  kid:     ${kid}`);
console.log(`  private: ${privatePath}  (0600, back this up offline)`);
console.log(`  public:  ${publicPath}`);
console.log('');
console.log('Add to .env:');
console.log(`  LICENSE_ACTIVE_KID=${kid}`);
console.log('');
const jwk = createPublicKey(publicKey).export({ format: 'jwk' });

console.log('Embed the PUBLIC key in the Flutter app (never the private one).');
console.log('Add this entry to _bakedKeys in');
console.log('lib/premium/license/license_config.dart — keep the outgoing key');
console.log('alongside it during a rotation:');
console.log('');
console.log('    LicensePublicKey(');
console.log(`      kid: '${kid}',`);
console.log(`      modulus:`);
console.log(`          '${jwk.n}',`);
console.log(`      exponent: '${jwk.e}',`);
console.log('    ),');
console.log('');
console.log('Or inject it at build time without editing source:');
console.log('');
console.log(`    --dart-define=AURORA_LICENSE_KID=${kid} \\`);
console.log(`    --dart-define=AURORA_LICENSE_KEY_N=${jwk.n} \\`);
console.log(`    --dart-define=AURORA_LICENSE_KEY_E=${jwk.e}`);
