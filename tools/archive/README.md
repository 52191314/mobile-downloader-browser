# Archived tools

## Load Lab (2026-07-16)

One-off experiment to A/B page-load causes via Diagnostics toggles
(disable intercept / enrich / guard) plus host-side WebSocket timing.

Archived after the user reported page loads felt faster without any Load Lab
toggles — the experimental UI was removed from production paths and general
load refinements (media-only fetch/XHR bridge posts, eager-enrich only for
downloadable-priority types) were kept permanently.

| File | Role |
|------|------|
| `load_lab_monitor.ps1` | Host-side ClientWebSocket monitor for `LOAD_LAB` / `LOAD_METRIC` log lines |
| `load_lab_results.log` | Append-only session timing results |
| `load_lab_live.txt` | Live monitor output snapshot (if present) |

Not used by the app. Safe to delete later if no longer needed for reference.
