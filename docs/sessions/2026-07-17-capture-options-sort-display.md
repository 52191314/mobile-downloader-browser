# Session Log — 2026-07-17 Capture Options Sort/Display (PR5)

### 2026-07-17 09:30 — User command

> Key factual statements that derive from web search results/browse page/X searches need to be cited with the render_inline_citation tool.
>
> ## Your PR
> - Title: Capture options: sort and display mode controls
> - Branch: execute-plan/cf9c45ee-pr-5-capture-options-sort-display
> - Base already contains full PR3 Capture redesign.
>
> ## Design
> … Key Decision 25: Re-expose sort + display-mode in Options zone.
>
> ## Requirements
> 1. Implement `CaptureOptionsRow` … Show-all toggle … Sort control … Display mode …
> 2. Host: `sortMedia` / `_sortedMedia` on sniffer_screen should honor settings changes from the sheet
> 3. Display mode should drive row subtitle richness …
> 4. Dead `_SniffedMediaControls` is pattern-only reference — do not delete it here (PR4)
> 5. Persist settings the same way other DownloadSettings fields do
> 6. Tokens only — theme-aware UI matching Capture redesign language

- **Agent:** Grok Build subagent (implementer)
- **Task:** PR5 Capture Options zone — re-expose sort (`sniffedMediaSort`) + display mode (`sniffedMediaDisplayMode`) via new `CaptureOptionsRow`, wire into live Capture sheet pipeline and row subtitles; persist through existing `onSettingsChanged`; keep show-all copy; leave dead `_SniffedMediaControls` in place.
