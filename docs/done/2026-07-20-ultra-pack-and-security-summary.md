# Ultra Feature Pack + Security Audit — Summary

| Field | Value |
|-------|-------|
| **Date** | 2026-07-20 |
| **Status** | Reference index |

## Full documents (markdown)

| Document | Path |
|----------|------|
| **Ultra full feature pack implementation plan** | [`docs/ultra_full_feature_pack_plan.md`](ultra_full_feature_pack_plan.md) |
| **Security audit** | [`docs/SECURITY_AUDIT.md`](SECURITY_AUDIT.md) |
| FFmpeg spike (prerequisite for U1) | [`docs/ffmpeg_spike_pr-21a.md`](ffmpeg_spike_pr-21a.md) |

Local mirror (if present): `.opencode/plans/2026-07-20-ultra-full-feature-pack-plan.md`

---

## Ultra plan — what it says

**Honest baseline:** Pro plumbing + many Pro features exist; Ultra is mostly **gates**, not product. FFmpeg spike is done; suite is not.

### Go-live Ultra (not “everything”)

| Must ship | Can wait (Phase E) |
|-----------|---------------------|
| **U0** Debug Free/Pro/**Ultra** + Upgrades UX | **U5** On-device AI |
| **U3** Wire 64/64 UI | **U3** Multi-mirror |
| **U1** FFmpeg MVP (compress/trim) | Full FFmpeg kitchen sink polish |
| **U2** Watcher (RSS + page) | **U9** Usenet |
| **U4** Localhost Automation API | Full Tasker plugin |
| **U8** Badge / listing extras | |
| **U6** E2EE vault sync | if calendar slips, post-go-live OK |
| **U7** Companion read-only | full “finish on PC” later |

**Ordered PRs:** UP-00 → FFmpeg integrate → Watcher → API → vault sync → companion → depth.

**Calendar:** ~8–14 weeks solo for go-live A–D.

**First three actions:**

1. Ultra debug dropdown (Free / Pro / **Ultra**)
2. FFmpeg integrate
3. Vault lifecycle fix before marketing Private Vault

---

## SECURITY_AUDIT.md — what it covers

- Threat model (LAN adversary, WebDAV host, local malware, patched APK)
- **Mitigated** list (S-01…S-18): LAN harden, vault GCM, WebDAV HTTPS policy, billing UNION/REPLACE, etc.
- **Open** issues (O-01…O-13): cleartext LAN, vault biometric lifecycle, “move” vs delete original, cookie hang on add-to-queue, no Force Ultra, etc.
- Rules for **future** Automation API / E2EE sync / companion / FFmpeg
- Release regression checklist
- Priority backlog (P0 vault lifecycle + honest move)

---

## Relation to product questions

| Topic | Covered in |
|-------|------------|
| Force Ultra missing | Ultra plan **U0** + audit **O-13** |
| Vault fingerprint / empty vault | Audit **O-02 / O-03 / O-04** + plan immediate actions |
| Full Ultra pack | Ultra plan phases A–E + PR table |
| Add-to-queue spinner | Audit **O-12** (cookie fetch hang) |

---

## Hard constraints (both docs)

1. One-time purchases only  
2. Zero hosting / no Aurora-operated servers  
3. Play YouTube / restricted hosts stay blocked on all tiers  
4. GPL honor-system gates — no DRM  

---

*End of summary.*
