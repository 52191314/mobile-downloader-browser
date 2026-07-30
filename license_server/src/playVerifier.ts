import { google, type androidpublisher_v3 } from 'googleapis';
import type { ServiceAccountCredentials } from './config.js';
import { ApiError } from './errors.js';
import { log, tokenFingerprint } from './logger.js';

/** Android Publisher `purchaseState` values. */
export const PurchaseState = {
  purchased: 0,
  canceled: 1,
  pending: 2,
} as const;

export interface VerifyInput {
  packageName: string;
  productId: string;
  purchaseToken: string;
}

export interface VerifiedPurchase {
  productId: string;
  packageName: string;
  /** 0 purchased · 1 canceled · 2 pending · -1 unknown / rejected by Google. */
  purchaseState: number;
  orderId: string | null;
  /** True only for purchaseState === 0. Pending purchases do NOT entitle. */
  owned: boolean;
}

export interface PurchaseVerifier {
  verify(input: VerifyInput): Promise<VerifiedPurchase>;
}

const NOT_OWNED_STATUSES = new Set([400, 404, 410]);

/** Real verifier — Google Play Developer API `purchases.products.get`. */
export class GooglePlayVerifier implements PurchaseVerifier {
  private readonly publisher: androidpublisher_v3.Androidpublisher;

  constructor(credentials: ServiceAccountCredentials) {
    const auth = new google.auth.GoogleAuth({
      credentials: credentials as unknown as Record<string, string>,
      scopes: ['https://www.googleapis.com/auth/androidpublisher'],
    });
    this.publisher = google.androidpublisher({ version: 'v3', auth });
  }

  async verify(input: VerifyInput): Promise<VerifiedPurchase> {
    const fingerprint = tokenFingerprint(input.purchaseToken);
    try {
      const response = await this.publisher.purchases.products.get({
        packageName: input.packageName,
        productId: input.productId,
        token: input.purchaseToken,
      });
      const data = response.data;
      const state = typeof data.purchaseState === 'number' ? data.purchaseState : -1;
      const verified: VerifiedPurchase = {
        productId: input.productId,
        packageName: input.packageName,
        purchaseState: state,
        orderId: data.orderId ?? null,
        owned: state === PurchaseState.purchased,
      };
      log.debug('play verify ok', {
        productId: input.productId,
        token: fingerprint,
        purchaseState: state,
      });
      return verified;
    } catch (error) {
      const status = extractStatus(error);

      // Google rejecting the token (invalid / consumed / not for this product)
      // is a legitimate "not owned" answer, not a server fault.
      if (status !== null && NOT_OWNED_STATUSES.has(status)) {
        log.info('play verify rejected token', {
          productId: input.productId,
          token: fingerprint,
          status,
        });
        return {
          productId: input.productId,
          packageName: input.packageName,
          purchaseState: -1,
          orderId: null,
          owned: false,
        };
      }

      log.error('play verify failed', {
        productId: input.productId,
        token: fingerprint,
        status,
        error: error instanceof Error ? error.message : String(error),
      });
      throw ApiError.upstream('Could not reach the Google Play Developer API');
    }
  }
}

function extractStatus(error: unknown): number | null {
  if (typeof error !== 'object' || error === null) return null;
  const candidate = error as { status?: unknown; code?: unknown; response?: { status?: unknown } };
  for (const value of [candidate.status, candidate.code, candidate.response?.status]) {
    if (typeof value === 'number' && value >= 100 && value < 600) return value;
  }
  return null;
}

/**
 * Local stub for development and tests.
 *
 * Config refuses to build this when NODE_ENV=production. Tokens prefixed with
 * `canceled:` / `pending:` / `invalid:` simulate the corresponding Play states;
 * anything else verifies as purchased.
 */
export class FakePlayVerifier implements PurchaseVerifier {
  readonly calls: VerifyInput[] = [];

  async verify(input: VerifyInput): Promise<VerifiedPurchase> {
    this.calls.push(input);
    const token = input.purchaseToken;
    let purchaseState: number = PurchaseState.purchased;
    if (token.startsWith('canceled:')) purchaseState = PurchaseState.canceled;
    else if (token.startsWith('pending:')) purchaseState = PurchaseState.pending;
    else if (token.startsWith('invalid:')) purchaseState = -1;

    return {
      productId: input.productId,
      packageName: input.packageName,
      purchaseState,
      orderId: purchaseState === PurchaseState.purchased ? `GPA.FAKE-${token.slice(0, 8)}` : null,
      owned: purchaseState === PurchaseState.purchased,
    };
  }
}
