# Aurora Downloader — Technical Codebase Critique

Last updated: 2026-07-18.

This document outlines a deep-dive, critical technical review of the **Aurora Downloader** architecture, highlighting performance bottlenecks, memory churn hotspots, and structural vulnerabilities.

**Remediation status:** items 2–6 addressed in code. Item 1 partially addressed (first extraction slice); further split tracked as B5.

**Implementation tracker:** [critique_remediation_plan.md](./critique_remediation_plan.md)

---

## 1. Monolithic Component Pattern — PARTIAL
### [sniffer_screen.dart](../lib/sniffer/sniffer_screen.dart) (~4,840 lines; was ~6,800)

* **The Issue:** A single UI component owns layout, menus, dialogs, and WebView orchestration.
* **Progress (B1–B5):**
  * Header/UA helpers → `sniffer_url_utils.dart`
  * Formatters → `sniffer_formatters.dart`
  * Strict-redirect dialog → `sheets/strict_redirect_prompt.dart`
  * Picker cancel chip → `widgets/picker_cancel_chip.dart`
  * Library export/import → `library_transfer.dart` + transfer sheets
  * Browser tools menu → `sheets/browser_menu_sheet.dart`
  * Quality sort/pick + floating overlay → `playback_quality.dart`, `widgets/floating_player_overlay.dart`
  * Favorites dialogs → `sheets/favorite_dialogs.dart`
  * Enqueue path → `enqueue_download.dart` + duplicate dialog
  * Find bar / phishing dialog / capture sort extracted
* **Remaining (optional):** `_setupTabCallbacks` / main `build` shell further splits — plan: [sniffer_further_refactor_plan.md](./sniffer_further_refactor_plan.md).

---

## 2. UI Thread / Main Isolate Congestion — FIXED

* **Fix:** `HlsDecryptor` and post-merge SHA-256 run via `Isolate.run`.

---

## 3. Cryptographic and GC Overhead in [HlsDecryptor](../lib/downloader/hls_decryptor.dart) — FIXED

* **Fix:** Reuse PKCS7 / no-pad `Encrypter` per segment; decrypt off UI isolate.

---

## 4. Bridge Allocation Churn in [AdBlockNativeEngine](../lib/native/adblock_native_engine.dart) — FIXED

* **Fix:** Reusable UTF-8 scratch buffers + capped string cache; freed in `destroy()`.

---

## 5. Fragile JS Overrides in [browser_guard.js](../assets/browser_guard.js) — HARDENED

* **Remaining risk:** Location wrappers still exist for ad-redirect capture (by design).
* **Hardening applied:**
  * User-gesture navigations not treated as silent ad redirects
  * Auth/payment host + path allowlist
  * Play-ad suppress still force-blocks
  * Inline script scan capped (250k chars, 40 scripts)
  * Only wrap configurable location descriptors; History API not overridden

---

## 6. Simulated Torrent Mode — FIXED (hard-fail)

* **Fix:** Hard-fail magnets/torrents without native engine; no zero-fill mock files; defaults prefer native.
