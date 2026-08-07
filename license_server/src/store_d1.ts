import type { PurchaseRecord, IssuedLicenseRecord } from "./store.js";
import { tokenHash as computeTokenHash } from "./logger.js";

export interface D1DatabaseBinding {
  prepare(query: string): D1PreparedStatement;
}

export interface D1PreparedStatement {
  bind(...values: any[]): D1PreparedStatement;
  first<T = unknown>(colName?: string): Promise<T | null>;
  all<T = unknown>(): Promise<{ results: T[] }>;
  run(): Promise<{ success: boolean }>;
}

export class D1LicenseStore {
  constructor(private readonly db: D1DatabaseBinding) {}

  async upsertPurchase(p: {
    purchaseToken: string;
    productId: string;
    packageName: string;
    orderId: string | null;
    purchaseState: number;
    owned: boolean;
    now?: Date;
  }): Promise<PurchaseRecord> {
    const hash = computeTokenHash(p.purchaseToken);
    const nowIso = (p.now ?? new Date()).toISOString();

    const existing = await this.db
      .prepare("SELECT first_seen_at FROM purchases WHERE token_hash = ?")
      .bind(hash)
      .first<{ first_seen_at: string }>();

    const firstSeenAt = existing?.first_seen_at ?? nowIso;
    const revokedAt = p.owned ? null : nowIso;

    await this.db
      .prepare(
        `INSERT INTO purchases (
          token_hash, purchase_token, product_id, package_name, order_id,
          purchase_state, owned, first_seen_at, last_verified_at, revoked_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(token_hash) DO UPDATE SET
          purchase_state = excluded.purchase_state,
          owned = excluded.owned,
          last_verified_at = excluded.last_verified_at,
          revoked_at = excluded.revoked_at`
      )
      .bind(
        hash,
        p.purchaseToken,
        p.productId,
        p.packageName,
        p.orderId,
        p.purchaseState,
        p.owned ? 1 : 0,
        firstSeenAt,
        nowIso,
        revokedAt
      )
      .run();

    return {
      tokenHash: hash,
      purchaseToken: p.purchaseToken,
      productId: p.productId,
      packageName: p.packageName,
      orderId: p.orderId,
      purchaseState: p.purchaseState,
      owned: p.owned,
      firstSeenAt,
      lastVerifiedAt: nowIso,
      revokedAt,
    };
  }

  async linkInstall(installId: string, purchaseToken: string, now?: Date): Promise<void> {
    const hash = computeTokenHash(purchaseToken);
    const nowIso = (now ?? new Date()).toISOString();
    await this.db
      .prepare(
        `INSERT OR IGNORE INTO install_purchases (install_id, token_hash, linked_at)
         VALUES (?, ?, ?)`
      )
      .bind(installId, hash, nowIso)
      .run();
  }

  async listPurchasesForInstall(installId: string): Promise<PurchaseRecord[]> {
    const res = await this.db
      .prepare(
        `SELECT p.* FROM purchases p
         INNER JOIN install_purchases ip ON ip.token_hash = p.token_hash
         WHERE ip.install_id = ? AND p.owned = 1`
      )
      .bind(installId)
      .all<any>();

    return (res.results || []).map((row) => ({
      tokenHash: row.token_hash,
      purchaseToken: row.purchase_token,
      productId: row.product_id,
      packageName: row.package_name,
      orderId: row.order_id,
      purchaseState: row.purchase_state,
      owned: row.owned === 1,
      firstSeenAt: row.first_seen_at,
      lastVerifiedAt: row.last_verified_at,
      revokedAt: row.revoked_at,
    }));
  }

  async recordIssuedLicense(r: IssuedLicenseRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO issued_licenses (jti, install_id, tier, issued_at, expires_at)
         VALUES (?, ?, ?, ?, ?)`
      )
      .bind(r.jti, r.installId, r.tier, r.issuedAt, r.expiresAt)
      .run();
  }
}
