# Aurora Downloader 1.0.1 — release notes

Build 54 · Play Store release · 2026-08-08

## What's new

- **Torrent downloads now save to your Downloads folder automatically when
  they finish** — including multi-file torrents, which previously completed
  in the background but never appeared in Downloads (fixed: completed
  torrents stuck at 100% with "Couldn't publish" errors).
- **Torrent tasks no longer offer "Force merge"** — it could never succeed
  for engine-based downloads; use Resume or Redownload instead.
- **Optimized for Android devices with 16 KB memory page sizes** (required
  for new Play releases; fully backwards-compatible with existing 4 KB
  devices). Native libraries re-aligned and verified on both ABIs.
- **Faster download queue** — progress bars and speeds update individually
  instead of redrawing the whole list; smoother scrolling with many
  concurrent downloads.
- **Less notification spam** — progress notifications throttle to once per
  second instead of every tick.
- **Faster, more reliable Vault** — encryption/decryption is now streaming;
  large vault exports and restores no longer freeze the app or run out of
  memory.
- **Smaller app** — bundled font subset (~500 KB/install) and unused code
  removed; upload is ~6% smaller.

## Technical

- perf(notify): throttled progress notification shows (P8)
- perf(queue): per-card progress notifiers + state-aware rebuilds; shell
  timer dropped (P1b/P2/P13)
- size(font): Inter variable font subset 876→373 KB + regeneration tooling (S1)
- chore: dropped dead deps qr_flutter / animations / dynamic_color (S6)
- fix(vault): streaming AES-256-GCM off the UI isolate (P10)
- fix(torrent): auto-classification no longer diverges task.savePath from
  the engine's save dir; folder publishing; force-merge hidden for engine
  tasks
- fix(tooling): align_elf_16k.py ELF32 phdr field-order bug (16 KB
  alignment for armeabi-v7a was silently skipped)
