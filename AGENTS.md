# Agent notes — Aurora Downloader

## Build channels

> [!IMPORTANT]
> **THIS REPO IS PLAY STORE ONLY.** Default build channel is `play` with `--dart-define=AURORA_LICENSE_URL=https://ahjie521.store/license`. (The open-source fat APK edition is maintained in a separate repository at `aurora_downloader_oss`).

### Release AAB for Play Store

```bash
# 16 KB page-size prep for the libtorrent prebuilt (see section below) —
# no-op on a healthy tree, ~1 s.
bash tooling/prepare_torrent_16k.sh

flutter build appbundle --release --dart-define=AURORA_LICENSE_URL=https://ahjie521.store/license --obfuscate --split-debug-info=build/app/outputs/symbols -PlibtorrentFlutterSkipDownload=true
```

`-PlibtorrentFlutterSkipDownload=true` makes the libtorrent_flutter plugin use the
prebuilt `.so` files that `prepare_torrent_16k.sh` installed (never the slow
CMake-from-source fallback, which triggers if the plugin's download fails mid-build).


The release AAB at `build/app/outputs/bundle/release/app-release.aab` is signed with `upload-keystore.jks` when `android/key.properties` is present. This file is gitignored.

The FFmpeg native library (~10 MB) is **not** included in the base AAB — it is downloaded on-demand from Play Store when the user first opens FFmpeg Studio (Ultra tier only). See `docs/play_on_demand_modules_plan.md`.

### 16 KB page size support (Play requirement)

Google Play rejects AABs whose native libraries are not aligned to >= 16 KB
(the "Your app does not support 16 KB memory page sizes" error, required for
new releases since Nov 2025). Every library in this project already passes —
**except** the `libtorrent_flutter` prebuilt (`liblibtorrent_flutter.so`,
linked upstream with `-Wl,-z,max-page-size=4096`).

The fix is applied by `tooling/prepare_torrent_16k.sh`, which re-aligns the
prebuilt `.so` (both `arm64-v8a` and `armeabi-v7a`) using
`tooling/align_elf_16k.py` — a pure-Python, dependency-free re-aligner that
inserts padding between PT_LOAD segments so `(p_vaddr - p_offset) % 0x4000 == 0`
and sets `p_align = 0x4000`. Virtual addresses are never changed, so no
relocation/symbol/.dynamic entry moves. A plain `p_align` bump without
re-aligning file offsets would pass Play's static check but crash on a real
16 KB device (unaligned mmap) — this script does the real thing.

**ELF32 pitfall (fixed 2026-08-08, commit de1f9bf):** `align_elf_16k.py`
previously unpacked program headers with the ELF64 field order
`(p_type, p_flags, p_offset, p_vaddr, ...)` for both classes. ELF32 phdrs
are `(p_type, p_offset, p_vaddr, p_paddr, ...)` (no `p_flags` gap), so every
offset/vaddr access read the wrong field: padding was computed as
`(p_paddr - p_vaddr) % PAGE = 0` (no padding inserted) and the
"already 16 KB aligned" gate compared `p_paddr - p_vaddr` (always 0) — any
ELF32 lib whose `p_align` was already `>= 0x4000` was declared aligned and
left with 4 KB-congruent offsets (the naive-bump failure mode). The
vendored + pub-cache `armeabi-v7a` prebuilt was that artifact and would
have been packaged on the next build. Fix: per-class `P_OFF`/`P_VADDR`
(and `p_filesz`/`p_memsz`) indices threaded through parse/compute/rewrite/
verify. After fixing, re-run `prepare_torrent_16k.sh` and confirm the
vendored v7a shows `(p_vaddr - p_offset) % 0x4000 == 0` on every PT_LOAD
(see the verify snippet below; llvm-readelf is authoritative for the
on-disk state). The release/debug AABs built 2026-08-07/08 were unaffected
(their v7a was aligned via the Gradle transform cache), but any AAB built
between the naive-bump being vendored and de1f9bf would have been broken.

- Aligned binaries are vendored in `tooling/torrent_16k/<abi>/` (stamped with
  the source package version in `tooling/torrent_16k/VERSION`); the script
  re-aligns from the package in the pub cache when the version changes.
- The `:torrent` feature module's `extractTorrentJni` task
  (`android/torrent/build.gradle.kts`) copies the prebuilt `.so` into the
  module and is forced to always re-run (`outputs.upToDateWhen { false }`):
  its real inputs live in the pub cache outside Gradle's view, so without
  that it goes UP-TO-DATE and packages a stale, unaligned lib.
- Only 64-bit libraries are checked (the requirement is "on 64-bit
  devices"); the armeabi-v7a ffmpeg/mediakit/c++_shared libs stay 4 KB
  aligned and that is fine. AGP strips `.symtab` before packaging
  (`stripReleaseDebugSymbols`) but preserves LOAD-segment alignment, so
  aligning the prebuilt source is sufficient.
- Run the prep script after `flutter pub get` whenever the
  `libtorrent_flutter` version changes, and always before the release build.
- Verify a built AAB with (BOTH ABIs — the arm64-only check is what let
  the ELF32 bug through):
  ```bash
  for abi in arm64-v8a armeabi-v7a; do
    unzip -p build/app/outputs/bundle/release/app-release.aab "torrent/lib/$abi/*.so" > /tmp/check.so
    echo "== $abi =="
    # every LOAD must show align 0x4000 AND (vaddr - offset) % 0x4000 == 0
    llvm-readelf -l -W /tmp/check.so | awk '/LOAD/ {print "  align=0x"$7"  (vaddr-offset)%0x4000="(strtonum("0x"$3)-strtonum("0x"$2))%16384}'
  done
  ```
  (llvm-readelf lives in the NDK: `D:\Android\Sdk\ndk\<ver>\toolchains\llvm\prebuilt\windows-x86_64\bin`.
  The congruence column must be 0 for every LOAD — p_align alone is NOT
  sufficient; a file with `p_align=0x4000` but 4 KB-congruent offsets is the
  naive-bump failure mode.)
- If upstream ever ships 16 KB-aligned binaries (a rebuild with
  `max-page-size=16384`), delete `tooling/torrent_16k/` and drop the prep step.

### Debug APK for local testing

Debug/profile APK builds are always **fat** (FFmpeg included). The on-demand module only activates for release AAB builds with `AURORA_BUILD_CHANNEL=play`.

```bash
flutter build apk --debug
# or with Play Billing for testing:
flutter build apk --debug --dart-define=AURORA_BUILD_CHANNEL=play
# Optional: disable first-launch app tour (product default is ON):
flutter run --dart-define=AURORA_BUILD_CHANNEL=github --dart-define=AURORA_ENABLE_ONBOARDING=false
```

Default channel is `github` so open-source / sideload builds never ship a billing client by accident.
First install auto-shows the interactive app tour; system permissions wait until the tour is finished or skipped.

### Build performance notes

Release AAB builds take **~5 min even with a warm cache** — that is expected, not a stale-build bug:

- **R8 minification** (`:app:minifyReleaseWithR8`) re-runs on every release build; AGP marks it
  stale every time, so it re-minifies the whole app (this is the dominant cost). Debug bundles skip
  R8 entirely, which is why `flutter build appbundle --debug` is ~1.5 min.
- **Flutter AOT phase** (`flutter assemble` → gen_snapshot + native-assets link) re-verifies/re-runs
  each build. This project uses `native_assets` (`jni` / `jni_flutter` → `libdartjni.so`), and the
  native-assets linking step re-runs every time.
- **Gradle configuration** over ~25 projects (4 dynamic-feature modules + ~20 plugin subprojects) is
  not free even when every task is `UP-TO-DATE` (30–90 s of config/task-graph time).

Practical guidance:

- Use `flutter build appbundle --debug --dart-define=AURORA_BUILD_CHANNEL=play` for fast structural
  checks of the on-demand modules (~1.5 min). Run the full `--release` build only when actually
  uploading to Play.
- **What debug can and cannot test for on-demand modules:**
  - Can test: module packaging in the AAB, base/native separation, the no-launch-crash registrant,
    and the "module already installed" runtime path (install every split via
    `bundletool build-apks` + `bundletool install-apks`). The forked plugins are registered at
    runtime (see `FeatureModuleLoader._registerPluginOnPlatform`), which debug builds exercise too.
  - Cannot test: the actual **Play Store module download** (`SplitInstallManager` fetching the
    on-demand module on first use) — that only works when the AAB is installed from a Play test
    track (internal/closed testing). Locally the module either isn't installed (download fails) or
    is pre-installed (all splits installed).
  - `flutter build apk --debug` / `flutter run` are **fat** — no on-demand modules at all; they
    validate the fat path only.
- `android/gradle.properties` sets `kotlin.incremental=true` (safe with in-process
  execution). Do NOT enable `org.gradle.parallel` or `org.gradle.caching` — the file's
  own comment documents why: parallel workers raise peak memory on this 7.8 GB host
  (documented OOM history) and the build cache can serve stale feature-module metadata
  when switching between play/github channels. This is a deliberate, known-good config.
- **CONCURRENT BUILDS WARNING:** Do NOT run builds in this repository simultaneously with the `aurora_downloader_oss` repository or any other heavy task. The host machine has limited RAM (7.8 GB) and concurrent builds will cause OOM crashes. Wait for other build tasks to finish before starting one here.
- Gradle daemons are killed under memory pressure (`gradlew --status` shows `STOPPED`); a cold
  daemon adds ~30–60 s. If the build suddenly feels slower than usual, check daemon status first.

## Release checklist — version display in About

When bumping `version:` in `pubspec.yaml` (and `android/local.properties`), the
About page hardcodes the version string in ONE place and it must be updated or
the About screen shows a stale version (the Settings nav hub subtitle that used
to be the second spot was removed by the 2026-08-07 dead-code sweep):

- `lib/ui/pages/settings_page.dart` — `_buildAboutPage()`: `Text('vX.Y.Z', ...)`

Search for the previous version string before committing a release bump:
`grep -rn "v[0-9]*\." lib/ui/pages/settings_page.dart | grep -i "v[0-9]"`.

## Play Console release notes — language tags (2026-08-11)

Release notes pasted into Play Console ("What's new" / release notes editor) must
use the editor's own language tags — one `<code>...</code>` block per language,
2 lines max each. Play Console **rejects** any tag not in its list with
"Unsupported language translation found: <tag>". The 10 tags that pass (verified
2026-08-11 on release 1.1.1+69):

```
<en-US>  English (US)
<zh-CN>  Simplified Chinese
<ru-RU>  Russian
<pt-BR>  Portuguese (Brazil)
<ja-JP>  Japanese
<id>     Indonesian   ← bare "id" only; Play Console REJECTS "id-ID" and "in-ID"
<hi-IN>  Hindi
<fr-FR>  French
<es-ES>  Spanish (Spain)
<de-DE>  German
```

Gotchas:

- **Indonesian is `id`** (bare language code). Standard BCP 47 `id-ID` and
  Android-legacy `in-ID` are both rejected by Play Console. Android resource
  folders still use `values-in/` — that is unrelated to Play Console tags.
- All other tags use the `xx-YY` region-suffixed form exactly as above (e.g.
  `pt-BR`, not `pt`; `hi-IN`, not `hi`).
- Play Console reports "Release notes provided for N language" counting the
  tags; an unsupported tag errors the whole block until deleted/replaced.
- The current app has 11 locales (`lib/l10n/app_localizations_*.dart` incl.
  Arabic `ar`); the release-notes block above covers 10. Arabic is accepted by
  Play Console as `<ar>` if a future release needs it.

## Play Console recommendations (release 54, 1.0.1) — status

- **Edge-to-edge** — FIXED (commit a917ca3): `enableEdgeToEdge()` in
  `MainActivity.onCreate`. targetSdk 36 is edge-to-edge by default on
  Android 15+; the explicit call keeps bar behavior consistent on older
  versions. The Flutter side already handles insets (SafeArea/MediaQuery).
- **R8 / "Optimized resource shrinking isn't enabled"** — DEFERRED. R8 +
  `isShrinkResources = true` are already on (android/app/build.gradle.kts).
  The Play bullet is gated on AGP 9.0+, which conflicts with the current
  Flutter-beta toolchain (AGP 8.9.1, Gradle 8.12). The planned next bump is
  Gradle ≥ 8.14 / AGP ≥ 8.11.1 / KGP ≥ 2.2.20 (see build-performance notes);
  revisit AGP 9 when Flutter stable supports it.

## Batch listing download (2026-08-10)

- Tools → **"Download all on this page"** (`_runListingBatchDownload` in
  sniffer_screen.dart) crawls the active page and enqueues every linked video
  in one batch: follows same-origin detail links (deeper sub-paths or
  numeric-ID pages like `/user/short/123`) + pagination (`?page=N`, `/page/N`),
  fetches each detail page, extracts media via `NativeHtmlMediaExtractor`,
  dedupes by URL. Core logic is `lib/sniffer/listing_page_crawler.dart`
  (generic — no per-site patterns; unit-tested in the OSS repo at
  `test/sniffer/listing_page_crawler_test.dart`).
- Transport: `_fetchHtmlForCrawl` tries the tab's WebView JS fetch first
  (rides browser WAF-bypass + cookies), falls back to native
  `NetworkBindingService.fetchUrl`.
- Gated by the same FreeTaste `batchCapture` soft-cap as the capture sheet
  (Pro feature, first-N free); respects `RestrictedMediaPolicy`; skips
  already-queued URLs silently (`enqueueDirectDownload(silent: true)`).
- Progress dialog is live-updated via a `ValueNotifier`; cancellable mid-crawl.

## Custom logging — removed (2026-08-05)

The AuroraLog file-logging subsystem + in-app Diagnostics page + both debug log
servers were removed and archived under `archive/diagnostics_logging_2026-08-05/`.
All `AuroraLog.instance.*` call sites are now plain `debugPrint(...)`. Do not
re-introduce a file-persisted logger for diagnostics; if a page needs to show
logs again, restore from the archive and see its README. Logcat (`debugPrint`)
is the supported debugging channel.

## Local tool inventory (Windows host, git-bash terminal)

| Tool | Location | Notes |
|------|----------|-------|
| Flutter SDK | `D:\flutter` (beta channel, 3.46.0-0.3.pre) | `dart` binary = `D:\flutter\bin\cache\dart-sdk\bin\dart` |
| adb / platform-tools | `D:\03_Library\Data\platform-tools` | Physical test device serial: `R5CW30P634N` |
| Java | `D:\01_Apps\Installed\Programs\Java\bin` | Needed to run the Gradle wrapper |
| Android SDK build-tools | `D:\Android\Sdk\build-tools\34.0.0` (also 35.0.0, 36.0.0; sdk.dir in `android\local.properties`) | `dexdump.exe`, `aapt2.exe`, `apkanalyzer.bat` |
| Gradle wrapper | `android\gradle\wrapper\gradle-wrapper.jar` (stock) | **git-bash cannot run `./gradlew`** ("Could not find or load main class") — invoke with `java -cp "<win-path>\gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain <task>` from `android/` |
| GRADLE_USER_HOME | `D:\DevTools\.gradle` (env var) | Daemon logs at `daemon\8.12\*.out.log`; module cache at `caches\modules-2` |
| Gradle / AGP / KGP | 8.12 / 8.9.1 / 2.1.0 (settings.gradle.kts) | Flutter beta warns these will soon be dropped → next: Gradle ≥ 8.14, AGP ≥ 8.11.1, KGP ≥ 2.2.20 |
| bundletool | `D:\DevTools\bundletool\bundletool-all.jar` (1.18.1, downloaded) | Not in SDK/gradle cache (plain/instrumented jars there are non-runnable). Fat jar from GitHub releases: `https://github.com/google/bundletool/releases/download/<ver>/bundletool-all-<ver>.jar` |
| FFmpeg | winget `Gyan.FFmpeg` (ffmpeg-8.1.2-full_build) | Video/audio inspection |
| apktool | `D:\01_Apps\Installed\Programs\apktool` | APK decode/inspect |
| Upload keystore | `android\key.properties` → `upload-keystore.jks` (gitignored) | Required for release AAB signing |
| Font subset tooling | `tooling/subset_inter_font.sh` + `tooling/check_font_subset.py` (python + fonttools ≥ 4.63, `python -m pip install fonttools`) | Inter variable font is subset (Latin/ext+Greek+Cyrillic, opsz pinned) → `assets/fonts/Inter-subset.ttf` (~0.5 MB saved/install). Regenerate after updating `assets/fonts/Inter.ttf`; pubspec points at the subset file. Check: `python tooling/check_font_subset.py` |

### Host quirks (git-bash on Windows)

- **Native exes + MSYS paths**: running Windows tools (curl, java, dexdump, aapt2) with MSYS-style
  `/d/...` or `/tmp/...` paths fails silently or with exit 2. Wrap paths with `cygpath -w` for
  arguments, and use `C:\...` paths for file outputs (e.g. `curl -o "C:\...\file.jar"`).
- **`search_files` tool is unreliable** in this repo (MSYS path-translation IO errors) — use
  `grep`/`find` via terminal instead.
- **Gradle daemon orphans**: killing a `flutter build` mid-run leaves its Gradle daemon holding the
  project lock; the next build then waits for minutes. Fix: `--status` to find BUSY daemons, kill
  them (`Stop-Process -Id <pid> -Force`), then rebuild. Kill ALL `java` processes before a retry.
- **evaluateJavascript results are json-decoded** by flutter_inappwebview (number → Dart `int`,
  string → decoded `String`, no quotes). Do not `.trim()` ints or `jsonDecode` decoded strings.
- **`window.find` loops break rendering**: a `while(window.find(...))` counting loop thrashes
  Android WebView's native finder (white screen). Count matches with a TreeWalker instead.
- **`flutter build apk --release` FAILS in this tree** with a MergeNativeDebugMetadataTask error:
  “Zip file ...native-debug-symbols.zip already contains entry
  arm64-v8a/liblibtorrent_flutter.so.sym” (duplicate prebuilt symbol on the fat-APK path). Do not
  fight it — device-install release APKs come from the release AAB via bundletool
  (`--mode=universal`) instead.

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes_tool` or `query_graph_tool` instead of Grep
- **Understanding impact**: `get_impact_radius_tool` instead of manually tracing imports
- **Code review**: `detect_changes_tool` + `get_review_context_tool` instead of reading entire files
- **Finding relationships**: `query_graph_tool` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview_tool` + `list_communities_tool`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
| ------ | ---------- |
| `detect_changes_tool` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context_tool` | Need source snippets for review — token-efficient |
| `get_impact_radius_tool` | Understanding blast radius of a change |
| `get_affected_flows_tool` | Finding which execution paths are impacted |
| `query_graph_tool` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes_tool` | Finding functions/classes by name or keyword |
| `get_architecture_overview_tool` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes_tool` for code review.
3. Use `get_affected_flows_tool` to understand impact.
4. Use `query_graph_tool` pattern="tests_for" to check coverage.


## Repository Rules & Documentation Policy

- **No Emojis in README.md**: Never include emojis (e.g. ⚡, 🏗️, 🚀, 🛡️, ✨, 💚, ℹ️, etc.) in any README.md or markdown documentation files across repositories. Keep headers and text clean and professional.
- **No Community / Contribution Sections**: Never include Awesome Ecosystem & Community or Open for Contributions sections in README.md files.

## Build & Release Policy (APK & Mobile Builds)

- **Version & Build Code Increment**: Every APK build MUST increment the build code (e.g., --build-number=N or ersionCode) and increment the semver version x.y.z:
  - Increment z (patch) for bug fixes, performance tweaks, and refactors.
  - Increment y (minor) for new features or notable enhancements.
  - Increment x (major) for breaking changes or major product milestones.
- **Mandatory Release Notes**: Every build code / version release MUST have corresponding release notes documented in RELEASE_NOTES_x.y.z.md or the project's release notes file.
