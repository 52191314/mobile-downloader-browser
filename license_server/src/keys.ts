import { createPublicKey } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface SigningKey {
  kid: string;
  privateKeyPem: string;
  publicKeyPem: string;
}

export interface Jwk {
  kty: string;
  n?: string;
  e?: string;
  kid: string;
  alg: 'RS256';
  use: 'sig';
}

/**
 * A key ring loaded from disk.
 *
 * Plan §15 gap 3: licenses carry a `kid` header and every key on the ring is
 * published, so a compromised key can be replaced without instantly bricking
 * the offline licenses signed by the outgoing key — publish both, sign with the
 * new one, retire the old after the longest possible license TTL has elapsed.
 */
export class KeyRing {
  private readonly keys: Map<string, SigningKey>;
  readonly activeKid: string;

  private constructor(keys: Map<string, SigningKey>, activeKid: string) {
    this.keys = keys;
    this.activeKid = activeKid;
  }

  static load(keyDir: string, activeKid: string | null): KeyRing {
    if (!existsSync(keyDir)) {
      throw new Error(
        `License key directory not found: ${keyDir}. Run "npm run keys:generate" first.`,
      );
    }

    const keys = new Map<string, SigningKey>();
    for (const file of readdirSync(keyDir)) {
      if (!file.endsWith('.key.pem')) continue;
      const kid = file.slice(0, -'.key.pem'.length);
      const publicPath = join(keyDir, `${kid}.pub.pem`);
      if (!existsSync(publicPath)) {
        throw new Error(`Key "${kid}" has no matching public key at ${publicPath}`);
      }
      keys.set(kid, {
        kid,
        privateKeyPem: readFileSync(join(keyDir, file), 'utf8'),
        publicKeyPem: readFileSync(publicPath, 'utf8'),
      });
    }

    if (keys.size === 0) {
      throw new Error(
        `No signing keys in ${keyDir}. Run "npm run keys:generate" to create one.`,
      );
    }

    let resolvedKid = activeKid;
    if (resolvedKid && !keys.has(resolvedKid)) {
      throw new Error(`LICENSE_ACTIVE_KID="${resolvedKid}" has no key in ${keyDir}`);
    }
    if (!resolvedKid) {
      if (keys.size > 1) {
        throw new Error(
          `${keys.size} keys present in ${keyDir}; set LICENSE_ACTIVE_KID to pick the signer.`,
        );
      }
      resolvedKid = [...keys.keys()][0]!;
    }

    return new KeyRing(keys, resolvedKid);
  }

  /** In-memory ring, used by tests. */
  static fromKeys(keys: SigningKey[], activeKid?: string): KeyRing {
    const map = new Map(keys.map((k) => [k.kid, k]));
    const active = activeKid ?? keys[0]?.kid;
    if (!active) throw new Error('KeyRing.fromKeys requires at least one key');
    if (!map.has(active)) throw new Error(`Active kid "${active}" not in supplied keys`);
    return new KeyRing(map, active);
  }

  get active(): SigningKey {
    return this.keys.get(this.activeKid)!;
  }

  get kids(): string[] {
    return [...this.keys.keys()];
  }

  publicKeyFor(kid: string): string | null {
    return this.keys.get(kid)?.publicKeyPem ?? null;
  }

  /** JWKS document — served at /v1/.well-known/jwks.json. */
  toJwks(): { keys: Jwk[] } {
    return {
      keys: [...this.keys.values()].map((key) => {
        const jwk = createPublicKey(key.publicKeyPem).export({ format: 'jwk' }) as Record<
          string,
          string
        >;
        return { ...jwk, kid: key.kid, alg: 'RS256', use: 'sig' } as Jwk;
      }),
    };
  }
}
