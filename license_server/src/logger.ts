import { createHash } from 'node:crypto';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

// Honour LOG_LEVEL from the moment the module loads, so anything logged
// before loadConfig() runs (and test runs) respects it too.
let threshold = LEVEL_ORDER[(process.env.LOG_LEVEL ?? 'info') as LogLevel] ?? LEVEL_ORDER.info;

export function setLogLevel(level: LogLevel): void {
  threshold = LEVEL_ORDER[level] ?? LEVEL_ORDER.info;
}

/**
 * Short, non-reversible fingerprint of a purchase token.
 *
 * Plan §9: purchase tokens must NEVER reach logs in full — a leaked token is
 * directly abusable against the Android Publisher API. Log this instead.
 */
export function tokenFingerprint(token: string): string {
  return createHash('sha256').update(token).digest('hex').slice(0, 12);
}

/** Full SHA-256 of a purchase token — the storage key, not for logs. */
export function tokenHash(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

function emit(level: LogLevel, message: string, fields?: Record<string, unknown>): void {
  if (LEVEL_ORDER[level] < threshold) return;
  const line = {
    ts: new Date().toISOString(),
    level,
    msg: message,
    ...fields,
  };
  const serialized = JSON.stringify(line);
  if (level === 'error' || level === 'warn') {
    process.stderr.write(`${serialized}\n`);
  } else {
    process.stdout.write(`${serialized}\n`);
  }
}

export const log = {
  debug: (msg: string, fields?: Record<string, unknown>) => emit('debug', msg, fields),
  info: (msg: string, fields?: Record<string, unknown>) => emit('info', msg, fields),
  warn: (msg: string, fields?: Record<string, unknown>) => emit('warn', msg, fields),
  error: (msg: string, fields?: Record<string, unknown>) => emit('error', msg, fields),
};
