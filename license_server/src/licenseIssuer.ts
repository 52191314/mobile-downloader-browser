import { randomUUID } from 'node:crypto';
import jwt from 'jsonwebtoken';
import type { Tier } from './entitlement.js';
import type { KeyRing } from './keys.js';

export interface LicenseClaims {
  iss: string;
  aud: string;
  sub: string;
  tier: Tier;
  products: string[];
  pkg: string;
  jti: string;
  iat: number;
  exp: number;
}

export interface IssuedLicense {
  token: string;
  jti: string;
  kid: string;
  tier: Tier;
  products: string[];
  issuedAt: Date;
  expiresAt: Date;
}

export interface IssuerOptions {
  issuer: string;
  audience: string;
  ttlSeconds: number;
}

/**
 * Signs offline-verifiable license blobs.
 *
 * RS256 with a `kid` header so the client can hold two public keys during a
 * rotation window (plan §15 gap 3). The client verifies signature, `iss`,
 * `aud`, `sub` (its own installId) and `exp` before trusting `tier`.
 */
export class LicenseIssuer {
  constructor(
    private readonly keyRing: KeyRing,
    private readonly options: IssuerOptions,
  ) {}

  issue(input: {
    installId: string;
    packageName: string;
    tier: Tier;
    products: string[];
    now?: Date;
  }): IssuedLicense {
    const now = input.now ?? new Date();
    const issuedAtSec = Math.floor(now.getTime() / 1000);
    const expSec = issuedAtSec + this.options.ttlSeconds;
    const jti = randomUUID();
    const key = this.keyRing.active;

    const payload: LicenseClaims = {
      iss: this.options.issuer,
      aud: this.options.audience,
      sub: input.installId,
      tier: input.tier,
      products: [...input.products].sort(),
      pkg: input.packageName,
      jti,
      iat: issuedAtSec,
      exp: expSec,
    };

    const token = jwt.sign(payload, key.privateKeyPem, {
      algorithm: 'RS256',
      keyid: key.kid,
    });

    return {
      token,
      jti,
      kid: key.kid,
      tier: input.tier,
      products: payload.products,
      issuedAt: new Date(issuedAtSec * 1000),
      expiresAt: new Date(expSec * 1000),
    };
  }

  /** Verify a license we issued — used by tests and the /v1/license/inspect aid. */
  verify(token: string): LicenseClaims {
    const decoded = jwt.decode(token, { complete: true });
    const kid = decoded?.header?.kid;
    if (!kid) throw new Error('License is missing a kid header');
    const publicKey = this.keyRing.publicKeyFor(kid);
    if (!publicKey) throw new Error(`Unknown signing key "${kid}"`);
    return jwt.verify(token, publicKey, {
      algorithms: ['RS256'],
      issuer: this.options.issuer,
      audience: this.options.audience,
    }) as LicenseClaims;
  }
}
