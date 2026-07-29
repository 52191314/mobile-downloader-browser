# Aurora Scan & PDF Studio — Execution Plan

| Field | Value |
|-------|-------|
| **Date** | 2026-07-24 |
| **Status** | Plan only (not implemented) |
| **Goal** | Sequence `pdf_scanner_app_idea.md` (already a complete PRD — features, tiers, tech stack, ASO) into a buildable roadmap that reuses Aurora Downloader's proven infrastructure instead of starting the new app from zero. |
| **Out of scope** | This doc | Re-litigating the product concept — see `pdf_scanner_app_idea.md` for the full feature roadmap and competitor analysis |
| **Related** | `pdf_scanner_app_idea.md` (source PRD) · `lib/premium/webdav_backup_service.dart` (near drop-in reuse) · `docs/play_store_listing.md` (naming/policy lessons that carry over) |

---

## 1. What's reusable from Aurora Downloader (real leverage, not just brand)

| Piece | Source | Reuse in Scan & PDF Studio |
|---|---|---|
| WebDAV backup/sync | `lib/premium/webdav_backup_service.dart`, `webdav_settings_page.dart` | The PRD's "BYOC: Nextcloud/WebDAV sync" feature is close to a direct port |
| Play Billing wiring | `in_app_purchase` integration in Aurora | Same one-time-unlock pattern, no new billing research needed |
| Build-channel split | `AURORA_BUILD_CHANNEL=play` / `github` dart-define pattern | Same dual-distribution story (Play + GitHub/F-Droid) the PRD already wants |
| CI pipeline | `.github/workflows/ci.yml` | Copy the template, adjust build targets |
| Privacy policy hosting pattern | `docs/privacy_policy.md`, `docs/privacy_policy_hosting.md` | Same hosting approach, new content |
| Naming/ASO policy lesson | `docs/play_store_listing.md` — "Do not use: TikTok, Instagram, YouTube... [competitor names]" | The PRD's tagline ("CamScanner Alternative") is fine as an internal pitch but **must not** appear in actual Play Store copy or ASO keywords — same policy reasoning, already paid for once on Aurora |

**Genuinely new risk (not reusable):** document edge detection, on-device OCR accuracy, and PDF manipulation are a different engineering domain from a download engine — treat this as higher product risk than the desktop companion plan, not a rerun of Aurora's playbook.

---

## 2. Phased delivery

| Phase | Work | Outcome |
|---|---|---|
| **P0 — Validate before building** | Spend a day reading current Play Store reviews on CamScanner / Adobe Scan / Smallpdf specifically for how many one- and two-star reviews cite subscription pricing vs. other complaints (quality, ads, bugs). The PRD's whole pitch rests on that pain point being large and specific — confirm cheaply before committing weeks. | Go/no-go decision, written down |
| **P1 — Scaffold from Aurora's proven parts** | New Flutter project. Port: build-channel dart-define split, CI workflow, Play Billing plumbing, privacy-policy template, WebDAV service. | Empty app that already builds, signs, and has a working billing path — before a single scanner feature exists |
| **P2 — Thin scanner MVP** | Cut the PRD's v1 scope hard: edge detection + capture + Magic Color/B&W filter + local PDF export. Defer ID-card mode, batch scanning, signatures, and the watermark suite. | Play Store listing live, free tier only — get real ASO/review data fast, same instinct as Aurora's own launch |
| **P3 — OCR + Pro unlock** | On-device OCR (ML Kit) + searchable PDF export, gated behind a one-time Pro unlock at the same price-tier pattern already validated on Aurora. | First paid conversions on the new app |
| **P4 — PDF Studio suite** | Merge/split, page management, signatures, encryption, compression — the remainder of the PRD's feature list, reprioritized by what P2/P3 users actually request rather than the original full list. | Feature parity with the PRD |
| **P5 — Cross-promote** | Same publisher account — add a "More from Aurora" link in both apps' settings pages; consider a bundle price for users who own both. This lever only exists *because* this is a second app, not a feature on the existing one. | Shared acquisition cost across two apps |

**Effort:** P0–P2 (thin MVP, reusing Aurora's scaffolding) — realistically 4–6 weeks given the new OCR/image-processing domain, noticeably heavier than the desktop companion plan. This is a parallel product line, not a feature on top of what's about to ship — sequence it **after** the entitlement-server gap-closing and the desktop companion's P1–P2, not concurrently, unless there's separate bandwidth for it.

---

## 3. Open choices (owner)

1. Same package-name/publisher conventions as Aurora, or a fresh brand identity for this app?
2. P0 validation: proceed regardless of what the review-mining finds, or treat it as a genuine kill gate?
3. Reuse the same GPL-3.0 + Play-channel-billing split, or a different license given the lessons from the earlier license/piracy discussion?

**Defaults if unanswered:** same publisher account (for cross-promotion in P5), P0 is a real kill gate, same GPL-3.0 core + Play-channel billing split as Aurora unless the license discussion concludes otherwise.

---

*End of plan.*
