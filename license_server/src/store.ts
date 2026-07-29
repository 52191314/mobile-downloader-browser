import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { tokenHash } from './logger.js';

/**
 * A purchase as last seen by the Android Publisher API.
 *
 * NOTE: `purchaseToken` is stored in the clear because refresh has to re-ask
 * Google whether the purchase still stands (refunds, chargebacks). The DB file
 * is therefore secret material — see README "Protecting the database".
 */
export interface PurchaseRecord {
  tokenHash: string;
  purchaseToken: string;
  productId: string;
  packageName: string;
  orderId: string | null;
  purchaseState: number;
  owned: boolean;
  firstSeenAt: string;
  lastVerifiedAt: string;
  revokedAt: string | null;
}

export interface IssuedLicenseRecord {
  jti: string;
  installId: string;
  tier: string;
  issuedAt: string;
  expiresAt: string;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS purchases (
  token_hash       TEXT PRIMARY KEY,
  purchase_token   TEXT NOT NULL,
  product_id       TEXT NOT NULL,
  package_name     TEXT NOT NULL,
  order_id         TEXT,
  purchase_state   INTEGER NOT NULL,
  owned            INTEGER NOT NULL,
  first_seen_at    TEXT NOT NULL,
  last_verified_at TEXT NOT NULL,
  revoked_at       TEXT
);

CREATE TABLE IF NOT EXISTS install_purchases (
  install_id  TEXT NOT NULL,
  token_hash  TEXT NOT NULL,
  linked_at   TEXT NOT NULL,
  PRIMARY KEY (install_id, token_hash)
);

CREATE INDEX IF NOT EXISTS idx_install_purchases_token
  ON install_purchases (token_hash);

CREATE TABLE IF NOT EXISTS issued_licenses (
  jti        TEXT PRIMARY KEY,
  install_id TEXT NOT NULL,
  tier       TEXT NOT NULL,
  issued_at  TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_issued_licenses_install
  ON issued_licenses (install_id);
`;

interface PurchaseRow {
  token_hash: string;
  purchase_token: string;
  product_id: string;
  package_name: string;
  order_id: string | null;
  purchase_state: number;
  owned: number;
  first_seen_at: string;
  last_verified_at: string;
  revoked_at: string | null;
}

function toRecord(row: PurchaseRow): PurchaseRecord {
  return {
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
  };
}

export class LicenseStore {
  private readonly db: DatabaseSync;

  constructor(dbPath: string) {
    if (dbPath !== ':memory:') {
      mkdirSync(dirname(dbPath), { recursive: true });
    }
    this.db = new DatabaseSync(dbPath);
    this.db.exec('PRAGMA journal_mode = WAL');
    this.db.exec('PRAGMA foreign_keys = ON');
    this.db.exec(SCHEMA);
  }

  close(): void {
    this.db.close();
  }

  /**
   * Insert or refresh a verified purchase.
   *
   * `first_seen_at` is preserved across updates; `revoked_at` is stamped the
   * first time Google stops reporting the purchase as owned and cleared if it
   * ever comes back (e.g. a pending purchase that later completes).
   */
  upsertPurchase(input: {
    purchaseToken: string;
    productId: string;
    packageName: string;
    orderId: string | null;
    purchaseState: number;
    owned: boolean;
    verifiedAt: Date;
  }): PurchaseRecord {
    const hash = tokenHash(input.purchaseToken);
    const now = input.verifiedAt.toISOString();
    const existing = this.getPurchaseByHash(hash);
    const firstSeenAt = existing?.firstSeenAt ?? now;
    let revokedAt: string | null = existing?.revokedAt ?? null;
    if (!input.owned && revokedAt === null) revokedAt = now;
    if (input.owned) revokedAt = null;

    this.db
      .prepare(
        `INSERT INTO purchases (
           token_hash, purchase_token, product_id, package_name, order_id,
           purchase_state, owned, first_seen_at, last_verified_at, revoked_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(token_hash) DO UPDATE SET
           product_id       = excluded.product_id,
           package_name     = excluded.package_name,
           order_id         = excluded.order_id,
           purchase_state   = excluded.purchase_state,
           owned            = excluded.owned,
           last_verified_at = excluded.last_verified_at,
           revoked_at       = excluded.revoked_at`,
      )
      .run(
        hash,
        input.purchaseToken,
        input.productId,
        input.packageName,
        input.orderId,
        input.purchaseState,
        input.owned ? 1 : 0,
        firstSeenAt,
        now,
        revokedAt,
      );

    return this.getPurchaseByHash(hash)!;
  }

  getPurchaseByHash(hash: string): PurchaseRecord | null {
    const row = this.db
      .prepare('SELECT * FROM purchases WHERE token_hash = ?')
      .get(hash) as PurchaseRow | undefined;
    return row ? toRecord(row) : null;
  }

  getPurchaseByToken(purchaseToken: string): PurchaseRecord | null {
    return this.getPurchaseByHash(tokenHash(purchaseToken));
  }

  /**
   * Link a purchase to an install.
   *
   * Plan §15 gap 1: the same purchase token legitimately appears under a new
   * installId after a reinstall or device change, so this is many-to-many by
   * design rather than a one-shot claim.
   */
  linkInstall(installId: string, purchaseToken: string, at: Date): void {
    this.db
      .prepare(
        `INSERT INTO install_purchases (install_id, token_hash, linked_at)
         VALUES (?, ?, ?)
         ON CONFLICT(install_id, token_hash) DO NOTHING`,
      )
      .run(installId, tokenHash(purchaseToken), at.toISOString());
  }

  /** Every purchase ever linked to this install, newest link first. */
  listPurchasesForInstall(installId: string): PurchaseRecord[] {
    const rows = this.db
      .prepare(
        `SELECT p.* FROM purchases p
           JOIN install_purchases ip ON ip.token_hash = p.token_hash
          WHERE ip.install_id = ?
          ORDER BY ip.linked_at DESC`,
      )
      .all(installId) as unknown as PurchaseRow[];
    return rows.map(toRecord);
  }

  /** How many distinct installs have activated this token (reuse signal). */
  countInstallsForToken(purchaseToken: string): number {
    const row = this.db
      .prepare('SELECT COUNT(*) AS n FROM install_purchases WHERE token_hash = ?')
      .get(tokenHash(purchaseToken)) as { n: number } | undefined;
    return row?.n ?? 0;
  }

  recordIssuedLicense(record: IssuedLicenseRecord): void {
    this.db
      .prepare(
        `INSERT INTO issued_licenses (jti, install_id, tier, issued_at, expires_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(jti) DO NOTHING`,
      )
      .run(
        record.jti,
        record.installId,
        record.tier,
        record.issuedAt,
        record.expiresAt,
      );
  }

  /** Drop issued-license audit rows that expired before `before`. */
  pruneExpiredLicenses(before: Date): number {
    const result = this.db
      .prepare('DELETE FROM issued_licenses WHERE expires_at < ?')
      .run(before.toISOString());
    return Number(result.changes ?? 0);
  }

  stats(): { purchases: number; installs: number; licenses: number } {
    const one = (sql: string): number =>
      Number((this.db.prepare(sql).get() as { n: number } | undefined)?.n ?? 0);
    return {
      purchases: one('SELECT COUNT(*) AS n FROM purchases'),
      installs: one('SELECT COUNT(DISTINCT install_id) AS n FROM install_purchases'),
      licenses: one('SELECT COUNT(*) AS n FROM issued_licenses'),
    };
  }
}
