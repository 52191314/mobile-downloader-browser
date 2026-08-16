# Mobile Downloader Browser

[![CI](https://github.com/52191314/mobile-downloader-browser/actions/workflows/ci.yml/badge.svg)](https://github.com/52191314/mobile-downloader-browser/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android%20%28API%2024%2B%29-green.svg)](https://developer.android.com)
[![Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B.svg?logo=flutter)](https://flutter.dev)

**Mobile Downloader Browser solves the friction of capturing and downloading media on Android.** It seamlessly transforms web browsing into background media capture with an integrated network sniffer, multi-threaded segmented HTTP engine, native HLS/DASH remuxing, and BitTorrent support — all wrapped in a sleek Nordic Glass UI.

> **Branding Note**: This open-source repository and GitHub distribution is titled **Mobile Downloader Browser**. On the Google Play Store, the application retains its published store brand, **`Aurora: Browser & Downloader`**.

---

## Quick Start (One Command)

Test, analyze, and spin up Mobile Downloader Browser on your Android device or emulator with a single command:

```bash
git clone https://github.com/52191314/mobile-downloader-browser.git && cd mobile-downloader-browser && flutter pub get && flutter test && flutter run
```

---

## Architecture & Workflows

Mobile Downloader Browser decouples media detection from downloading, running background isolation workers to prevent UI main-thread jank and handling complex protocols seamlessly.

### Master Application Workflow

![Master Application Workflow](docs/diagrams/master_workflow.svg)

<details>
<summary><b>View Detailed Subsystem Diagrams (Bootstrapping, Sniffer, Multi-Protocol Engine, FFmpeg Studio &amp; Vault)</b></summary>

#### Bootstrapping &amp; Tier Entitlement

![Bootstrapping &amp; Tier Entitlement](docs/diagrams/bootstrapping_flow.svg)

#### Multi-Protocol Download Engine Lifecycle

![Multi-Protocol Download Engine Lifecycle](docs/diagrams/download_engine_lifecycle.svg)

</details>

---

---

## Why Mobile Downloader Browser?

- **Catch Media While Browsing** — Automatically hook DOM, `fetch`/`XHR`, media elements, and resource streams without manual copy-pasting.
- **Survive Real-World CDNs** — Retains session cookies, Referer, custom User-Agents, and WebView-bound fetch routines for WAF/Cloudflare-protected hosts.
- **Finish the Job Reliably** — Pause/resume, multi-chunk HTTP, HLS segment fetching + AES-128 decryption, TS→MP4 remuxing, foreground service protection, and auto-categorization.
- **Modern Nordic UI** — Samsung-style browser chrome, tab groups, customizable capture tray, and dark/light Nordic Glass themes.

---

## Key Features

| Feature | Description |
|---------|-------------|
| **Segmented HTTP Downloads** | Multi-threaded range requests, speed limiter, auto-retry, stall detection, auto-classification, and SHA-256 verification. |
| **HLS & DASH Streaming** | Master/media playlist parsing, representation extraction, AES-128 decryption, fMP4/TS segment validation, and native `MediaMuxer` TS→MP4 remuxing. |
| **Native BitTorrent** | BitTorrent and magnet link intake powered by high-performance native `libtorrent` bindings. |
| **In-App Browser & Sniffer** | Multi-tab support, Samsung-style tab groups, User-Agent switcher, element picker adblock rules, cosmetic block engine, and capture tray. |
| **Hybrid Adblock** | Native C++ adblock engine (`libaurora_adblock.so`: domain trie + Aho-Corasick) with Dart fallback. |
| **In-App Player** | Custom video player with full-screen controls, aspect-ratio toggles, speed controls, and automatic header/cookie passthrough. |

---


---


---


---

## Build Channels & Distribution

This repository is the Play Store release line. The open-source fat-APK edition
(GitHub releases / F-Droid / sideload) is maintained separately at
[github.com/52191314/Aurora_Download_Manager](https://github.com/52191314/Aurora_Download_Manager).

| Channel | App Branding & Distribution |
|---------|-----------------------------|
| **Play Store** | **Aurora: Browser & Downloader** — Google Play release with Play Billing one-time unlock and on-demand Play Feature Modules. |

### Build Commands

```bash
# Debug build (fat APK)
flutter build apk --debug

# Release build for Play Store (AAB)
flutter build appbundle --release --dart-define=AURORA_LICENSE_URL=https://ahjie521.store/license
```

---

## Requirements & License

- **Flutter SDK**: Dart `^3.8.1`
- **Android SDK**: Min API **24**, Compile API **36**, NDK **27.0.12077973**
- **License**: [GNU General Public License v3.0](LICENSE)

*Disclaimer: Mobile Downloader Browser is a general-purpose download and browsing tool. Users are responsible for complying with applicable laws and site terms of service.*

