import rateLimit, { type RateLimitRequestHandler } from 'express-rate-limit';
import type { Request } from 'express';
import { log } from '../logger.js';

/**
 * Keyed by installId when the client supplies one, else by IP.
 *
 * Plan §9: the point is protecting our Google API quota from a spam loop, not
 * authenticating anyone — installId is client-controlled and the IP fallback is
 * what actually bounds an attacker.
 */
function keyFor(req: Request): string {
  const body = req.body as { installId?: unknown } | undefined;
  const installId = body?.installId;
  if (typeof installId === 'string' && installId.length >= 8 && installId.length <= 128) {
    return `install:${installId}`;
  }
  return `ip:${req.ip ?? 'unknown'}`;
}

function onLimit(req: Request): void {
  log.warn('rate limited', { path: req.path, key: keyFor(req) });
}

export function createGlobalLimiter(windowMs: number, max: number): RateLimitRequestHandler {
  return rateLimit({
    windowMs,
    limit: max,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    // Custom keyGenerator: we intentionally opt out of the built-in IP
    // validators because the key is installId-first, not IP-first.
    validate: false,
    keyGenerator: keyFor,
    handler: (req, res) => {
      onLimit(req);
      res.status(429).json({ error: 'rate_limited', message: 'Too many requests' });
    },
  });
}

/** Stricter bucket for the two endpoints that cost a Google API call. */
export function createLicenseLimiter(windowMs: number, max: number): RateLimitRequestHandler {
  return createGlobalLimiter(windowMs, max);
}
