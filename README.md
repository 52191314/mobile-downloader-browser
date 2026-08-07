# Mobile Downloader Browser

[![CI](https://github.com/52191314/mobile-downloader-browser/actions/workflows/ci.yml/badge.svg)](https://github.com/52191314/mobile-downloader-browser/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android%20%28API%2024%2B%29-green.svg)](https://developer.android.com)
[![Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B.svg?logo=flutter)](https://flutter.dev)

**Mobile Downloader Browser solves the friction of capturing and downloading media on Android.** It seamlessly transforms web browsing into background media capture with an integrated network sniffer, multi-threaded segmented HTTP engine, native HLS/DASH remuxing, and BitTorrent support — all wrapped in a sleek Nordic Glass UI.

> ℹ️ **Branding Note**: This open-source repository and GitHub distribution is titled **Mobile Downloader Browser**. On the Google Play Store, the application retains its published store brand, **`Aurora: Browser & Downloader`**.

---

## ⚡ Quick Start (One Command)

Test, analyze, and spin up Mobile Downloader Browser on your Android device or emulator with a single command:

```bash
git clone https://github.com/52191314/mobile-downloader-browser.git && cd mobile-downloader-browser && flutter pub get && flutter test && flutter run
```

---

## 🏗️ Architecture & Workflows

Mobile Downloader Browser decouples media detection from downloading, running background isolation workers to prevent UI main-thread jank and handling complex protocols seamlessly.

### Master Application Workflow

```mermaid
flowchart TD
    subgraph Launch ["1. App Launch & Bootstrapping"]
        A["App Start main()"] --> B["Initialize Native Bindings & System UI"]
        B --> C["Load SharedPreferences & Local DB Hive/Isar"]
        C --> D["Detect Build Channel (Play Store vs GitHub)"]
        D --> E["Evaluate License & Entitlement Tier (Free / Pro / Ultra)"]
        E --> F{"First Launch / Onboarding?"}
        F -- Yes --> G["Show Interactive App Tour"]
        G --> H["Request System Permissions"]
        F -- No --> H
        H --> I["Start In-App Timers (Watcher, Auto-Backup); Automation API if enabled"]
        I --> J["Render Core App Shell (AuroraDock)"]
    end

    subgraph Navigation ["2. Core Shell & Page Routing"]
        J --> K["Queue Page (Tab 1)"]
        J --> L["Web Browser & Sniffer (Tab 2)"]
        J --> M["Overflow Menu / Popups"]
        M --> N["FFmpeg Studio"]
        M --> O["Secure Vault"]
        M --> P["Aurora Watcher"]
        M --> Q["Settings & Diagnostics"]
    end

    subgraph Sniffer ["3. Browsing & Media Sniffing Engine"]
        L --> R["InAppWebView Navigation"]
        R --> S["AdBlock Engine Interception (FFI Rust)"]
        R --> T["Media Capture Analyzer"]
        T --> U{"Media Stream Detected?"}
        U -- Yes --> V["Enrich Media Metadata & Parse Playlists"]
        V --> W["Show Floating Sniffer Badge & Sheet"]
        W --> X["User Selects Stream Quality / Format"]
        X --> Y["Enqueue to Download Engine"]
    end

    subgraph Downloader ["4. Multi-Protocol Download Engine"]
        Y --> Z["DownloadQueue Task Dispatcher"]
        Z --> AA{"Classify Protocol / Scheme"}
        AA -- HTTP Direct --> AB["DownloadSplitter (Multi-segment Range Requests)"]
        AA -- HLS / m3u8 --> AC["HlsDownloader (ts Segments + Key Decryption)"]
        AA -- DASH / mpd --> AD["DashPlaylistParser (Video/Audio Muxing)"]
        AA -- Torrent / Magnet --> AE["TorrentDownloader (Bencode + Peer Swarm)"]

        AB --> AF["File Combiner & Speed Limiter"]
        AC --> AF
        AD --> AF
        AE --> AF

        AF --> AG{"Download State"}
        AG -- In Progress --> AH["Update Foreground Notification & Speed Meter"]
        AG -- Error / Expiry --> AI["DownloadErrorClassifier & Dead-Link Revival"]
        AI --> Z
        AG -- Completed --> AJ["Notify Completion & Trigger Post-Processing"]
    end

    subgraph Processing ["5. Media Tools & Storage Vault"]
        AJ --> AK{"Post-Download Action"}
        AK -- Encryption --> AL["Move to Encrypted Vault (AES-256)"]
        AK -- Edit / Transcode --> AM["FFmpeg Studio Module Check"]
        AK -- Share / PC --> AN["LAN File Server (Send to PC)"]
        AM --> AO["Execute Native FFmpeg Command"]
    end
```

<details>
<summary><b>🔍 View Detailed Subsystem Diagrams (Bootstrapping, Sniffer, Multi-Protocol Engine, FFmpeg Studio & Vault)</b></summary>

#### Bootstrapping & Tier Entitlement
```mermaid
flowchart TD
    Start(["main() App Entry"]) --> InitFlutter["WidgetsFlutterBinding.ensureInitialized()"]
    InitFlutter --> LoadTheme["Load ThemeNotifier & Accent Pack"]
    LoadTheme --> InitDB["Initialize Local DB & Preferences Store"]

    subgraph ChannelResolution ["Build Channel Resolution"]
        InitDB --> ReadChannel["Read AURORA_BUILD_CHANNEL"]
        ReadChannel --> IsPlay{"Channel is Play Store?"}
        IsPlay -- Yes --> PlaySetup["Set Play Store Mode: Play Billing Active, Dynamic FFmpeg Module On-Demand"]
        IsPlay -- No --> GithubSetup["Set GitHub Mode: Billing Disabled, Fat APK with FFmpeg Included"]
    end

    subgraph LicenseCheck ["Entitlement & License Evaluation"]
        PlaySetup --> EvalTier["ProEntitlementStore.evaluateTier()"]
        GithubSetup --> EvalTier
        EvalTier --> LicenseServerCheck{"Check Aurora License Server / Play Purchase"}
        LicenseServerCheck -- Valid License --> TierResult{"Resolved Tier"}
        LicenseServerCheck -- No License / Free --> TierResult

        TierResult -- Free --> FreeLimits["Apply Free Tier Caps: Capped max parallel downloads, Standard HTTP speed, Basic Sniffer"]
        TierResult -- Pro --> ProUnlocks["Unlock Pro Features: Turbo Engine, AdBlock Native FFI, Dead-Link Revival, Encrypted Vault"]
        TierResult -- Ultra --> UltraUnlocks["Unlock Ultra Features: FFmpeg Studio Suite, Aurora Watcher, Automation API, E2EE Vault Sync"]
    end

    subgraph OnboardingFlow ["First Launch Check"]
        FreeLimits --> CheckFirstLaunch{"Onboarding Enabled AND First Launch?"}
        ProUnlocks --> CheckFirstLaunch
        UltraUnlocks --> CheckFirstLaunch

        CheckFirstLaunch -- Yes --> TourPage["Launch Interactive App Tour"]
        TourPage --> RequestPermissions["Request Storage & Notification Permissions"]
        CheckFirstLaunch -- No --> CheckPerms["Check Existing Permissions"]
        CheckPerms --> RequestPermissions
        RequestPermissions --> StartServices["Start In-App Timers & Automation API (if enabled)"]
        StartServices --> LaunchShell["Launch Core Navigation Shell"]
    end
```

#### Multi-Protocol Download Engine Lifecycle
```mermaid
flowchart TD
    subgraph QueueDispatch ["1. Queue Dispatch & Protocol Handlers"]
        TaskIn["DownloadQueue.enqueue()"] --> ProtocolRouter{"Classify Protocol & File Type"}

        ProtocolRouter -- Direct HTTP/HTTPS --> HTTPHandler["Direct HTTP Engine"]
        ProtocolRouter -- HLS (.m3u8) --> HLSHandler["HlsDownloader Engine"]
        ProtocolRouter -- DASH (.mpd) --> DASHHandler["DashPlaylistParser Engine"]
        ProtocolRouter -- Torrent / Magnet --> TorrentHandler["TorrentDownloader Engine"]
    end

    subgraph DirectHTTPEngine ["2. Direct HTTP Segmented Engine"]
        HTTPHandler --> CheckRange{"Server Supports HTTP Range Headers?"}
        CheckRange -- Yes --> Splitter["DownloadSplitter: Calculate Chunk Byte Ranges based on Threads"]
        CheckRange -- No --> SingleThread["Single-Threaded Stream Download"]

        Splitter --> ParallelChunks["Worker Threads Download Chunks Concurrently"]
        ParallelChunks --> SpeedControl["SpeedLimiter (Rate Limiting if configured)"]
        SpeedControl --> ChunkWrite["Write Chunks to Temp Storage"]
        ChunkWrite --> MergeCheck{"All Chunks Complete?"}
        MergeCheck -- Yes --> FileCombiner["FileCombiner: Stitch Chunks into Final File"]
    end

    subgraph HLSEngine ["3. HLS Stream Downloader"]
        HLSHandler --> FetchPlaylist["Fetch Master & Media Playlist"]
        FetchPlaylist --> CheckEncrypted{"Key Encrypted (#EXT-X-KEY)?"}
        CheckEncrypted -- Yes --> KeyFetcher["HlsDecryptor: Fetch AES Key & IV"]
        CheckEncrypted -- No --> ParseSegments["Extract .ts Segment URLs"]
        KeyFetcher --> ParseSegments

        ParseSegments --> DownloadTS["Fetch .ts Segments Concurrently"]
        DownloadTS --> DecryptTS["Decrypt AES-128 Segments"]
        DecryptTS --> StitchTS["Stitch TS Segments / Transcode to .mp4"]
    end

    subgraph TorrentEngine ["4. BitTorrent Downloader"]
        TorrentHandler --> ParseBencode["BencodeDecoder / Magnet Parser"]
        ParseBencode --> FetchMetadata["Fetch Torrent Metadata & Tracker Announcement"]
        FetchMetadata --> PeerSwarm["Connect to Swarm Peers via DHT"]
        PeerSwarm --> DownloadPieces["Download & Verify Piece Hashes"]
        DownloadPieces --> AssembleTorrent["Assemble Files to Storage Directory"]
    end

    subgraph StateAndRecovery ["5. Execution State & Recovery Loop"]
        SingleThread --> DownloadProgress["Emit Speed, Percent, ETA & Bytes Received"]
        FileCombiner --> DownloadProgress
        StitchTS --> DownloadProgress
        AssembleTorrent --> DownloadProgress

        DownloadProgress --> StateCheck{"Execution Result"}
        StateCheck -- Pause Requested --> PausedState["State: PAUSED (Save Byte Checkpoint)"]
        StateCheck -- Network Error / 403 --> ErrorHandler["DownloadErrorClassifier"]

        ErrorHandler --> ReviveCheck{"Token Refresh Eligible (Pro+)?"}
        ReviveCheck -- Yes --> HeadlessResniffer["TokenRefreshService: Re-sniff Link Headlessly for Fresh Cookies"]
        HeadlessResniffer --> UpdateURL["Update Task Headers & Resume Download"]
        UpdateURL --> ParallelChunks
        ReviveCheck -- No --> FailedState["State: FAILED (User Action Required)"]

        StateCheck -- Success --> CompleteState["State: COMPLETED"]
        CompleteState --> MediaScanner["Register File with Android MediaStore / Storage"]
        MediaScanner --> Notification["Post Completion Notification with Rich Actions"]
    end
```

</details>

---

## ✨ Why Mobile Downloader Browser?

- **Catch Media While Browsing** — Automatically hook DOM, `fetch`/`XHR`, media elements, and resource streams without manual copy-pasting.
- **Survive Real-World CDNs** — Retains session cookies, Referer, custom User-Agents, and WebView-bound fetch routines for WAF/Cloudflare-protected hosts.
- **Finish the Job Reliably** — Pause/resume, multi-chunk HTTP, HLS segment fetching + AES-128 decryption, TS→MP4 remuxing, foreground service protection, and auto-categorization.
- **Modern Nordic UI** — Samsung-style browser chrome, tab groups, customizable capture tray, and dark/light Nordic Glass themes.

---

## 🚀 Key Features

| Feature | Description |
|---------|-------------|
| 📥 **Segmented HTTP Downloads** | Multi-threaded range requests, speed limiter, auto-retry, stall detection, auto-classification, and SHA-256 verification. |
| 🎬 **HLS & DASH Streaming** | Master/media playlist parsing, representation extraction, AES-128 decryption, fMP4/TS segment validation, and native `MediaMuxer` TS→MP4 remuxing. |
| 🧲 **Native BitTorrent** | BitTorrent and magnet link intake powered by high-performance native `libtorrent` bindings. |
| 🌐 **In-App Browser & Sniffer** | Multi-tab support, Samsung-style tab groups, User-Agent switcher, element picker adblock rules, cosmetic block engine, and capture tray. |
| 🛡️ **Hybrid Adblock** | Native C++ adblock engine (`libaurora_adblock.so`: domain trie + Aho-Corasick) with Dart fallback. |
| 🎥 **In-App Player** | Custom video player with full-screen controls, aspect-ratio toggles, speed controls, and automatic header/cookie passthrough. |

---

## 📦 Build Channels & Distribution

Mobile Downloader Browser supports two distinct build configurations controlled by `--dart-define=AURORA_BUILD_CHANNEL`:

| Channel | `--dart-define` | App Branding & Distribution | Use Case & Capabilities |
|---------|-----------------|-----------------------------|-------------------------|
| **GitHub / Open Source** (Default) | `AURORA_BUILD_CHANNEL=github` | **Mobile Downloader Browser** | GitHub releases / F-Droid / Sideload builds. No billing client, fat APK with native engines included, full sniffer enabled. |
| **Play Store** | `AURORA_BUILD_CHANNEL=play` | **Aurora: Browser & Downloader** | Google Play Store release with Play Billing one-time unlock and on-demand Play Feature Modules. |

### Build Commands

```bash
# Debug build (fat APK, default GitHub channel)
flutter build apk --debug --target-platform android-arm64

# Release build for Play Store (AAB)
flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play
```

---

## 🌟 Awesome Ecosystem & Community

Mobile Downloader Browser is designed for developers and open-source enthusiasts. It fits into curated developer indices:

- 💙 **[Awesome Flutter](https://github.com/Solido/awesome-flutter)** — Open-source production Flutter applications.
- 🤖 **[Awesome Android](https://github.com/JStumpp/awesome-android)** — Top open-source Android utilities and download managers.
- 🔓 **[Awesome Open Source Apps](https://github.com/serhii-londar/open-source-mac-os-apps)** — Privacy-respecting mobile tools.

Have a feedback idea or feature request? Join our community discussions on [GitHub Discussions](https://github.com/52191314/mobile-downloader-browser/discussions) or submit issues via the [Issue Tracker](https://github.com/52191314/mobile-downloader-browser/issues).

---

## 🤝 Open for Contributions

We love contributions! Check out our detailed **[CONTRIBUTING.md](CONTRIBUTING.md)** guide to get started.

- 🐛 **[Good First Issues](https://github.com/52191314/mobile-downloader-browser/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)** — Perfect for newcomers looking for quick, high-impact fixes.
- 💡 **[Help Wanted](https://github.com/52191314/mobile-downloader-browser/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)** — Feature requests and sniffer enhancements seeking community pull requests.

---

## 📜 Requirements & License

- **Flutter SDK**: Dart `^3.8.1`
- **Android SDK**: Min API **24**, Compile API **36**, NDK **27.0.12077973**
- **License**: [GNU General Public License v3.0](LICENSE)

*Disclaimer: Mobile Downloader Browser is a general-purpose download and browsing tool. Users are responsible for complying with applicable laws and site terms of service.*

