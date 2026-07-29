# Session: Playwright & Chrome Troubleshooting

### 2026-07-17 16:11 — User command

> *Does AGENTS.md tell how to use playwright, grok keep saying Chrome is not installed]*

- **Agent:** Gemini 3.5 Flash (High)
- **Task:** Answer user's query about AGENTS.md contents and explain how to resolve the Playwright "Chrome is not installed" issue.

### 2026-07-17 16:15 — User command

> *No, I wanna run headless in whichever chrome*

- **Agent:** Gemini 3.5 Flash (High)
- **Task:** Explain how to configure Playwright to run headless with whichever Chrome/Chromium is available and how to install the required binaries.

### 2026-07-17 16:16 — User command

> *Fix it*

- **Agent:** Gemini 3.5 Flash (High)
- **Task:** Add `HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe` registry keys pointing to the Playwright Chromium hardlink to satisfy Playwright's channel `'chrome'` checks. Verified that Playwright successfully launches.
