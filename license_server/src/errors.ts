/**
 * Typed API errors. Every client-visible failure carries a stable machine
 * `code` so the app can branch without string-matching prose.
 */
export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: unknown;

  constructor(status: number, code: string, message: string, details?: unknown) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.details = details;
  }

  static badRequest(code: string, message: string, details?: unknown): ApiError {
    return new ApiError(400, code, message, details);
  }

  static forbidden(code: string, message: string): ApiError {
    return new ApiError(403, code, message);
  }

  static tooManyRequests(message = 'Too many requests'): ApiError {
    return new ApiError(429, 'rate_limited', message);
  }

  /** Google / upstream dependency failed in a way that is not the caller's fault. */
  static upstream(message: string): ApiError {
    return new ApiError(502, 'upstream_unavailable', message);
  }

  static internal(message = 'Internal error'): ApiError {
    return new ApiError(500, 'internal_error', message);
  }
}

/** Stable error codes the Flutter client is expected to handle explicitly. */
export const ErrorCodes = {
  /** Body failed schema validation. */
  invalidRequest: 'invalid_request',
  /** packageName not in the allowlist. */
  packageNotAllowed: 'package_not_allowed',
  /** productId is not one of the three Aurora SKUs. */
  unknownProduct: 'unknown_product',
  /** Google says nothing here is owned → client should drop to free. */
  noValidPurchase: 'no_valid_purchase',
  /** Previously valid entitlement is gone (refund / chargeback / revoke). */
  entitlementRevoked: 'entitlement_revoked',
  /** No purchases on record for this installId; client must re-activate. */
  unknownInstall: 'unknown_install',
} as const;
