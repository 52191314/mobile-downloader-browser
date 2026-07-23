# Implementation Plan — Play On-Demand Feature Modules

| Field | Value |
|-------|-------|
| **Status** | Proposed |
| **Scope** | Play channel only (`AURORA_BUILD_CHANNEL=play`) |
| **Out of scope** | GitHub / F-Droid / sideload on-demand delivery |
| **Primary win** | Smaller Play install size by deferring large native libs |
| **First module** | FFmpeg (`ffmpeg_kit_flutter_new_min_gpl`) |
| **Optional later** | BitTorrent (`libtorrent_flutter`) |

---

## 1. Goals

| Goal | Detail |
|------|--------|
| **G1** | Reduce Play **install size** by not shipping FFmpeg native libs until first use |
| **G2** | Keep **GitHub channel** as a fat APK — everything included, no download step |
| **G3** | Reuse existing feature gates (`ProFeature.ffmpegSuite`, Ultra tier) |
| **G4** | Clear UX when a module is missing, downloading, failed, or offline |
| **G5** | One shared Dart codebase; only the *load path* differs by channel |

### Non-goals

- On-demand modules for GitHub / sideload (no Play delivery there)
- Hosting binaries on a private CDN for either channel
- Deferring core download / sniffer / InAppWebView (product-critical)
- Changing Pro/Ultra pricing or entitlement rules

---

## 2. Channel policy (locked)

```
┌─────────────────────────────────────────────────────────────┐
│                     Shared Dart feature code                 │
│              (FFmpeg Studio, FfmpegService, gates)            │
└────────────────────────────┬────────────────────────────────┘
                             │
           ┌─────────────────┴─────────────────┐
           ▼                                   ▼
   AURORA_BUILD_CHANNEL=play          AURORA_BUILD_CHANNEL=github
   (default for Console AAB)          (default for open-source APK)
           │                                   │
   On-demand module via                Libs always in base APK
   Play Feature Delivery               No Play Core / no download
   First open → install module         Feature works immediately
```

| Channel | Packaging | FFmpeg at install | First Studio open |
|---------|-----------|-------------------|-------------------|
| **play** | AAB + dynamic feature module(s) | **Not** in base (on-demand) | Request install → load → run |
| **github** | Single fat APK | **In** APK | Immediate |

Rule of thumb: **if `BuildChannel.isGithub` → treat module as always present.**

---

## 3. Phased delivery

### Phase 0 — Spike & measure (1–2 days)

Confirm feasibility and size savings before structural work.

| Task | Output |
|------|--------|
| Measure current Play AAB / device install size (arm64) | Baseline MB |
| Identify FFmpeg contribution (arm64 `.so` from ffmpeg-kit) | Delta ~8–12 MB (see `docs/ffmpeg_spike_pr-21a.md`) |
| Confirm Flutter deferred components + plugin native libs path for current Flutter/AGP | Spike notes: **BLOCKED** — see [`ffmpeg_spike_pr-21a.md`](./ffmpeg_spike_pr-21a.md) |
| Check Play Console requirements (AAB only, app signing, min API) | Checklist |
| Decide: FFmpeg-only v1 vs FFmpeg+torrent later | Recommendation in spike close-out |

**Exit criteria:** Known install-size delta, known risk list, go/no-go for Phase 1.

---

### Phase 1 — FFmpeg on-demand (Play only) — **MVP**

Largest optional native blob; already Ultra-gated; not on critical path for downloads.

#### 1.1 Module boundary

| In base (always) | In `ffmpeg` dynamic module (Play) |
|------------------|-----------------------------------|
| FFmpeg Studio shell / entry points | `ffmpeg_kit` native `.so` |
| Upsell / Ultra gate UI | Dart code that **must** import ffmpeg-kit |
| Job models that are pure Dart (if split cleanly) | Actual encode/probe execution |
| “Download FFmpeg pack” UI | Plugin registration for ffmpeg-kit |

**GitHub:** same sources, but Gradle links ffmpeg into the **base** APK (no dynamic feature).

#### 1.2 Flutter deferred loading

Use Dart deferred imports for the Play path:

```dart
// Conceptual — exact file split decided in Phase 1 design
import 'ffmpeg_runtime.dart' deferred as ffmpeg_runtime;

Future<void> ensureFfmpegReady() async {
  if (BuildChannel.isGithub) {
    // Fat APK: already linked; optional no-op or light probe
    await FfmpegService.instance.probeVersion();
    return;
  }
  // Play: load deferred component (triggers Play download if needed)
  await ffmpeg_runtime.loadLibrary();
  await FfmpegService.instance.probeVersion();
}
```

| Work item | Notes |
|-----------|--------|
| Split `FfmpegService` so **top-level** code does not import `ffmpeg_kit_*` at app start | Only deferred library imports the plugin |
| Entry points call `ensureFfmpegReady()` before first job / Studio open | `ffmpeg_studio_page.dart`, download-card “Edit in FFmpeg Studio” |
| Keep `ProFeature.ffmpegSuite` gate **before** module install | Don’t download for free users who can’t use it |

#### 1.3 Android / Gradle (Play)

Follow Flutter deferred components + Play Feature Delivery:

| Work item | Notes |
|-----------|--------|
| Enable deferred components in Flutter project config | `deferred-components` / pubspec + Android modules per Flutter docs |
| Create dynamic feature module e.g. `:ffmpeg` | `dist:onDemand`, depends on `:app` |
| Move / isolate ffmpeg-kit native packaging into that module for **play** builds | Hardest step if the plugin assumes base-app embedding |
| Keep base `applicationId` / signing unchanged | Same upload key / Play App Signing |
| Arm64-only (`abiFilters`) remains | Matches existing policy |

**GitHub builds:** do **not** register on-demand modules; produce a normal fat APK with ffmpeg linked as today.

Suggested approach to avoid dual maintenance hell:

1. Prefer **product flavors or build-channel Gradle flags** that:
   - `play` → `dynamicFeatures = [":ffmpeg"]` + ffmpeg dependency on feature module
   - `github` → ffmpeg dependency on `:app` only
2. Or accept that deferred components only apply when building AAB with play defines, and document a separate github APK recipe that disables deferred modules.

Document the exact commands in `docs/build_channels_and_defines.md` after implementation.

#### 1.4 Module install UX (Play)

| State | UX |
|-------|-----|
| **Not installed** | Sheet: “FFmpeg tools need a one-time download (~X MB). Download now?” |
| **Downloading** | Progress + cancel; Studio disabled until ready |
| **Installed** | Transparent; probe version; open Studio |
| **Failed / offline** | Error + Retry; no silent failure |
| **Cancelled** | Return to previous screen; feature stays gated |

Rules:

- Only prompt after Ultra entitlement allows `ProFeature.ffmpegSuite` (or free taste if product decides otherwise — default: **entitled only**).
- Prefer Play’s session API (`SplitInstallManager` / Flutter deferred loading APIs).
- Do not block app cold start on module download.
- Optional: deferred install in background after Ultra purchase (nice-to-have, not MVP).

#### 1.5 Service layer

| File / area | Change |
|-------------|--------|
| `lib/premium/ffmpeg/ffmpeg_service.dart` | Don’t hard-depend on kit at library top if that pulls module into base; introduce `ffmpeg_runtime` deferred unit |
| New: `lib/premium/ffmpeg/ffmpeg_module_loader.dart` | Channel-aware ensure/load/status |
| `lib/ui/pages/ffmpeg_studio_page.dart` | Await loader before showing ops |
| `lib/ui/widgets/download_card.dart` | Same before navigating to Studio |
| `lib/premium/build_channel.dart` | No change required beyond existing `isPlay` / `isGithub` |

API sketch:

```dart
enum FeatureModuleStatus { notNeeded, missing, downloading, ready, failed }

abstract class FeatureModuleLoader {
  FeatureModuleStatus statusFor(String moduleId);
  Stream<FeatureModuleStatus> watch(String moduleId);
  Future<bool> ensureInstalled(String moduleId, {void Function(double)? onProgress});
}
```

Play implementation talks to deferred components / Play Core.  
GitHub implementation always returns `ready`.

#### 1.6 Testing (Phase 1)

| Case | Channel | Expected |
|------|---------|----------|
| Open Studio, Ultra, module missing | play | Download prompt → install → works |
| Open Studio offline, module missing | play | Clear failure + retry |
| Open Studio after install | play | No re-download |
| Free user taps Studio entry | play | Upsell; **no** module download |
| Open Studio | github | Works offline; no download UI |
| Cancel mid-download | play | No crash; can retry later |
| Process death during install | play | Resume or clean re-request |

Device/emulator: use internal testing track AAB (deferred modules don’t fully work from plain sideload APK the same way).

#### 1.7 Docs & release

| Doc | Update |
|-----|--------|
| `docs/build_channels_and_defines.md` | Play AAB + deferred modules; GitHub fat APK |
| `docs/ffmpeg_spike_pr-21a.md` or successor | Supersede “download at runtime = rejected” with “Play on-demand = accepted” |
| `docs/user_guide.md` | One-time FFmpeg pack download on Play |
| `docs/play_store_console_runbook.md` | Internal testing must use Play install path |
| README size / features blurb | Optional |

**Phase 1 exit criteria**

- [ ] Play base install size reduced by ~FFmpeg native size (± measurement)
- [ ] FFmpeg Studio works end-to-end via on-demand on Play internal track
- [ ] GitHub APK still ships FFmpeg and works fully offline
- [ ] Free users never trigger FFmpeg module download
- [ ] No regression on non-FFmpeg download/sniffer paths

---

### Phase 2 — BitTorrent on-demand (optional)

Only if Phase 1 is stable and size still matters.

| Topic | Notes |
|-------|--------|
| **Module** | `torrent` / libtorrent native |
| **Trigger** | First magnet/torrent add (not cold start) |
| **Complexity** | Higher: torrent may be more “core” for power users; more call sites (`torrent_downloader.dart`, queue) |
| **GitHub** | Still fat — no change to open-source UX |
| **Gate** | Not Ultra-only today; confirm product intent (download for all vs Pro tracker packs only) |

Do **not** start Phase 2 until Phase 1 metrics and support load look healthy.

---

### Phase 3 — Polish (optional)

- Preload FFmpeg module after Ultra purchase while on Wi‑Fi
- Module uninstall / storage reclaim (Play supports uninstalling modules; product decision)
- Analytics: install success rate, fail reasons, download MB, time-to-ready
- Size dashboard in release checklist

---

## 4. Architecture sketch

```
User opens FFmpeg Studio
        │
        ▼
 ProFeature.ffmpegSuite allowed?
        │ no → upsell / return
        │ yes
        ▼
 FeatureModuleLoader.ensureInstalled('ffmpeg')
        │
        ├─ github → ready immediately
        │
        └─ play
             ├─ already installed → loadLibrary + probe
             ├─ missing → UI confirm → SplitInstall / deferred download
             └─ fail → error UI
        │
        ▼
 FfmpegService (ffmpeg-kit) execute jobs
```

**Do not put FFmpeg init in `main.dart`.** Keep cold start free of module install.

---

## 5. Build & CI matrix

| Artifact | Command (illustrative) | Modules |
|----------|------------------------|---------|
| Play release AAB | `flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play` | Base + on-demand `ffmpeg` |
| Play debug (device via Play internal / bundletool) | Same channel define | Same |
| GitHub release APK | `flutter build apk --release` (default github) | Fat — FFmpeg inside base |
| GitHub debug APK | `flutter build apk --debug` | Fat |

CI checklist:

- [ ] Play job produces AAB with dynamic feature listed in bundle metadata
- [ ] GitHub job produces APK without requiring Play to run FFmpeg features
- [ ] Size report (bundletool `get-size` or Play pre-launch) recorded per release

---

## 6. Risk register

| Risk | Impact | Mitigation |
|------|--------|------------|
| ffmpeg-kit plugin hardcodes base-app packaging | Deferred module hard | Spike early; fork/wrapper plugin; or only defer Dart + ship native via custom module |
| Deferred components tooling gaps on current Flutter | Schedule slip | Phase 0 go/no-go; fallback keep FFmpeg in base |
| Internal testing / local install confusion | “Module never downloads” | Always install AAB via Play; document in runbook |
| Users on metered data | Complaints | Confirm dialog with size estimate; Wi‑Fi hint |
| Module install fails in restricted regions / Play issues | Feature broken | Retry UX; support FAQ; GitHub users unaffected |
| Dual Gradle config drift | Break one channel | Single source of truth + CI matrix both channels |
| License notices | Compliance | Keep FFmpeg / x264 notices in About regardless of when module installs |

---

## 7. Effort estimate (rough)

| Phase | Effort | Depends on |
|-------|--------|------------|
| Phase 0 spike | 1–2 days | — |
| Phase 1 MVP | 3–7 days | Spike green; plugin modularization may dominate |
| Phase 1 polish + docs + internal track | 1–2 days | MVP |
| Phase 2 torrent | 3–6 days | Phase 1 stable |
| Phase 3 analytics / preload | 1–2 days | Optional |

If the plugin cannot be split cleanly, Phase 1 may grow or be re-scoped to “assets-only deferral” (unlikely to save much without native).

---

## 8. Success metrics

| Metric | Target |
|--------|--------|
| Play download size (arm64, new install, no FFmpeg use) | **−FFmpeg native size** vs baseline |
| FFmpeg Studio success after first install (Play internal) | ≥ 95% on good network |
| GitHub offline FFmpeg | 100% (no network required) |
| Free-user module install rate | **0** (must not download) |
| Crash rate / ANR on Studio open | No regression vs baseline |

---

## 9. Suggested PR sequence

| PR | Title | Contents |
|----|-------|----------|
| **PR-A** | Spike: size + deferred feasibility | Measurements, notes, go/no-go (no product ship) |
| **PR-B** | `FeatureModuleLoader` + GitHub always-ready | Channel abstraction + unit tests; no Android module yet |
| **PR-C** | Play dynamic feature `:ffmpeg` + deferred import split | Android + Dart split + Studio entry wiring |
| **PR-D** | Install UX sheet + error/retry | User-facing Play download flow |
| **PR-E** | Docs + CI matrix + runbook | Channels, Console testing, user guide |
| **PR-F** (later) | Optional torrent module | Phase 2 |

Each PR should keep **GitHub fat APK green** in CI.

---

## 10. Decision log (pre-filled)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Channels in scope | **Play only** | GitHub has no Play Feature Delivery |
| First module | **FFmpeg** | Largest optional native; Ultra-gated; non-critical path |
| GitHub packaging | **Fat APK** | Zero extra host; offline; simple |
| When to download | **First entitled use** (not cold start) | Avoid surprise data use; don’t punish non-Ultra users |
| Free users | **No module download** | Entitlement first |
| Torrent | **Phase 2 optional** | More call sites; product-core for some users |

---

## 11. References

- Flutter deferred components: https://docs.flutter.dev/perf/deferred-components  
- Play Feature Delivery (on-demand): https://developer.android.com/guide/playcore/feature-delivery/on-demand  
- Aurora channels: `docs/build_channels_and_defines.md`  
- FFmpeg size spike: `docs/ffmpeg_spike_pr-21a.md`  
- Feature gate: `ProFeature.ffmpegSuite` in `lib/premium/pro_features.dart`  
- Current service: `lib/premium/ffmpeg/ffmpeg_service.dart`  
- Channel flag: `lib/premium/build_channel.dart`  

---

## 12. Immediate next step

1. Run **Phase 0** size + deferred-plugin spike on a throwaway branch.  
2. If green, land **PR-B → PR-C → PR-D → PR-E** as above.  
3. Validate only via **Play internal testing** install of the AAB (not bare APK sideload).
