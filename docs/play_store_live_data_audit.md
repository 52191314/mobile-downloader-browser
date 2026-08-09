# Play Store Live Listing Data — Aurora Download Manager

## Verification Summary

This document records the verified live Play Store data and audit metrics for **Aurora Download Manager** (`com.personal.aurora_downloader`), verified as of August 2026.

---

## 1. App Metadata & Live Status

| Field | Verified Live Value | Notes / Status |
| :--- | :--- | :--- |
| **App Name** | **`Aurora Download Manager`** | Renamed on Play Store (2026-08-08; previously *`Aurora: Browser & Downloader`*) |
| **Package Name** | `com.personal.aurora_downloader` | Official Play Store bundle identifier |
| **Developer Name** | `Ahjie521` | Published developer account |
| **Category** | Tools / Productivity | Primary store category |
| **Content Rating** | Rated 3+ | Unrestricted Internet access, In-App Purchases enabled |
| **Current Live Track** | **Closed Testing** | Active testing track for feedback gathering |
| **Install Count** | **0+ installs** | Pre-launch / early testing phase (zero organic search footprint yet) |
| **Live Version** | **1.0.1 (build 54)** | Updated 2026-08-08. Includes 16 KB ELF memory alignment and Play On-Demand modules |
| **Base Download Size** | **~26 MB** | Base install size for `arm64-v8a` devices (FFmpeg module fetched on-demand) |

---

## 2. Listing Copy & Positioning

### Short Description
> Download manager, ad-free browser, torrents. A queue that never gives up.

### Core Feature Suite Highlighted
1. **Multi-Threaded Segmented Download Engine**: Accelerated HTTP parallel downloading with automatic resume support.
2. **Ad-Free Web Browser**: Integrated Rust-based ad-blocking engine and media sniffer.
3. **Native BitTorrent Client**: Magnet link and `.torrent` file downloading (powered by `libtorrent`).
4. **Encrypted Vault**: Local AES-256 media protection with biometric / PIN unlock.
5. **LAN File Transfer**: Built-in Wi-Fi server to send downloads directly to PC/Mac without cables.
6. **Policy Compliance**: YouTube media capture is disabled on Play Store builds to comply with Developer Distribution Agreements.
