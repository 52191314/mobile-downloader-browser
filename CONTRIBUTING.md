# Contributing to Aurora Downloader

Thank you for your interest in contributing to **Aurora Downloader**! Whether you are fixing a bug, extending sniffer rules, refining the UI, or adding new filter lists, your contributions help make Aurora a fast, reliable, open-source download manager for Android.

---

## ⚡ Quick Start for Developers

Get up and running locally with a single command sequence:

```bash
# Clone the repository and run static analysis & unit tests
git clone https://github.com/52191314/Aurora-Downloader.git
cd Aurora-Downloader
flutter pub get && flutter analyze && flutter test
```

To run on an connected Android device or emulator:

```bash
flutter run
```

---

## 🛠️ Build Channels & Configuration

Aurora Downloader supports two distribution channels controlled by `--dart-define=AURORA_BUILD_CHANNEL`:

| Channel | Flag | Description |
|---------|------|-------------|
| **GitHub / Open Source** (Default) | `AURORA_BUILD_CHANNEL=github` | Sideload / F-Droid / GitHub releases. No Google Play Billing code, full media sniffer enabled. |
| **Play Store** | `AURORA_BUILD_CHANNEL=play` | Google Play Store build with Play Billing integrated and on-demand native modules. |

### Development Commands

- **Debug Run (Foss / GitHub default):**
  ```bash
  flutter run --dart-define=AURORA_BUILD_CHANNEL=github
  ```

- **Debug Run (Bypass initial app onboarding tour during dev):**
  ```bash
  flutter run --dart-define=AURORA_BUILD_CHANNEL=github --dart-define=AURORA_ENABLE_ONBOARDING=false
  ```

- **Build Debug APK:**
  ```bash
  flutter build apk --debug --target-platform android-arm64
  ```

---

## 🏗️ Codebase Architecture

```text
lib/
├── downloader/   # Multi-thread HTTP splitter, HLS AES-128 engine, BitTorrent/magnet, queue management, naming
├── sniffer/      # In-app WebView browser, DOM/Fetch media sniffer, tab groups, adblock intercept, in-app player
├── premium/      # Feature entitlement gates (Pro capabilities)
├── backup/       # Data export/import & automated backup engine
├── settings/     # Central DownloadSettings data model & persistence
├── ui/           # Nordic Glass theme components, Queue, Browser, Settings screens
├── theme/        # Aurora design system & color palettes
├── platform/     # Android native bridges (MediaMuxer remux, Foreground Service)
└── native/       # C++ Native Adblock engine (libaurora_adblock) via Dart FFI
```

---

## 🏷️ Looking for Tasks? (Good First Issues)

We welcome first-time open-source contributors! Here are great starting points:

1. **Adblock & Filter Lists**: Add or update cosmetic/network filter rules in `assets/` or rule parser logic in `lib/sniffer/adblock/`.
2. **Sniffer Parity & Host Hardening**: Extend media sniffing heuristics for new streaming platforms in `lib/sniffer/`.
3. **UI Polish & Glassmorphic Animations**: Improve animations, layout accessibility, or dark/light themes in `lib/ui/`.
4. **Translations**: Translate app strings or error hint messages.

Check open issues on GitHub tagged with:
- [`good first issue`](https://github.com/52191314/Aurora-Downloader/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) — Simple tasks with clear scope.
- [`help wanted`](https://github.com/52191314/Aurora-Downloader/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22) — Features or fixes seeking community participation.

---

## 📋 Pull Request Process

1. **Fork & Branch**: Create a descriptive topic branch (`git checkout -b feature/awesome-sniffer-rule`).
2. **Format & Lint**: Ensure code follows standard Dart formatting and passes analysis:
   ```bash
   dart format .
   flutter analyze
   ```
3. **Tests**: Run automated tests to make sure existing flows remain green:
   ```bash
   flutter test
   ```
4. **Commit & Push**: Keep commits clean and focused. Avoid committing personal queue data, local settings, or secrets.
5. **Open PR**: Provide a summary of changes, screenshot/screen recording if UI-related, and link to any relevant issue.

---

## 📜 License

By contributing to Aurora Downloader, you agree that your contributions will be licensed under the [GNU General Public License v3.0](LICENSE).
