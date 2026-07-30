import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { LogLevel } from './logger.js';

export interface Config {
  env: 'development' | 'production' | 'test';
  port: number;
  host: string;
  trustProxy: number;
  allowedPackageNames: string[];
  playVerifyMode: 'google' | 'fake';
  serviceAccount: ServiceAccountCredentials | null;
  verifyCacheTtlMs: number;
  keyDir: string;
  activeKid: string | null;
  issuer: string;
  audience: string;
  licenseTtlSeconds: number;
  dbPath: string;
  rateLimitWindowMs: number;
  rateLimitMax: number;
  licenseRateLimitMax: number;
  logLevel: LogLevel;
}

export interface ServiceAccountCredentials {
  client_email: string;
  private_key: string;
  [key: string]: unknown;
}

function str(name: string, fallback: string): string {
  const v = process.env[name];
  return v === undefined || v === '' ? fallback : v;
}

function optional(name: string): string | null {
  const v = process.env[name];
  return v === undefined || v === '' ? null : v;
}

function int(name: string, fallback: number): number {
  const raw = optional(name);
  if (raw === null) return fallback;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n)) {
    throw new Error(`Config ${name} must be an integer, got "${raw}"`);
  }
  return n;
}

function csv(name: string, fallback: string): string[] {
  return str(name, fallback)
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

function loadServiceAccount(): ServiceAccountCredentials | null {
  const inline = optional('GOOGLE_SERVICE_ACCOUNT_JSON');
  const path = optional('GOOGLE_SERVICE_ACCOUNT_JSON_PATH');
  const raw = inline ?? (path ? readFileSync(resolve(path), 'utf8') : null);
  if (!raw) return null;

  let parsed: ServiceAccountCredentials;
  try {
    parsed = JSON.parse(raw) as ServiceAccountCredentials;
  } catch {
    throw new Error('Service account credentials are not valid JSON');
  }
  if (!parsed.client_email || !parsed.private_key) {
    throw new Error('Service account JSON is missing client_email / private_key');
  }
  return parsed;
}

/**
 * Reads and validates the environment. Throws on any misconfiguration that
 * would otherwise surface as a runtime 500 on the first real purchase.
 */
export function loadConfig(): Config {
  const env = str('NODE_ENV', 'development') as Config['env'];
  const playVerifyMode = str('PLAY_VERIFY_MODE', 'google') as Config['playVerifyMode'];

  if (playVerifyMode !== 'google' && playVerifyMode !== 'fake') {
    throw new Error(`PLAY_VERIFY_MODE must be 'google' or 'fake', got "${playVerifyMode}"`);
  }
  // A stub verifier in production would hand out Ultra to anyone who asks.
  if (playVerifyMode === 'fake' && env === 'production') {
    throw new Error('PLAY_VERIFY_MODE=fake is refused when NODE_ENV=production');
  }

  const serviceAccount = playVerifyMode === 'google' ? loadServiceAccount() : null;
  if (playVerifyMode === 'google' && !serviceAccount) {
    throw new Error(
      'PLAY_VERIFY_MODE=google requires GOOGLE_SERVICE_ACCOUNT_JSON_PATH or GOOGLE_SERVICE_ACCOUNT_JSON',
    );
  }

  const allowedPackageNames = csv('ALLOWED_PACKAGE_NAMES', 'com.personal.aurora_downloader');
  if (allowedPackageNames.length === 0) {
    throw new Error('ALLOWED_PACKAGE_NAMES must list at least one package');
  }

  const licenseTtlDays = int('LICENSE_TTL_DAYS', 30);
  if (licenseTtlDays < 1 || licenseTtlDays > 365) {
    throw new Error(`LICENSE_TTL_DAYS must be 1..365, got ${licenseTtlDays}`);
  }

  return {
    env,
    port: int('PORT', 8080),
    host: str('HOST', '0.0.0.0'),
    trustProxy: int('TRUST_PROXY', 0),
    allowedPackageNames,
    playVerifyMode,
    serviceAccount,
    verifyCacheTtlMs: int('VERIFY_CACHE_TTL_MINUTES', 360) * 60_000,
    keyDir: resolve(str('LICENSE_KEY_DIR', './keys')),
    activeKid: optional('LICENSE_ACTIVE_KID'),
    issuer: str('LICENSE_ISSUER', 'aurora-license'),
    audience: str('LICENSE_AUDIENCE', 'aurora-app'),
    licenseTtlSeconds: licenseTtlDays * 24 * 60 * 60,
    dbPath: resolve(str('DB_PATH', './data/licenses.db')),
    rateLimitWindowMs: int('RATE_LIMIT_WINDOW_MS', 60_000),
    rateLimitMax: int('RATE_LIMIT_MAX', 60),
    licenseRateLimitMax: int('LICENSE_RATE_LIMIT_MAX', 10),
    logLevel: str('LOG_LEVEL', 'info') as LogLevel,
  };
}
