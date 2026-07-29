# Agent notes — Aurora Downloader

## Build channels

The app has two distribution channels controlled by `--dart-define=AURORA_BUILD_CHANNEL`:

| Channel | `--dart-define` | Use case |
|---------|-----------------|----------|
| **play** | `AURORA_BUILD_CHANNEL=play` | Google Play Store release (enables Play Billing for Pro; FFmpeg as on-demand module) |
| **github** | (default) | GitHub / F-Droid / sideload builds (no billing; FFmpeg in fat APK) |

### Release AAB for Play Store

```bash
flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play
```

The release AAB at `build/app/outputs/bundle/release/app-release.aab` is signed with `upload-keystore.jks` when `android/key.properties` is present. This file is gitignored.

The FFmpeg native library (~10 MB) is **not** included in the base AAB — it is downloaded on-demand from Play Store when the user first opens FFmpeg Studio (Ultra tier only). See `docs/play_on_demand_modules_plan.md`.

### Debug APK for local testing

Debug/profile APK builds are always **fat** (FFmpeg included). The on-demand module only activates for release AAB builds with `AURORA_BUILD_CHANNEL=play`.

```bash
flutter build apk --debug
# or with Play Billing for testing:
flutter build apk --debug --dart-define=AURORA_BUILD_CHANNEL=play
# Optional: disable first-launch app tour (product default is ON):
flutter run --dart-define=AURORA_BUILD_CHANNEL=github --dart-define=AURORA_ENABLE_ONBOARDING=false
```

Default channel is `github` so open-source / sideload builds never ship a billing client by accident.
First install auto-shows the interactive app tour; system permissions wait until the tour is finished or skipped.

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes_tool` or `query_graph_tool` instead of Grep
- **Understanding impact**: `get_impact_radius_tool` instead of manually tracing imports
- **Code review**: `detect_changes_tool` + `get_review_context_tool` instead of reading entire files
- **Finding relationships**: `query_graph_tool` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview_tool` + `list_communities_tool`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
| ------ | ---------- |
| `detect_changes_tool` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context_tool` | Need source snippets for review — token-efficient |
| `get_impact_radius_tool` | Understanding blast radius of a change |
| `get_affected_flows_tool` | Finding which execution paths are impacted |
| `query_graph_tool` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes_tool` | Finding functions/classes by name or keyword |
| `get_architecture_overview_tool` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes_tool` for code review.
3. Use `get_affected_flows_tool` to understand impact.
4. Use `query_graph_tool` pattern="tests_for" to check coverage.
