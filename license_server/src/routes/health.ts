import { Router, type Request, type Response } from 'express';
import type { KeyRing } from '../keys.js';
import type { LicenseStore } from '../store.js';

const startedAt = Date.now();

export function createHealthRouter(store: LicenseStore, keyRing: KeyRing): Router {
  const router = Router();

  // Deliberately cheap and dependency-free so an uptime pinger can hit it
  // often without touching Google or leaking any state.
  router.get('/health', (_req: Request, res: Response) => {
    res.json({
      status: 'ok',
      uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
      time: new Date().toISOString(),
    });
  });

  // Slightly deeper: proves SQLite is writable and a signing key is loaded.
  router.get('/ready', (_req: Request, res: Response) => {
    try {
      const stats = store.stats();
      res.json({
        status: 'ready',
        activeKid: keyRing.activeKid,
        keys: keyRing.kids.length,
        ...stats,
      });
    } catch (error) {
      res.status(503).json({
        status: 'degraded',
        error: error instanceof Error ? error.message : 'storage unavailable',
      });
    }
  });

  return router;
}
