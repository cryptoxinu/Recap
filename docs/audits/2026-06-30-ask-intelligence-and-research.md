# Post-build iteration — Ask intelligence, web research, UX fixes (2026-06-30)

Founder-driven refinement pass after BUILD COMPLETE. Each item screenshot- or test-verified.

## Shipped
1. **Auto-import folder watch** (`FolderAutoImport.swift`) — FSEvents watcher; drop a transcript into a
   watched folder (e.g. a Google-Drive-synced "Meet Recordings") → imports itself (~4s, verified live).
   Settings → Auto-import. Seen-set bounded (cap 5000; content-hash dedupe is the backstop).
2. **Transcript-open visual bug fixed** (`MeetingWorkspaceView.swift`) — the nested `HSplitView` honored
   its panes' ideal widths and overflowed the navigation column, clipping the app sidebar off the left.
   Replaced with a width-respecting `GeometryReader`+`HStack` (panes always sum to the available width).
3. **Fireflies-grade answers** (`AskEngine.swift`, `AppEnvironment.swift`) — Claude=opus, Codex=high
   reasoning; restructured system + per-mode prompts (orienting opener, `##`/`###` themed sections,
   **bold** lead terms, defined jargon, comprehensive); deeper adaptive retrieval (`autoTopK`).
4. **Clickable inline citations** (`MarkdownAnswerView.swift`) — `[S#]` is a tap target that opens the
   cited call at that moment; markdown parsed first so **bold** spanning a citation renders correctly.
5. **Real reasoning timeline** — surfaces actual call names ("18 passages across 3 calls · morning sync
   +1 more"); each step fires at a real pipeline boundary.
6. **Multi-turn continuation** (`AskEngine.Turn`, `ChatModel`) — prior turns fed back as context;
   verified: "whose job is it to fix *that*?" resolved "that" to the previous turn's BitRouter issue.
7. **Web research mode** (gated) — globe toggle / "research…online" phrasing → answers from calls + web,
   clearly separated. Works on **both** Claude (`--safe-mode` + WebSearch/WebFetch, hooks/config off) and
   Codex (`-c tools.web_search=true`, `--ignore-user-config`). Injection-hardened: web tools only, no
   Bash/Write/Edit; env scrubbed → subscription auth. Routed via `ProviderRouter` (selector + fallback).
8. **Web-source collapsing** — prose shows clean clickable source names; raw URLs hidden; a collapsed
   "Web sources · N" dropdown; the call-citation list is a collapsed "Sources · N" dropdown too.
9. **Background generation + Stop** (`ChatModel`, `AppEnvironment.askChat`, `Subprocess.run`) — the Ask
   chat lives in the environment, so an in-flight answer survives leaving/returning the tab; a red Stop
   button cancels mid-answer and terminates the CLI subprocess (`withTaskCancellationHandler`).
10. **Light/Dark selector** (`CallBrainApp.swift`) — System/Light/Dark segmented control in the sidebar
    (`.preferredColorScheme`); light mode verified legible.

## SME review (swift-macos-sme) — findings fixed
- **C1 (crash)** — `Process.terminate()` could hit an unlaunched/racing process. Serialized lifecycle in
  `ProcHolder` (`markLaunched` + lock-guarded `terminateIfRunning`/`killIfRunning`).
- **H2 (security)** — web-research had dropped `--safe-mode`, re-enabling the user's hooks/CLAUDE.md/MCP
  in the subprocess. Verified `--safe-mode` still allows WebSearch → restored it.
- **H3 (state corruption)** — Stop-then-resend let a stale task's `defer` clobber the new turn. Added a
  monotonic `generation` token; cleanup/results only apply if still the current generation.
- **H4 (rendering)** — a citation written as a link (`[S1](url)`) wasn't styled. `stripCitationLinks`
  normalizes it before parse.
- **M6** — `retrievalQuery` follow-up enrichment now gates on personal-pronoun anaphors or a short query
  (no more false trigger on "this week").
- **L8** — auto-import seen-set capped.
- **M7** — research system prompt now tells the model not to paste private call content into web queries.
- **Verified FINE by SME:** FolderWatch Unmanaged lifetime, ProviderRouter web cast, research empty-hits,
  GeometryReader width, weak-self capture, Codex read-only web path.
- **Deferred (cosmetic/rare):** M5 — a web URL containing parens can truncate in the dropdown link.

## Verification
- `swift build` clean; `swift test` → **139 tests, 32 suites green** (4 new: history/retrievalQuery/
  research-intent, researchArgs, codex baseArgs reasoning).
- Live in-app: Claude research (13 sources), Codex research (14 sources), multi-turn continuity, web-source
  dropdown, Stop button, light mode — all screenshot-verified.
