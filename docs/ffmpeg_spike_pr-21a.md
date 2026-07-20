# FFmpeg Spike — PR-21a Deliverable

| Field | Value |
|-------|-------|
| **Author** | Implementation Agent |
| **Date** | 2026-07-20 |
| **Status** | Spike complete — ready for PR-22 (FFmpeg MVP) |
| **Applies to** | Phase 3 Ultra (`ProFeature.ffmpegSuite`) |

---

## 1. Build approach

**Recommendation: `ffmpeg-kit` min-gpl, static arm64 jniLibs, embedded in APK/AAB.**

| Approach | Size (arm64) | Maintenance | Complexity | Verdict |
|----------|-------------|-------------|------------|---------|
| **ffmpeg-kit min-gpl** | ~8–12 MB | Upstream prebuilt, active | Low | ✅ **Chosen** |
| mobile-ffmpeg min-gpl | ~12–16 MB | Archived (2023) | Low | ❌ Unmaintained |
| Custom NDK build | ~6–10 MB | Full control | High | ⏸️ Fallback if page-size issues |
| Download at runtime | 0 MB APK | Server cost, offline fails | Medium | ❌ Rejected |

**ffmpeg-kit** (`com.arthenica:ffmpeg-kit-min-gpl:6.0.3`) is the actively maintained successor to `mobile-ffmpeg`. It ships prebuilt `.so` files for arm64-v8a. Aurora already ships only arm64 (`abiFilters = ["arm64-v8a"]`), so the other ABIs are automatically excluded, keeping the FFmpeg contribution to the single arm64 `.so`.

### 16 KB page size (Android 15+)

Android 15 (API 35) requires 16 KB page size for native libraries. `ffmpeg-kit` 6.0.3 **does not** ship 16 KB-aligned binaries by default. The workaround:

1. Use `android:extractNativeLibs="true"` in `AndroidManifest.xml` (forces re-extraction at install time, which aligns pages).
2. Or build FFmpeg with `--page-size=16384` (custom NDK build path).
3. Or wait for `ffmpeg-kit` to ship 16 KB-aligned builds (tracked upstream).

**Recommendation:** Start with `ffmpeg-kit` and `extractNativeLibs=true`. Monitor upstream for native 16 KB support. If performance or install-time issues arise, fall back to a custom NDK build.

---

## 2. APK size delta

Current APK size breakdown (estimated from typical mobile-ffmpeg/ffmpeg-kit deployments):

| Component | Size |
|-----------|------|
| Base Aurora APK (arm64) | ~15–25 MB |
| FFmpeg arm64 .so (min-gpl) | ~8–12 MB |
| **Estimated total** | **~23–37 MB** |
| **Delta** | **+8–12 MB** |

The delta is acceptable for a premium feature (Ultra tier $9.99). AAB delivery means users download only the arm64 split, so the install-time delta is identical. The app was already arm64-only to keep the native adblock engine small; FFmpeg follows the same constraint.

**Budget:** target < +15 MB. `ffmpeg-kit` min-gpl meets this.

---

## 3. Licensing

### FFmpeg license
FFmpeg is available under **LGPL** or **GPL** depending on which codecs are linked.

- `ffmpeg-kit-min-gpl`: GPL-2.0. Includes libx264 (GPL). Compatible with Aurora's GPL-3.0.
- `ffmpeg-kit-min-lgpl`: LGPL-3.0. Omits x264; uses OpenH264 (BSD) instead.

**Recommendation:** Use **`ffmpeg-kit-min-gpl`** for maximum codec support (x264 for CRF compression). Aurora is GPL-3.0, so linking a GPL-2.0 library is permitted as long as the combined work is distributed under GPL-3.0.

### Required notices (About page)

Add the following to Aurora's About → OSS Licenses screen:

```
This software uses FFmpeg (https://ffmpeg.org/) licensed under the
GNU Lesser General Public License version 2.1 or later
(https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).

FFmpeg source code is available at:
https://github.com/FFmpeg/FFmpeg
```

If `min-gpl` variant is used, add:

```
This build links against libx264 (https://www.videolan.org/developers/x264.html)
which is licensed under the GNU General Public License version 2.
```

### Source code offer
Flutter apps using ffmpeg-kit are not required to distribute source with the binary. A written offer in the About page (URL to FFmpeg GitHub + build instructions) satisfies GPL requirements.

---

## 4. Allowed operations — MVP

### Trim
```bash
ffmpeg -i input.mp4 -ss 00:00:10 -to 00:00:30 -c copy output.mp4
```
- Uses stream copy (`-c copy`) — no re-encode, very fast, near-lossless.
- Duration limited to 30 minutes (configurable).

### Compress (CRF)
```bash
ffmpeg -i input.mp4 -c:v libx264 -crf 28 -preset fast -c:a aac -b:a 64k output.mp4
```
- CRF range slider: 18–51 (lower = better quality, larger file).
- Default: 28 (good balance).
- `-preset fast` keeps encode time reasonable on mobile.
- Max encode time: 30 minutes.

### GIF generation
```bash
ffmpeg -i input.mp4 -vf "fps=10,scale=320:-1:flags=lanczos" -c:v gif output.gif
```
- Configurable: FPS (5–15), width (160–640), palette generation for quality.
- Max duration: 30 seconds of output (to prevent huge GIFs).

### Rejected for MVP
- Audio transcoding (handled by Media3 Transformer, P5)
- Concatenation, overlay, filters — future
- Hardware acceleration (MediaCodec) — future

---

## 5. Thread / process policy

### Architecture
```
Flutter isolate (UI)
    │
    ▼
ffmpeg-kit CommandExecution (native thread pool)
    │
    ├── Progress callback (stderr parse → 0–100%)
    ├── Cancel → kill process group
    └── Timeout → kill process group (30-min default)
```

### Constraints
| Property | Value |
|----------|-------|
| Max concurrent FFmpeg processes | **1** (sequential queue) |
| Max execution time | **30 minutes** per op |
| Cancel behaviour | `SIGTERM` → `SIGKILL` after 5s grace |
| UI thread | Never blocked (ffmpeg-kit runs on its own thread) |
| Download queue impact | None — separate native thread, separate I/O |
| Notification | Show "Processing video…" progress notification during encode |

### Implementation pattern (Dart)
```dart
import 'package:flutter_ffmpeg_kit/flutter_ffmpeg_kit.dart';

Future<FfprobeResult?> runFfmpeg(String cmd) async {
  final session = await FlutterFFmpegKit.executeWithTimeout(cmd, 1800);
  // session.returnCode, session.allLogs, session.duration
  return session;
}
```

---

## 6. Integration points

| UI surface | Where to add | Gate |
|------------|-------------|------|
| Completed download → "Compress" | `download_card.dart` popup | Ultra |
| Completed download → "Convert to GIF" | `download_card.dart` popup | Ultra |
| Queue → overflow → "Trim video" | `queue_page.dart` overflow menu | Ultra |
| Settings → FFmpeg quality presets | `settings_page.dart` Pro section | Ultra |

---

## 7. Risk assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| 16 KB page size breaks on Android 15+ | High | Crash on launch | `extractNativeLibs=true` + monitor upstream |
| APK size exceeds budget (+15 MB) | Medium | User complaints | Rebuild with custom configure; trim codecs |
| FFmpeg process killed by OS (memory) | Medium | Failed encode | Add retry with lower preset; document device reqs |
| GPL compliance lawsuit | Low | Legal | Include accurate notices; link to source |
| User expects faster encodes | Medium | Bad reviews | Show progress notification; document expected times |

---

## 8. Next steps (PR order)

1. ~~PR-21a: This spike~~ ✅
2. **PR-21b**: Add `ffmpeg-kit-min-gpl` dependency, define Ultra op stubs
3. **PR-22**: Implement trim + compress + GIF operations with progress notification
4. **PR-23**: Wire UI actions + settings presets + OSS license notices
5. **Play Console**: Activate `aurora_ultra_unlock` + `aurora_ultra_upgrade` SKUs
6. **Production**: Remove `AURORA_DISABLE_ULTRA_UI` compile flag

---

## 9. Key Decisions

1. **`ffmpeg-kit-min-gpl`** over custom NDK build — prebuilt, maintained, familiar API.
2. **GPL variant** over LGPL — x264 support for CRF compression is worth the GPL requirement.
3. **Embedded .so** over runtime download — offline-capable, no server cost, instant availability.
4. **16 KB page workaround** via `extractNativeLibs=true` — adequate until upstream ships aligned binaries.
5. **+8–12 MB delta** accepted for Ultra tier ($9.99) — consistent with category norms.
6. **Single FFmpeg process** limit — prevents resource starvation. Queue FFmpeg jobs if needed.
