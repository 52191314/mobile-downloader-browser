## 2026-06-18T06:43:10Z
Fix the critical bugs and resource leaks identified in the Milestone 2 implementation:
1. Download Splitter Early Return Bug: Locate the DownloadSplitter.start() guard condition and the DownloadQueue._schedule() task state change. Fix the deadlock where the queue sets the state to downloading and the splitter returns early because the state is already downloading. Splitter should manage its own state internally, and check an internal boolean _started to prevent double execution.
2. Broken Preemption: In DownloadQueue._preemptTask, ensure splitter.pause() is called BEFORE changing the task state to idle, so that the splitter's pause logic actually executes and cancels background downloads instead of returning early.
3. Resource Leak on Failure: In DownloadSplitter.start(), catch any exceptions thrown during download (e.g. from Future.wait). In the catch block, ensure all active chunk stream subscriptions are cancelled and file handles are closed, so that background chunk downloads don't leak on a single chunk failure.
4. Connection Leak on Probe: In DownloadSplitter, make sure any fallback GET probe request's response stream is consumed or closed (e.g. by draining the stream or calling stream.listen(...).cancel()), to avoid socket connection leaks.
5. Fallback HTTP Status Check: Ensure both multi-chunk range requests (expects status 206) and single-chunk fallback requests (expects status 200) strictly verify the HTTP response status code and throw an exception if an error code (like 404 or 500) is returned.
6. Run `flutter test` to verify that all unit tests, including preemption and pause/resume tests under test/, pass 100%.
7. Create a handoff file at D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\worker_m2_remediation\handoff.md detailing the changes and test results.
8. Send a message to the caller (main agent, id: 3e4d9f3c-76f4-4325-9a43-a009ab5cee90) when completed.
