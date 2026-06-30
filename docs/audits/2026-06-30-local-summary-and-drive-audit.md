# Audit — On-device call summaries + Drive shared-with-me (2026-06-30)

Covers the new **Summary/Transcript tabs + local meeting summarizer** and the **Google Drive
"shared with me" scooping** shipped this session. Reviewed in parallel by 3 Codex passes
(`-s read-only`, high reasoning) + a `swift-macos-sme` subagent + 2 model-selection research agents.

## Local model decision (verified)

Two independent research passes both concluded **Qwen2.5-Instruct is the right family** for
transcript → clean Markdown summary + owner-tagged action-item JSON on Ollama. Default raised
**7B → `qwen2.5:14b`** for deeper insight (the founder's M4 Max / 128 GB has the headroom; ~10–15 s
per call, invisible for a background pass). `qwen2.5:7b` stays as the low-RAM fallback; the CLI
subscription (Opus) is the one-click premium tier above both.

Hardening that came out of the research (all applied to `OllamaSummarizer`):
- **`num_ctx: 16384`** — Ollama's 2048 default would have *silently truncated* long transcripts.
- **Grammar-constrained `format`** = the full JSON schema object (field-level guarantee), with a
  retry that downgrades to bare `"json"` if a build rejects the object form.
- `temperature: 0`, `repeat_penalty: 1.1`, `num_predict: 3072`, one retry.

**Empirically verified end-to-end** on a real 361-utterance call: valid schema JSON, a clean
`## `-sectioned summary with bold lead terms, and correctly owner-tagged action items.

## Battery / lifecycle (founder requirement: "won't nuke battery, kicks on and off well")

`SummaryScheduler` is the single funnel for every summary pass. Both reviewers confirmed **no path
to two concurrent generations** (MainActor + single `drain()` + `pumping` flag). Findings fixed:

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| C1/C2 | CRITICAL | "Pause" on Low Power Mode / critical thermal actually **dropped** the queue; only a relaunch recovered it | Keep `auto`/`queuedAuto` intact on pause; observe `NSProcessInfoPowerStateDidChange` + `thermalStateDidChange` and `pump()` the instant power recovers — true pause/resume, no relaunch |
| H1 | HIGH | The 7B **fallback** model was never unloaded (only 14B) — bites the low-RAM Mac that triggers the fallback | `drain()` unloads every candidate model (14B + 7B) on idle |
| H2/H3 | HIGH | `requestNow` had no dedupe; a meeting could sit in both `auto` and `priority` → same 14B pass run twice | `requestNow` dedupes (workingOn + priority) and supersedes a pending auto entry; auto branch re-checks `needsAutoSummary` |
| — | — | model resident between bursts | short `keep_alive: "60s"` bridges a batch, hard-unload on drain (SME called this the correct Apple-Silicon tradeoff) |

Result: one summary at a time, paused on battery saver and resumed automatically, every model
evicted when idle, never the same call summarized twice.

## Summary feature wiring

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | HIGH | Transcribed-media imports never queued a summary (only text/paste did) | `runTranscription` now calls `summarizeInBackground` |
| 2 | HIGH | Regenerate **appended** action items → reworded duplicates piled up | `setSummaryTasks` replaces OPEN summary-derived tasks (keyed `sum:`), preserves completed ones |
| 5 | MED | Task toggle updated the UI even if the DB write changed nothing | `setTaskStatus` returns changed-Bool; UI updates only on success, else reloads |
| 4 | MED | Gemini's non-cloud "Generate" button would wipe a cloud summary back to notes | Gemini shows only "Summarize with AI" |
| 6 | LOW | `CALLBRAIN_FIND` didn't switch to the Transcript tab | switches when pre-filling find |

## Google Drive "shared with me"

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | HIGH | `sharedWithMe=true` pulled the **entire shared corpus**; any shared Google Doc could import as a fake meeting | Query narrowed to recordings + docs/text at the API; `DriveAPI.isLikelyMeeting` post-filter keeps only recordings + meeting-named docs |
| 3 | HIGH | Files marked synced even if the import job failed to persist → dropped forever | `enqueueFilesReturningQueued` → mark synced ONLY what actually queued |
| 4 | MED | Launch auto-sync gated on `folderID` only → shared-only setups never synced on relaunch | gate on `hasFolder \|\| includeShared` |
| 5 | MED | `disconnect()` didn't stop an in-flight `syncNow` | `guard connected else { break }` in the loop + before enqueue/persist |
| 2 | MED | Shared pagination caps at 2000/12 pages silently | accepted — the mimeType narrowing makes truncation of meeting artifacts implausible |

## Verification
- `swift build` clean · `swift test` 167/167 green (+4 new: summary-task reconcile, task-status
  change report, shared-query narrowing, `isLikelyMeeting`).
- Local summarizer proven end-to-end against real founder data (then test row removed; `PRAGMA
  foreign_key_check` clean).
