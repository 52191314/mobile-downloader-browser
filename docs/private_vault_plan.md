# Private Vault — Audit & Remediation Plan

> **Status:** Proposal. Scope: correctness fixes + IA (navigation) relocation only.
> No upgrade/entitlement changes, no crypto redesign, no opportunistic refactors.

---

## 1. Executive summary

**Private Vault works.** The full pipeline (encrypt → store → list → export → delete → WebDAV sync) is wired end-to-end and gated correctly by Pro entitlement plus a 25-item free cap. Authentication is biometric/PIN with a deliberate **fail-closed** posture on devices with no credential.

However:
- It is **mis-categorized in Settings** when it is, by Aurora's own Tools-vs-Settings test, a **Tool**.
- There is **one real correctness bug** (legacy CBC padding is never unpadded → corrupted exports) and a handful of smaller hygiene issues.

The plan below is split into:
- **Part A — Correctness fixes** (do regardless of where the feature lives).
- **Part B — IA relocation** (move the entry point from Settings to Tools).

---

## 2. Findings (verified against source)

### 2.1 Does it work? — pipeline trace

| Stage | Status | Evidence |
|-------|--------|----------|
| Entry point "Move to Vault…" | ✅ Works | `lib/main.dart:1063` → `_moveToVault()` (`:1915`) → `VaultService.store()` (`:1933`) |
| Context-menu surface | ✅ Completed tasks only | `lib/ui/widgets/download_card.dart:831, 1006` (`isCompleted && onMoveToVault != null`) |
| AES-256-GCM encrypt + store | ✅ Correct | `vault_service.dart:184-210`, v1 format `0x01 \| nonce(12) \| ct+tag` |
| Keystore-backed key | ✅ Correct | `FlutterSecureStorage`, `ensureInitialized()` (`:52`) |
| Biometric/PIN gate, fail-closed | ✅ Correct | `authenticate()` (`:86-117`) returns `false` when no credential |
| List contents (symlink guard) | ✅ Correct | `list()` (`:298`), sanitized in `export`/`delete` |
| Export / decrypt | ✅ mostly | `export()` (`:217`) — see Bug B2 |
| Delete | ✅ Correct | `delete()` (`:285`) |
| WebDAV sync (Pro tier) | ✅ Works | `vault_sync_service.dart:43`, invoked from `vault_page.dart:156` |
| Session/lock hygiene | ✅ Correct | 5-min TTL, lock on background, `FLAG_SECURE` via `SecureWindow` |

### 2.2 Bugs

#### 🔴 B1 — Legacy CBC blobs are **not unpadded** → corrupted exports
`_decryptBlob()` (`vault_service.dart:251-279`) reads CBC blobs as `IV(16) | ciphertext` but never strips **PKCS#7 padding**. The `encrypt` package's CBC mode **pads by default** and `decryptBytes` returns the padded plaintext unless padding is removed. Any file written by the legacy (pre-GCM) encoder exports with trailing padding bytes → **corrupted/truncated content**.

```dart
// current (broken for legacy)
final decrypted = encrypter.decryptBytes(enc.Encrypted(ct), iv: iv);
// → returns plaintext INCLUDING PKCS#7 padding bytes
```

**Fix:** strip PKCS#7 manually for the CBC branch only (GCM is stream mode, no padding).

#### 🟠 B2 — Export filename is meaningless
`_export()` (`vault_page.dart:118-120`) writes the internal timestamp name with a tacked-on `.bin`:

```dart
final safe = VaultService.sanitizeVaultName(entry.name) ?? 'export.vault';
final dest = p.join(docs.path, 'vault_export', '$safe.bin');
// → vault_export/1690843406123.vault.bin   (useless double extension)
```

The original filename is **never stored**, so a friendly name is impossible without a metadata sidecar. Minimal fix: drop the `.bin` and write `1690843406123.vault` (still timestamp-y but not lying about being a `.bin`). Better fix: persist the original name in a JSON index (see Deferred).

#### 🟡 B3 — iOS "device supported" guard is weaker than the comment claims
`authenticate()` (`:93-100`) gates on `isDeviceSupported() || canCheckBiometrics`. On **iOS**, `isDeviceSupported()` (local_auth_darwin) returns `true` regardless of whether any credential is enrolled. The outcome is still fail-closed because `authenticate()` itself then returns `false` — but the guard is doing nothing on iOS and the inline comment overstates the protection. Non-blocking; tighten by requiring an enrolled credential check where the platform exposes it, or adjust the comment.

#### 🟡 B4 — Recovery key is single-shot with no re-display
`recoveryKeyShown` is written once (`markRecoveryKeyShown`, `:72`); after dismissal the key is unrecoverable. This **matches** the on-screen warning copy ("This is your ONLY recovery key"), so it is by design — but it is worth an explicit product decision (see Deferred; do not change silently).

### 2.3 Gating (working as intended)

- `ProFeature.privateVault` requires `EntitlementTier.pro` (`pro_features.dart:309`).
- Free tier capped at `freeVaultItems = 25` (`pro_features.dart:247`; surfaced via `Phase2Caps.maxFreeVaultItems`).
- Settings entry upsells non-Pro users instead of opening the page (`settings_page.dart:186-197, 421-427`).

---

## 3. IA decision — Tools or Settings?

**Tools.** Unambiguous.

Aurora's own discriminator:
- **Tool** = a user-initiated action that *does work / moves / transforms* data.
- **Setting** = persistent configuration that changes how the app behaves once.

Private Vault is a Tool because it:
1. **Holds state** (an inventory of encrypted files) rather than *configuring* behavior.
2. Is an **action surface** — move in, export out, sync are verbs, not preferences.
3. Sits alongside **Backup** and **WebDAV Backup**, which already act as tools in the same list.
4. Has a natural neighbor in the **download action menu** (`Move to Vault…` on a task).

The only "Settings-flavored" part is the biometric/recovery ceremony — but that is **authentication**, not app configuration. The *configuration* of vault sync already correctly lives in `WebdavSettingsPage` and should stay there.

---

## 4. Part A — Correctness fixes

> Ordered by severity. Each is a small, scoped change.

### A1. Fix legacy CBC unpadding (B1) — **highest priority**
- **File:** `lib/premium/vault_service.dart`
- **Change:** in `_decryptBlob()`, after CBC decrypt, strip PKCS#7 padding:
  - read last byte `pad`; if `1 <= pad <= 16` and `pad <= plaintext.length` and all trailing `pad` bytes equal `pad`, truncate; else return `null` (tamper/corrupt).
- **Add:** unit test `test/vault_decrypt_legacy_test.dart` covering padded round-trip.
- **Note:** keep GCM branch untouched.

### A2. Fix export filename (B2)
- **File:** `lib/ui/pages/vault_page.dart`
- **Minimal (recommended now):** write `$safe` without appending `.bin` → `vault_export/1690843406123.vault`.
- **Better (optional, see Deferred):** maintain `vault_index.json` mapping vault name → original filename; export uses the original name.

### A3. Harden/document the iOS supported-check (B3)
- **File:** `lib/premium/vault_service.dart`
- **Change:** where the platform API allows, require an enrolled credential before proceeding; otherwise correct the comment to state the guard is Android-effective and the real enforcement is `authenticate()`.
- **Risk:** low; no Android behavior change.

### A4. (Decision, not code) Recovery-key re-display (B4)
- **Decide:** keep single-shot (current, matches copy) **or** add a re-auth → re-show path gated by biometric.
- If changed, update the warning copy accordingly. **Default: leave as-is.**

### Part A acceptance criteria
- [ ] Legacy CBC blob round-trips and exports byte-identical to original.
- [ ] GCM store/export unaffected.
- [ ] Export filename no longer has spurious `.vault.bin`.
- [ ] New unit test passes; `flutter analyze` clean on touched files.

---

## 5. Part B — Relocate entry to Tools

> Rename the nav cluster and move the item. No page/route changes.

### B1. Identify current home
- **File:** `lib/ui/pages/settings_page.dart`
- Section title `"Data & account"` (`:397`) contains: `Backup`, `Aurora Pro & Ultra`, `Private Vault` (`:415-428`), `WebDAV Backup`, `Folder Watcher` (conditional).
- Builder `_buildVaultPage()` (`:2886`) and route case `SettingsSection.vault` (`:186-197`) **stay** — only the *list position* changes.

### B2. Chosen approach — **rename section to "Tools"** (low risk)
Rather than inventing a new top-level cluster (bigger diff, new grouping to design), rename `"Data & account"` → **"Tools"** and let the action-y features live there.

New **Tools** group order:
1. **Backup**
2. **WebDAV Backup**
3. **Private Vault**  ← moved
4. **Folder Watcher** (existing conditional)
5. **Aurora Pro & Ultra** (keep last, or relocate — see Open question)

### B3. Edits
- `settings_page.dart:397`: `_buildSectionTitle('Data & account')` → `'Tools'`.
- Reorder `_NavItem`s per §B2 within the same `_buildNavGroup`.
- Move the `Private Vault` `_NavItem` block (`:415-428`) into position #3, unchanged internally (upsell gate preserved).

### Part B acceptance criteria
- [ ] "Tools" section renders with Private Vault between Backup/Watcher cluster and Pro item.
- [ ] Tapping Private Vault still: Pro → opens `VaultPage`; Free → Pro upsell sheet.
- [ ] No change to `SettingsSection.vault` route or `_buildVaultPage()`.
- [ ] No other Settings sections affected.

---

## 6. Out of scope (explicit non-goals)

- No change to crypto primitives, v1 format, or keystore storage.
- No entitlement/tier changes; 25-item free cap untouched.
- No WebDAV Settings relocation (correctly a Setting).
- No recovery-key UX change without a product decision.
- No "Files changed" expansion beyond the two edited files + one new test.

---

## 7. Files changed

| File | Part | Nature |
|------|------|--------|
| `lib/premium/vault_service.dart` | A1, A3 | bug fix + comment/guard |
| `lib/ui/pages/vault_page.dart` | A2 | export filename |
| `lib/ui/pages/settings_page.dart` | B2, B3 | section rename + item reorder |
| `test/vault_decrypt_legacy_test.dart` | A1 | **new** unit test |

---

## 8. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| A1 padding-strip false-positive on corrupt data | Validate padding strictly; return `null` on any inconsistency (fails closed). |
| A2 changing export name breaks… nothing | Names are export-time only; no persisted references to `.bin`. |
| B2 rename confuses users mid-rollout | Section title is cosmetic; item titles/icons unchanged. |
| Recovery-key single-shot data loss | Keep single-shot; surface clearer copy; revisit only with product sign-off. |

---

## 9. Verification plan

1. **Unit:** `flutter test test/vault_decrypt_legacy_test.dart` (padded CBC round-trip).
2. **Static:** `flutter analyze` on the three edited files.
3. **Manual (device, Pro):**
   - Store a completed download → appears in vault.
   - Lock/unlock via biometric; background → relocks.
   - Export a GCM item → byte-identical to source.
   - Export a **legacy CBC** item (seed one) → byte-identical (proves A1).
   - WebDAV upload/restore round-trip.
4. **Nav:** confirm "Tools" grouping + Pro upsell gate for free users.

---

## 10. Implementation order

1. **A1** (CBC unpadding) + its test — correctness first.
2. **A2** (export filename) — tiny follow-up.
3. **A3** (guard/comment) — hygiene.
4. **B2/B3** (Tools relocation) — independent; can land in the same PR or separately.
5. **A4** — decision only; no code unless directed.

Suggested split: **PR-1 = Part A (fixes)**, **PR-2 = Part B (IA move)** so the behavior fixes ship independently of the navigation change.

---

*Prepared from verified source. If you want, I can proceed with PR-1 (Part A fixes) now, or bundle A+B into a single branch.*
