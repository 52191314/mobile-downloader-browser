import 'dotenv/config';

import { createApp } from './app.js';
import { loadConfig } from './config.js';
import { KeyRing } from './keys.js';
import { LicenseIssuer } from './licenseIssuer.js';
import { LicenseService } from './licenseService.js';
import { log, setLogLevel } from './logger.js';
import {
  FakePlayVerifier,
  GooglePlayVerifier,
  type PurchaseVerifier,
} from './playVerifier.js';
import { LicenseStore } from './store.js';

function main(): void {
  const config = loadConfig();
  setLogLevel(config.logLevel);

  const keyRing = KeyRing.load(config.keyDir, config.activeKid);
  const store = new LicenseStore(config.dbPath);

  const verifier: PurchaseVerifier =
    config.playVerifyMode === 'google'
      ? new GooglePlayVerifier(config.serviceAccount!)
      : new FakePlayVerifier();

  if (config.playVerifyMode === 'fake') {
    log.warn('PLAY_VERIFY_MODE=fake — purchases are NOT verified against Google');
  }

  const issuer = new LicenseIssuer(keyRing, {
    issuer: config.issuer,
    audience: config.audience,
    ttlSeconds: config.licenseTtlSeconds,
  });

  const service = new LicenseService(store, verifier, issuer, {
    allowedPackageNames: config.allowedPackageNames,
    verifyCacheTtlMs: config.verifyCacheTtlMs,
  });

  const app = createApp({
    service,
    store,
    keyRing,
    trustProxy: config.trustProxy,
    rateLimitWindowMs: config.rateLimitWindowMs,
    rateLimitMax: config.rateLimitMax,
    licenseRateLimitMax: config.licenseRateLimitMax,
  });

  const server = app.listen(config.port, config.host, () => {
    log.info('license server listening', {
      host: config.host,
      port: config.port,
      env: config.env,
      verifyMode: config.playVerifyMode,
      activeKid: keyRing.activeKid,
      keys: keyRing.kids.length,
      licenseTtlDays: Math.round(config.licenseTtlSeconds / 86400),
      packages: config.allowedPackageNames,
    });
  });

  // Housekeeping: expired audit rows are useless after their license died.
  const pruneTimer = setInterval(
    () => {
      try {
        const removed = store.pruneExpiredLicenses(new Date());
        if (removed > 0) log.debug('pruned expired license rows', { removed });
      } catch (error) {
        log.warn('prune failed', {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    },
    6 * 60 * 60 * 1000,
  );
  pruneTimer.unref();

  const shutdown = (signal: string): void => {
    log.info('shutting down', { signal });
    server.close(() => {
      store.close();
      process.exit(0);
    });
    // Don't hang forever on a stuck connection.
    setTimeout(() => process.exit(1), 10_000).unref();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

try {
  main();
} catch (error) {
  log.error('startup failed', {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exit(1);
}
