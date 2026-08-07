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
