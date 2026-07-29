import { generateKeyPairSync } from 'node:crypto';
import type { Express } from 'express';
import { createApp } from '../src/app.js';
import { KeyRing, type SigningKey } from '../src/keys.js';
import { LicenseIssuer } from '../src/licenseIssuer.js';
import { LicenseService } from '../src/licenseService.js';
import { FakePlayVerifier } from '../src/playVerifier.js';
import { LicenseStore } from '../src/store.js';

export const PACKAGE_NAME = 'com.personal.aurora_downloader';
export const ISSUER = 'aurora-license-test';
export const AUDIENCE = 'aurora-app-test';

export function makeKey(kid: string): SigningKey {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  return { kid, privateKeyPem: privateKey, publicKeyPem: publicKey };
}

export interface Harness {
  app: Express;
  store: LicenseStore;
  service: LicenseService;
  issuer: LicenseIssuer;
  verifier: FakePlayVerifier;
  keyRing: KeyRing;
  close(): void;
}

export function createHarness(
  options: { ttlSeconds?: number; verifyCacheTtlMs?: number; keys?: SigningKey[] } = {},
): Harness {
  const keyRing = KeyRing.fromKeys(options.keys ?? [makeKey('test-key-1')]);
  const store = new LicenseStore(':memory:');
  const verifier = new FakePlayVerifier();
  const issuer = new LicenseIssuer(keyRing, {
    issuer: ISSUER,
    audience: AUDIENCE,
    ttlSeconds: options.ttlSeconds ?? 30 * 24 * 60 * 60,
  });
  const service = new LicenseService(store, verifier, issuer, {
    allowedPackageNames: [PACKAGE_NAME],
    verifyCacheTtlMs: options.verifyCacheTtlMs ?? 6 * 60 * 60 * 1000,
  });
  const app = createApp({
    service,
    store,
    keyRing,
    trustProxy: 0,
    rateLimitWindowMs: 60_000,
    rateLimitMax: 10_000,
    licenseRateLimitMax: 10_000,
  });

  return {
    app,
    store,
    service,
    issuer,
    verifier,
    keyRing,
    close: () => store.close(),
  };
}
