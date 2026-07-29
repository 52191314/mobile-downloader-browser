import express, {
  type Express,
  type NextFunction,
  type Request,
  type Response,
} from 'express';
import { ApiError } from './errors.js';
import type { KeyRing } from './keys.js';
import type { LicenseService } from './licenseService.js';
import { log } from './logger.js';
import { createGlobalLimiter, createLicenseLimiter } from './middleware/rateLimit.js';
import { createHealthRouter } from './routes/health.js';
import { createJwksRouter } from './routes/jwks.js';
import { createLicenseRouter } from './routes/license.js';
import type { LicenseStore } from './store.js';

export interface AppDeps {
  service: LicenseService;
  store: LicenseStore;
  keyRing: KeyRing;
  trustProxy: number;
  rateLimitWindowMs: number;
  rateLimitMax: number;
  licenseRateLimitMax: number;
}

export function createApp(deps: AppDeps): Express {
  const app = express();

  app.disable('x-powered-by');
  app.set('trust proxy', deps.trustProxy);
  // Purchase-token payloads are tiny; a small cap keeps junk bodies cheap.
  app.use(express.json({ limit: '32kb' }));

  app.use(requestLogger);
  app.use(createGlobalLimiter(deps.rateLimitWindowMs, deps.rateLimitMax));

  app.use('/v1', createHealthRouter(deps.store, deps.keyRing));
  app.use('/v1', createJwksRouter(deps.keyRing));
  app.use(
    '/v1/license',
    createLicenseLimiter(deps.rateLimitWindowMs, deps.licenseRateLimitMax),
    createLicenseRouter(deps.service),
  );

  app.use((_req: Request, res: Response) => {
    res.status(404).json({ error: 'not_found', message: 'No such endpoint' });
  });

  app.use(errorHandler);

  return app;
}

function requestLogger(req: Request, res: Response, next: NextFunction): void {
  const startedAt = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - startedAt) / 1e6;
    // Never log req.body — it carries purchase tokens.
    log.info('request', {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      durationMs: Math.round(ms * 10) / 10,
    });
  });
  next();
}

function errorHandler(
  error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction,
): void {
  if (res.headersSent) {
    next(error);
    return;
  }

  if (error instanceof ApiError) {
    res.status(error.status).json({
      error: error.code,
      message: error.message,
      ...(error.details ? { details: error.details } : {}),
    });
    return;
  }

  // Malformed JSON from express.json()
  if (error instanceof SyntaxError && 'body' in error) {
    res.status(400).json({ error: 'invalid_json', message: 'Request body is not valid JSON' });
    return;
  }

  log.error('unhandled error', {
    error: error instanceof Error ? error.message : String(error),
    stack: error instanceof Error ? error.stack : undefined,
  });
  res.status(500).json({ error: 'internal_error', message: 'Internal error' });
}
