# App tour (first-launch onboarding) — Summary

| Field | Value |
|-------|-------|
| **Status** | Product feature (first install) |
| **Default** | **On** — shown once until finished or skipped |
| **Disable flag** | `--dart-define=AURORA_ENABLE_ONBOARDING=false` |

Interactive first-launch tour for Aurora Downloader. System permission prompts (notifications, battery optimization) wait until the tour is finished or skipped.

---

## Goals

| Goal | Detail |
|------|--------|
| **First-launch guidance** | Help new users find URL input, Media Sniffer Browser, and Queue / Vault |
| **Zero production risk** | Default `false` via `bool.fromEnvironment`; Play and GitHub release builds stay clean |
| **Coachmark UX** | Dimmed backdrop + glowing cutout over real controls (not a generic modal sheet) |
| **Easy local test** | CLI defines, VS Code launch configs, in-app Settings toggle, User Guide replay |

---

## How it works

### Enablement

```
isEnabled =
  experimentOverride  (if set in onboarding_experiment.json)
  else compileTimeFlag  (AURORA_ENABLE_ONBOARDING, default false)
```

Shown when `isEnabled && !hasCompletedOnboarding`.

### Tutorial steps (5)

| Step | Target | Tab | Content |
|------|--------|-----|---------|
| 1 | URL input (`_urlInputKey`) | Queue | **Link & URL Input** — paste media URLs / stream links |
| 2 | Browser dock tab (`_browserTabKey`) | Queue | **Media Sniffer Browser** — open the built-in browser |
| 3 | Radar (`_browserSnifferKey`) | Browser | **Sniffed Media** — review detected streams; Queue left of Radar |
| 4 | Tabs (`_browserTabsKey`) | Browser | **Browser Tabs** — multi-tab management |
| 5 | Menu ⋯ (`_browserMenuKey`) | Browser | **Menu popup** — Settings + Tools (User Guide, Adblock, Rules, Vault, Profiles, WebDAV, Watcher, History, Favorites, …) |

Steps 1–2 use the shell `AuroraDock` (Queue only). Steps 3–5 switch to Browser so primary-bar keys exist. No Queue-tab spotlight (that icon only exists on the Queue shell bar). `onStepEntered` is always **post-frame** (avoids setState-during-build).

### Spotlight UI

- Full-screen dim (~78% black) with rounded cutout (`PathOperation.difference`)
- Accent glow border (`accentFrost`) around the target
- Frosted card: step badge (“STEP X OF Y”), icon, title, description
- **Skip tutorial** / **Next** / **Got it!**; tap dimmed backdrop advances
- Finish or skip → `OnboardingExperiment.markCompleted()`

---

## Implementation map

| Area | Path | Role |
|------|------|------|
| State / flags | `lib/settings/onboarding_experiment.dart` | Compile flag, JSON persistence, override, completion |
| Overlay UI | `lib/ui/widgets/onboarding_spotlight.dart` | Coachmark painter, tooltip, step machine |
| Wiring | `lib/main.dart` | GlobalKeys, step list, launch + resume checks |
| URL target | `lib/ui/pages/queue_page.dart` | `urlInputKey` on input bar |
| Tab targets | `lib/ui/widgets/aurora_dock.dart` | `queueKey` / `browserKey` on dock tabs |
| Browser chrome | `lib/sniffer/widgets/capture_widgets.dart` | Primary bar: sniffer / tabs / menu keys; disabled icon visibility |
| Settings toggle | `lib/ui/pages/settings_page.dart` | “Onboarding Tutorial Experiment” switch |
| Replay | `lib/ui/pages/user_guide_page.dart` | “Replay App Quick Tour” |
| Tests | `test/onboarding_experiment_test.dart` | Flag, completion, override |
| Launch configs | `.vscode/launch.json` | GitHub / Play Debug + Tutorial |
| Agent notes | `AGENTS.md` | CLI example for the experiment |

### Persistence (`onboarding_experiment.json`)

Stored under the app support directory:

| Key | Purpose |
|-----|---------|
| `hasCompletedOnboarding` | User finished or skipped the tour |
| `experimentOverride` | Local force on/off (null = use compile-time flag) |

Enabling the override (`true`) also resets `hasCompletedOnboarding` so the tour can run immediately.

### Route cleanup on replay / enable

Settings and User Guide call:

```dart
Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
```

so the home shell is visible and the spotlight can attach over `AuroraHome` immediately.

---

## How to run / verify

### CLI

```bash
flutter run --dart-define=AURORA_BUILD_CHANNEL=github --dart-define=AURORA_ENABLE_ONBOARDING=true
```

### VS Code

- **Aurora (GitHub Debug + Tutorial)**
- **Aurora (Play Debug + Tutorial)**

### In-app

1. **Settings → Onboarding Tutorial Experiment** → turn **ON**  
   (pops to home and starts the tour)
2. Or **Settings → User Guide & Tutorial → Replay App Quick Tour**

### Checks

- [ ] With flag **off** and no override: tour never appears
- [ ] With flag **on**, fresh state: tour after first paint (~600 ms delay on cold start)
- [ ] Tab switches correctly for steps 1–3; cutouts land on the right controls
- [ ] Skip / Got it mark completed; relaunch does not re-show
- [ ] Settings toggle and User Guide replay both re-show after reset

---

## Non-goals (current experiment)

- Not enabled on production Play/GitHub store builds by default
- Not a full product walkthrough (only three core controls)
- Not remote A/B — compile define + local override only

---

*Source: onboarding experiment implementation as of 2026-07-22.*
