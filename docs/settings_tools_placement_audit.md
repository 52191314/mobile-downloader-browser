# Settings / Tools Placement Audit

> **Status:** Analysis + proposal. Scope: information architecture only — no entitlement, routing, or page-content changes.

---

## 1. The app has two navigation surfaces that disagree

Every settings-reachable feature is currently exposed through **two independently-maintained menus**:

| Surface | File | Grouping |
|---------|------|----------|
| **Settings hub** | `lib/ui/pages/settings_page.dart` (`_buildSettingsHub`, ~line 320) | Downloads / Browser / Appearance / Data & account / About |
| **Sniffer overflow menu** | `lib/ui/sniffer/sniffer_screen.dart` (`rawSettingsEntries`, ~line 3906) | Downloads & Core Behavior / Security, Privacy & Sniffing / Customization & Profiles / External apps / Sync & Backup / Advanced & Automation / Help & Info |

Both open the **same** `SettingsSection` routes — but bucket the items differently, and the lists are already out of sync (see §3.1).

---

## 2. Verdict per item

Settings hub order. ✅ = correctly placed · ⚠️ = borderline · ❌ = misplaced.

| Item | Hub section | Also in overflow? | Verdict | Notes |
|------|-------------|-------------------|---------|-------|
| Download Defaults | Downloads | ✅ | ✅ | Pure config (concurrency, chunks, retries). |
| Network (proxy/UA) | Downloads | ✅ | ✅ | Pure config. |
| Rules | Downloads | ✅ | ✅ | Pure config (auto-rename/organize). |
| Schedule | Downloads | ✅ | ⚠️ | Config-shaped, but it's an *engine that runs* (auto-starts downloads). Defensible in Downloads. |
| Adblock | Browser | ✅ | ✅ | Pure config. |
| Search & Privacy | Browser | ✅ | ✅ | Config + private-mode toggle. |
| Sniffer | Browser | ✅ | ✅ | Pure config. |
| Profiles | Browser | ✅ | ⚠️ | Per-site **behavior presets** — config of browsing. Fine in Browser. |
| Theme | Appearance | ✅ | ✅ | Pure config. |
| **Backup** | Data & account | ✅ | ⚠️ | A **tool** (export/restore does work). "Data & account" is at least honest. |
| Aurora Pro & Ultra | Data & account | ✅ | ✅ | Account/paywall. |
| **Private Vault** | Data & account | ✅ | ❌ | **Tool** — stateful encrypted storage + import/export/sync actions on files. |
| WebDAV Backup | Data & account | ✅ | ⚠️ | Tool (sync action) — same bucket as Backup. |
| Folder Watcher | Data & account | ✅ | ⚠️ | Tool/daemon — auto-actions on folders. |
| About (+ battery, tour, Diagnostics) | About | ✅ | ✅ | About; **Diagnostics** is a tool but "under About" is a common, acceptable pattern. |
| **Automation API** | — (route only) | ✅ (overflow only) | ❌ | **Tool** (Tasker/REST server) with **no Settings hub entry**. |
| **Google Drive Sync** | — (route only) | ✅ (overflow only, `kDriveSyncEnabled`) | ❌ | Tool, reachable **only** via the sniffer overflow menu. |

---

## 3. The real problems (ranked)

### 3.1 Two sources of truth — already drifted 🔴

- The hub's `_NavItem` list and the overflow's `rawSettingsEntries` list are hand-maintained in two files.
- **Automation API** and **Google Drive Sync** exist only in the overflow menu (`SettingsSection.automation` / `.drive` routes + sniffer entries at `sniffer_screen.dart:3971-3998`). A user browsing Settings **cannot discover them**.
- This drift will keep growing each time a feature is added to one surface but not the other.

### 3.2 Action-features mixed into config sections 🟠

"Data & account" currently holds **Backup**, **WebDAV Backup**, **Private Vault**, **Folder Watcher** — all of which *do work / hold state* rather than configure static preferences. They form the app's de-facto **Tools** cluster — and the overflow menu's *"Sync & Backup"* / *"Advanced & Automation"* buckets already recognize that. The hub just hasn't caught up.

### 3.3 Private Vault is the clearest misfit 🟠

As previously established: stateful encrypted storage with import/export/sync actions = a tool, not a setting.

---

## 4. Recommendation — small, surgical

Don't redesign; regroup inside the existing hub and close the drift.

### 4.1 Hub restructure (`settings_page.dart`)

Rename one section, add a new one, add two missing items:

- **`Data & account` → `Tools & Sync`**
  - Backup
  - WebDAV Backup
  - Google Drive Sync *(new `_NavItem`, gated on `kDriveSyncEnabled`)*
  - **Private Vault** *(moved here)*
  - Folder Watcher
- **New section: `Advanced`**
  - Automation API *(new `_NavItem`)*
  - Aurora Pro & Ultra *(move here, or keep under account — open question)*
- Keep everything else exactly where it is (Downloads, Browser, Appearance, About).

### 4.2 Keep routes untouched

`SettingsSection.drive` and `SettingsSection.automation` already exist and render correctly. This is purely a **hub menu** change — no route, page, or entitlement changes.

### 4.3 Prevent future drift (optional but cheap)

Generate the sniffer overflow's `rawSettingsEntries` from the same hub item list (single `_NavItem` model + section metadata), so both menus read one source. If that's too invasive now, at minimum add a code comment in both files: *"When adding a Settings entry, update both settings_page.dart and sniffer_screen.dart."*

---

## 5. Files changed (proposed)

| File | Change |
|------|--------|
| `lib/ui/pages/settings_page.dart` | Rename `Data & account` → `Tools & Sync`; add `Advanced` section; add Drive Sync + Automation `_NavItem`s; reorder Private Vault. |
| `lib/ui/sniffer/sniffer_screen.dart` | *(Optional)* derive from shared list, else add drift-warning comment. |

---

## 6. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Drive/Automation were hidden deliberately | Both are Pro/Ultra features; showing locked entries with the existing upsell pattern matches how Vault/Watcher are handled. Conditional `kDriveSyncEnabled` preserved. |
| Users can't find moved items | Titles, icons, and subtitles unchanged; only section headers and positions change. |
| Overflow/hub continues to drift | Shared-list refactor (4.3) or explicit maintenance comment. |

---

## 7. Verification

1. Hub renders `Tools & Sync` (Backup → WebDAV → Drive[if enabled] → Private Vault → Watcher) and `Advanced` (Automation API).
2. Drive Sync + Automation entries open their pages for entitled users; free users get the existing upsell flow.
3. Overflow menu still opens all routes.
4. `flutter analyze` clean; no test changes needed (no route/entitlement logic modified).

---

*Related: `docs/private_vault_plan.md` (vault correctness fixes). The vault relocation in Part B of that plan folds into §4.1 of this audit — if both land, do the placement moves in one PR.*
