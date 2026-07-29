import { Router, type Request, type Response } from 'express';
import { z } from 'zod';
import { ApiError, ErrorCodes } from '../errors.js';
import type { LicenseService, PurchaseInput } from '../licenseService.js';

/** Install ids are client-generated UUIDs; keep the accepted shape tight. */
const installIdSchema = z
  .string()
  .min(8)
  .max(128)
  .regex(/^[A-Za-z0-9_.:-]+$/, 'installId contains unsupported characters');

const packageNameSchema = z
  .string()
  .min(3)
  .max(255)
  .regex(/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/, 'packageName is not a valid package');

const purchaseTokenSchema = z.string().min(8).max(4096);
const productIdSchema = z.string().min(1).max(128);

const purchaseSchema = z.object({
  productId: productIdSchema,
  purchaseToken: purchaseTokenSchema,
});

/**
 * Activate accepts either the single-purchase shape from the plan or a full
 * `purchases[]` ownership snapshot from BillingClient.queryPurchases. The
 * snapshot form is preferred: it is what makes the Pro + Ultra-upgrade
 * combination resolve correctly on a fresh install.
 */
const activateSchema = z
  .object({
    packageName: packageNameSchema,
    installId: installIdSchema,
    purchaseToken: purchaseTokenSchema.optional(),
    productId: productIdSchema.optional(),
    purchases: z.array(purchaseSchema).max(16).optional(),
  })
  .strict()
  .refine(
    (body) =>
      (body.purchases && body.purchases.length > 0) ||
      (body.purchaseToken !== undefined && body.productId !== undefined),
    { message: 'Provide purchases[] or both purchaseToken and productId' },
  );

const refreshSchema = z
  .object({
    packageName: packageNameSchema,
    installId: installIdSchema,
    purchases: z.array(purchaseSchema).max(16).optional(),
  })
  .strict();

function collectPurchases(body: z.infer<typeof activateSchema>): PurchaseInput[] {
  const list: PurchaseInput[] = [...(body.purchases ?? [])];
  if (body.purchaseToken && body.productId) {
    list.push({ productId: body.productId, purchaseToken: body.purchaseToken });
  }
  return list;
}

function parse<T extends z.ZodTypeAny>(schema: T, body: unknown): z.infer<T> {
  const result = schema.safeParse(body);
  if (!result.success) {
    throw ApiError.badRequest(
      ErrorCodes.invalidRequest,
      'Request body failed validation',
      result.error.issues.map((issue) => ({
        path: issue.path.join('.'),
        message: issue.message,
      })),
    );
  }
  return result.data;
}

export function createLicenseRouter(service: LicenseService): Router {
  const router = Router();

  router.post('/activate', async (req: Request, res: Response) => {
    const body = parse(activateSchema, req.body);
    const result = await service.resolve({
      packageName: body.packageName,
      installId: body.installId,
      purchases: collectPurchases(body),
    });
    res.json(toResponse(result));
  });

  router.post('/refresh', async (req: Request, res: Response) => {
    const body = parse(refreshSchema, req.body);
    const result = await service.refresh({
      packageName: body.packageName,
      installId: body.installId,
      purchases: body.purchases ?? [],
    });
    res.json(toResponse(result));
  });

  return router;
}

function toResponse(result: Awaited<ReturnType<LicenseService['resolve']>>) {
  return {
    license: result.license.token,
    tier: result.tier,
    products: result.products,
    keyId: result.license.kid,
    issuedAt: result.license.issuedAt.toISOString(),
    expiresAt: result.license.expiresAt.toISOString(),
  };
}
