import { Router, type Request, type Response } from 'express';
import type { KeyRing } from '../keys.js';

/**
 * Public verification keys.
 *
 * The Play app ships its public keys compiled in — it must NOT fetch them at
 * runtime, or an attacker who can MITM the app also controls what signs its
 * licenses. This endpoint exists for tooling, debugging and rotation checks.
 */
export function createJwksRouter(keyRing: KeyRing): Router {
  const router = Router();

  router.get('/.well-known/jwks.json', (_req: Request, res: Response) => {
    res.set('Cache-Control', 'public, max-age=3600');
    res.json(keyRing.toJwks());
  });

  return router;
}
