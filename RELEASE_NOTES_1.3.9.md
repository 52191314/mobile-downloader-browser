# Aurora Download Manager — Release Notes v1.3.9 (Build 88)

Release 1.3.9 introduces high-performance native BitTorrent engine improvements and an optimized lightweight media processing pipeline.

## Key Changes

### Native BitTorrent Engine (In-House FFI)
* Direct C-FFI bindings to native Rasterbar BitTorrent core, eliminating intermediate plugin overhead and lowering memory consumption.
* Maintained full 16 KB memory page size alignment for Android 15/16 64-bit and 32-bit targets.
* High-throughput piece hashing and speed limit controls.

### Lightweight Media & Scriptlet Stack
* Optimized dynamic FFmpeg module with reduced bundle size.
* Fast stream remuxing, HLS parsing, and container conversions.
* Cleanroom high-performance in-house adblock scriptlet engine.

### Licensing & Compliance
* Full commercial proprietary compliance with all GPL-encumbered wrappers eliminated.
* Integrated comprehensive third-party open-source attribution in `THIRD_PARTY_NOTICES.md`.
