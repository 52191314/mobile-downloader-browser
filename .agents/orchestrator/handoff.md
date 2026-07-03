# Soft Handoff — Orchestrator Succession

## Milestone State
- **M1: Environment Check & Codebase Analysis**: Completed and verified.
- **M2: Core Multi-threaded Downloader (R1)**: Completed, verified, and remediated (no socket/connection leaks, preemption works, tests pass 100%).
- **M3: Browser & Media Sniffer (R2)**: Implemented with custom headers support and adblocker rules. However, the verification subagents returned a `REQUEST_CHANGES` verdict due to critical integration defects and leaks. **Remediation is pending.**
- **M4: Torrent & Magnet Downloader (R3)**: Planned.
- **M5: Google Drive Integration & Sync (R4)**: Planned.
- **M6: Nordic Dark UI & Queue Dashboard (R5)**: Planned.
- **M7: Final Verification & Automated Test Pass (R6)**: Planned.

## Active Subagents
- None. All spawned subagents are currently completed.

## Pending Decisions
- Remediation of Milestone 3 issues. The specific changes requested are:
  1. **Memory Leak**: Add a `dispose()` method to `SnifferScreen` (and `_SnifferScreenState`) to close the sniffer engine's broadcast stream subscription and resources.
  2. **Unbounded Cache**: Implement cache eviction / expiration logic in `MediaSnifferEngine` using a Timer or pruning size limit (e.g. 10-second sliding window or LRU cache) so `_urlCache` doesn't grow infinitely.
  3. **Adblocker Gaps**:
     - Expand the blocked domain list to cover common tracking/ad services (e.g. `ads.yahoo.com`, `doubleclick.net`, `adcolony.com`, `googleads.g.doubleclick.net`, `popads.net`, `adservice.google.com`, etc., at least 15 domains).
     - Fix false positives by checking full host matches rather than `host.contains(adDomain)` which could over-block.
     - Prevent malformed URLs from bypassing the block list in the try-catch block.
     - Render the blocked popup count visually in the UI (e.g., as a badge or indicator in `SnifferScreen`).
  4. **Headers and Filename Mapping**:
     - Ensure browser cookies, Referer, and User-Agent are correctly mapped when converting a `SniffedMedia` item to a `DownloadTask` inside `SnifferScreen` or the download dialog.
     - Support extracting filenames from HTTP `Content-Disposition` headers in the sniffer engine, rather than only relying on the URL path.
  5. **Analyzer Lints**: Resolve 6 dart analyzer lints/warnings in the new sniffer code.

## Remaining Work
The successor should execute the following:
1. Spawn a fresh Worker subagent to implement the Milestone 3 remediation fixes outlined above.
2. Run verification loop for Milestone 3 (spawning 2 Reviewers, 2 Challengers, 1 Forensic Auditor) to verify that the fixes compile, pass all tests (including the new adblocking/popup/deduplication stress tests), and have a CLEAN audit status.
3. Proceed to Milestone 4 (Torrent & Magnet Downloader).

## Key Artifacts
- Plan: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\orchestrator\plan.md`
- Progress: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\orchestrator\progress.md`
- Briefing: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\orchestrator\BRIEFING.md`
- Original request: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\orchestrator\ORIGINAL_REQUEST.md`
