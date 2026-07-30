# Session: Public repo local-only cleanup

### 2026-07-17 19:21 — User command

> *Ok, remove what we should from remove, keep them local only. Do it also for agent docs, design/roadmap, trckers. My point is keeping the repo clean because this is what people fork/clone.*

- **Agent:** Grok 4.5
- **Task:** Untrack maintainer-only paths (agents, design/roadmap, trackers, tests, tools, logs/junk) via git rm --cached; expand .gitignore so they stay local; keep Play/build surface tracked; trim dead README links.
