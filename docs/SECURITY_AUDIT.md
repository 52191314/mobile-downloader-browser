# Aurora Downloader — Security Audit

| Field | Value |
|-------|-------|
| **Date** | 2026-08-07 |
| **Scope** | Premium tiers, LAN Send-to-PC, Private Vault, WebDAV backup, billing, free-taste, sniffer-adjacent network, Automation API |
| **App version baseline** | 4.0.1+52 / `play` |
| **Status** | Living document — Automation API shipped (4.0.1); update when Vault Sync / Companion ship |
| **Related** | `docs/ultra_full_feature_pack_plan.md`, `docs/ffmpeg_spike_pr-21a.md` |

---

## 1. Threat model

| Attacker | Goal | Primary surfaces |
|----------|------|------------------|
| Same Wi‑Fi adversary | Steal files shared via Send-to-PC; sniff tokens | `LanFileServer` cleartext HTTP |
| Malicious / MITM WebDAV host | Steal backups, inject restore payload | `WebdavBackupService` |
| Local malware / backup tool | Read vault ciphertext / keys | App support dir, Keystore |
| Modified APK user | Bypass Pro/Ultra gates | Client honor system (GPL) |
| Remote internet | RCE / unsolicited open port | Only if user starts LAN share or (future) companion mode |
| Confused deputy (Tasker) | Abuse automation API | Localhost Automation API (shipped; default off, bearer token) |

**Out of scope for this audit:** full WebView exploit chain, Play Billing server fraud beyond client reconcile, physical extraction of unlocked device with root.

**Product constraint:** client-side gates are an **honor system** under GPL-3.0. Do not add DRM. Revenue assumes convenience purchases.

---

## 2. Executive summary

| Area | Posture | Notes |
|------|---------|-------|
| Play Billing reconcile | **Good** | BillingClient-only revoke; stream UNION grants |
| Free-taste / caps | **OK** | Local; clock rollback trivial abuse |
| Send-to-PC LAN | **Improved** | Single-use tokens, LAN bind, path allowlist, TTL — still cleartext |
| Private Vault | **Improved crypto; UX/auth bugs** | AES-GCM; fail-closed without device lock; lifecycle vs biometric friction |
| WebDAV backup | **Improved transport policy** | HTTPS required except private IP; restore validated; backup still **not** E2EE |
| Restricted media (Play) | **Good** | Independent of tier |
| Automation API | **Shipped (4.0.1)** | §5.1 controls implemented — see §4.6 |
| Desktop companion | **Not shipped** | Future (§5.3) |

**Overall residual risk for a local downloader utility:** **Medium**, dominated by intentional cleartext LAN sharing and user-chosen WebDAV trust.

---

## 3. Findings register

Severity: **Critical** · **High** · **Medium** · **Low** · **Info**

### 3.1 Addressed (mitigations landed)

| ID | Sev | Finding | Mitigation (code) | Status |
|----|-----|---------|-------------------|--------|
| S-01 | High | LAN bound `0.0.0.0` | Bind LAN IPv4 only | **Mitigated** |
| S-02 | High | Multi-use share tokens | Single-use (`remove` on GET) | **Mitigated** |
| S-03 | High | No absolute share TTL | 15m absolute + 10m idle | **Mitigated** |
| S-04 | High | Full-file `readAsBytes` OOM | Stream `openRead()` | **Mitigated** |
| S-05 | High | `permitted: true` footgun | `start(..., tier:)` re-checks FreeTaste/Pro | **Mitigated** |
| S-06 | High | Arbitrary share paths | Allowlist under docs/completed/support/temp | **Mitigated** |
| S-07 | Med | Content-Disposition injection | Sanitize filename | **Mitigated** |
| S-08 | Med | Rate-limit map wipe | Evict only old minute keys | **Mitigated** |
| S-09 | High | Vault open without device lock | Fail closed if no PIN/biometric | **Mitigated** (causes emulator pain) |
| S-10 | High | Vault AES-CBC no auth | New files AES-GCM v1; legacy CBC read-only | **Mitigated** for new blobs |
| S-11 | Med | Vault path traversal via name | `sanitizeVaultName` rejects `/` `\` `..` | **Mitigated** |
| S-12 | Med | Screenshots of vault | `FLAG_SECURE` via `SecureWindow` | **Mitigated** |
| S-13 | Med | WebDAV HTTP to public hosts | `validateWebdavUrl` HTTPS or private IP only | **Mitigated** |
| S-14 | Med | Weak Digest cnonce | `Random.secure()` | **Mitigated** |
| S-15 | Med | Unsafe remote backup names | `sanitizeBackupRemoteName` | **Mitigated** |
| S-16 | Med | Blind restore JSON | Allowlist keys + size cap 8 MiB | **Mitigated** |
| S-17 | High | Entitlement notify bug `_tier != _tier` | Compare previous tier/source | **Mitigated** |
| S-18 | High | Billing stream REPLACE wipe | UNION grant; BC snapshot REPLACE only | **Mitigated** |

### 3.2 Open / residual

| ID | Sev | Finding | Impact | Recommendation |
|----|-----|---------|--------|----------------|
| **O-01** | High | LAN share is **cleartext HTTP** | Guest Wi‑Fi can sniff file bytes + tokens | Document risk; optional PIN in URL; prefer short TTL (done); never enable by default |
| **O-02** | High | Vault lifecycle locks on `inactive` | Biometric sheet often sets `inactive` → unlock appears broken | Lock only on `paused`/`detached`, or suppress lock while auth in flight |
| **O-03** | High | “Move to Vault” may not delete original | User thinks file is private; clear copy remains in Downloads | Delete/rename original after successful store; clarify UI copy |
| **O-04** | Med | Vault requires Pro gate; free inventory taste unused | Inconsistent with FreeTaste inventory design | Either wire free taste or drop free inventory claims |
| **O-05** | Med | WebDAV backup is **not E2EE** | WebDAV host can read queue/settings JSON | Label as “server can read”; U6 E2EE vault sync separate |
| **O-06** | Med | Site profile `downloadFolder` + headers | Write outside intended trees; header smuggling | Constrain folder under known roots; filter hop-by-hop headers |
| **O-07** | Med | Free cap day uses local clock | Set clock back to reset daily free taste | Accept or use monotonic + last-seen day |
| **O-08** | Med | Offline cached Pro after refund | Until BC reconcile succeeds | Document; optional recheck on resume |
| **O-09** | Low | Recovery key = raw key material | Screenshot before FLAG_SECURE race; user stores insecurely | Show only under FLAG_SECURE; force confirm “written down” |
| **O-10** | Low | Desktop companion (future); Automation API shipped | Accidental LAN bind = remote queue control | Shipped API mitigates: localhost-only, default off, bearer token, rate limits; companion still future |
| **O-11** | Info | GPL gate bypass | Expected | No DRM |
| **O-12** | Med | Add-to-queue cookie fetch no timeout | UI spinner can hang on dead WebView | Timeout 2–3s; proceed with empty cookies |
| **O-13** | Low | Debug Force Pro only (no Ultra) | Incomplete Ultra QA | Free/Pro/Ultra dropdown |

### 3.3 Explicitly accepted product risks

1. **Cleartext LAN file share** — required for “open in PC browser” without cert UX.  
2. **Honor-system IAP gates** — GPL.  
3. **User WebDAV trust** — user chooses server; we only reduce footguns.  

---

## 4. Component deep dives

### 4.1 Play Billing / entitlement

**Files:** `play_billing_service.dart`, `pro_entitlement.dart`, `pro_entitlement_store.dart`

| Control | Status |
|---------|--------|
| Product allowlist `kAllProductIds` | Yes |
| Stream grants UNION only | Yes |
| Revoke only on successful BillingClient query | Yes |
| Restore settle never frees | Yes |
| Upgrade SKU hard-gate `tier == pro` | Yes |
| Cache schema v2 + corrupt → free | Yes |
| Server receipt validation | No (N/A offline) |

**Residual:** patched client can grant product IDs; offline refund lag (O-08).

---

### 4.2 Send-to-PC (`LanFileServer`)

**Controls now:**

- Wi‑Fi only (`ConnectivityResult.wifi`)  
- Bind specific LAN IP  
- Token 32-byte secure random, single-use  
- Path allowlist under app roots  
- Absolute TTL 15m + idle 10m  
- Stream body; rate limit; max concurrent 4  
- Tier re-check on start  

**Residual:** cleartext (O-01); dual-homed routing edge cases; token still valuable until first fetch on hostile LAN.

**Regression tests (manual):**

- [ ] Cellular start fails  
- [ ] Second GET same token → 403  
- [ ] After 15m server stops  
- [ ] Path outside allowlist rejected  
- [ ] Free over daily cap cannot start  

---

### 4.3 Private Vault

**Controls now:**

- AES-GCM v1 for new files; Keystore-backed key via `flutter_secure_storage`  
- Fail closed without device credential  
- Basename sanitization  
- FLAG_SECURE while vault UI open  
- Lock on background  

**Open bugs / UX security:**

| Issue | Detail |
|-------|--------|
| O-02 lifecycle | `inactive` during biometric → false lock |
| O-03 original file | Encrypt does not equal “remove from gallery” |
| Emulator QA | No PIN → vault unusable (by design) |
| Entry points | Only completed download “Move to Vault”; no in-vault import picker |

**Regression tests:**

- [ ] Device with PIN: unlock works  
- [ ] Device without PIN: clear error, no open  
- [ ] Biometric: unlock does not immediately re-lock (after O-02 fix)  
- [ ] `../` vault name rejected  
- [ ] Export writes only under sanitized path  

---

### 4.4 WebDAV backup

**Controls now:**

- HTTPS or private/loopback HTTP only  
- Credentials in secure storage  
- Remote name allowlist `aurora_backup_*`  
- Restore size cap + key allowlist  

**Residual:** server can read backup JSON (O-05); no cert pinning; Digest is MD5-based (protocol limitation).

---

### 4.5 Sniffer / downloads (selected)

| Topic | Note |
|-------|------|
| RestrictedMediaPolicy | Tier-independent; keep regression for Ultra |
| Cookie fetch on add-to-queue | Can hang (O-12); cookies needed for CDN |
| Custom headers from profiles | O-06 |
| Cleartext media URLs | Inherent to many sites; user-initiated |

### 4.6 Automation API (`AutomationApiService`)

**Controls now:**

- Ultra tier only; **default off** — persisted `enabled` flag in `automation_api_settings.json`; auto-starts at launch only if previously enabled
- Binds `127.0.0.1:8080` only (loopback); separate port from Send-to-PC (17890)
- Bearer token: 32 random bytes, `aurora_` prefix, stored in platform secure storage (**not hashed**); shown / regenerable in Settings
- Endpoints: `GET /v1/status` (tier + queue counts), `GET /v1/tasks` (list), `POST /v1/tasks` (enqueue), `POST /v1/tasks/:id/pause|resume|cancel`
- `POST /v1/tasks` → `201` with real `savePath` under the completed-downloads directory; `409` duplicate URL, `400` missing/blocked URL or bad JSON, `413` body > 64 KB, `429` > 60 req/10 s, `503` queue unavailable

---

## 5. Requirements for upcoming Ultra features

### 5.1 Automation API (U4) — shipped in 4.0.1

| Rule | Status |
|------|--------|
| Bind `127.0.0.1` only by default | **Implemented** |
| Separate port from Send-to-PC (17890) | **Implemented** — 8080 |
| Bearer token, high entropy, show once | **Implemented** — 32 random bytes, `aurora_` prefix, secure storage, regenerable in Settings |
| Default **off** | **Implemented** — persisted toggle; auto-starts at launch only if previously enabled |
| No path that returns arbitrary filesystem | **Implemented** — queue metadata + enqueue only |
| Rate limit + body size limit | **Implemented** — 60 req / 10 s; body ≤ 64 KB |
| Ultra gate | **Implemented** |

### 5.2 E2EE Vault Sync (U6)

| Rule | Mandatory |
|------|-----------|
| Ciphertext only on WebDAV/S3 | Yes |
| Passphrase/KDF or device-bound keys | Yes |
| Wrong passphrase fail closed | Yes |
| Do not reuse plaintext WebDAV backup format | Yes |

### 5.3 Desktop companion (U7)

| Rule | Mandatory |
|------|-----------|
| Explicit “Companion mode” toggle | Yes |
| Short-lived token / pair QR | Yes |
| Read-only MVP first | Yes |
| No arbitrary file share without Send-to-PC UX | Yes |

### 5.4 FFmpeg (U1)

| Rule | Mandatory |
|------|-----------|
| No network in FFmpeg jobs | Yes |
| Timeout + cancel | Yes |
| Output only under app/user-selected dirs | Yes |
| OSS license notices | Yes |

---

## 6. Regression checklist (release)

Run before any Play production push that touches premium/network:

- [ ] **Billing:** empty BC query → free; offline failure → keep cache  
- [ ] **LAN:** single-use token; TTL; allowlist; Wi‑Fi only  
- [ ] **Vault:** no-credential denied; GCM round-trip; FLAG_SECURE on  
- [ ] **WebDAV:** reject `http://example.com`; accept `http://192.168.x.x`  
- [ ] **WebDAV restore:** oversized / unknown keys rejected  
- [ ] **Restricted media:** free/pro/ultra all block YouTube on Play  
- [ ] **Add-to-queue:** cookie timeout does not infinite-spin (after O-12 fix)  

---

## 7. Priority fix backlog (security-relevant product)

| Priority | Item | Effort |
|----------|------|--------|
| P0 | O-02 Vault lifecycle vs biometric | 0.5 d |
| P0 | O-03 Vault delete/clear original + honest copy | 0.5 d |
| P1 | O-12 Add-to-queue cookie timeout + finally spinner | 0.5 d |
| P1 | O-13 Debug Free/Pro/Ultra selector | 0.25 d |
| P2 | O-06 Profile downloadFolder root constrain | 1 d |
| P2 | O-05 Label WebDAV backup non-E2EE; push U6 for secrets | product |
| P3 | O-07 Cap clock skew | 0.5 d |

---

## 8. History

| Date | Change |
|------|--------|
| 2026-07-20 | Initial audit from remediation + hardening review; mirrored open issues into Ultra plan |
| 2026-08-07 | Automation API shipped (4.0.1+52): §5.1 controls implemented; §4.6 added |

---

*End of security audit.*
