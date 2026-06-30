# CallBrain — Master State (COMPACTION-PROOF · read this first)

> **If you are resuming (post-compaction or fresh session): READ THIS FILE, then the four canonical
> docs below, before touching anything.** This file is the single source of truth for *where we are*.
> Keep it current at the end of every build iteration. Do not let context loss cause scope creep —
> the scope is fixed by `PHASE-PLAN.md`; the rules are fixed by `SESSION-RULES.md`.

## 0. Canonical docs (the law)
- **`docs/SESSION-RULES.md`** — hard rules (no stop, native Swift, production UI, screenshot-verify, Codex-audit each phase).
- **`docs/PHASE-PLAN.md`** — the 9 phases (0–8) with exit criteria + per-phase Codex gate + the **Progress Ledger** (running history).
- **`docs/ARCHITECTURE.md`** — the locked Swift-native design (decisions log in §0).
- **`docs/DESIGN-fireflies-reference.md`** — the UI/UX target (looks like Fireflies; calm, animated, buttery).
- `docs/research/` — the two full design-research passes + critic findings (provenance, never delete).
- Memory anchor: `~/.claude/.../memory/callbrain_project_2026_06_29.md` (+ `MEMORY.md` index line).

## 1. What CallBrain is
A private, **local-first macOS** meeting-intelligence app (a personal RAG over months/years of work
calls) for the founder's job. Capture → organize → search → **ask AI** → extract tasks, with strict
**citations** (meeting · date · speaker · timestamp) and zero hallucination. Must feel like a premium
**Fireflies/Fathom/Otter** app but private + native. Repo: **`/Users/z/CallBrain`** (git, branch `main`).

## 2. Founder context (do not re-ask)
- Founder = **Zade Kal**, new hire at **Ambient** (decentralized-AI / GPU inference: GLM/Gemma models,
  OpenRouter, validators, TEEs, prefill/decode, Bittensor/Shoots, "Proof of Logits", BGIN/Iceriver,
  amp code, Pearl, Mercor). Non-coder; leaning entirely on this to stay organized + keep the job.
- People in his calls: **Max** (Maxwell Lang), **Travis** (Good), **Chris** (Molle), **Gregory**
  (Petrosyan), **Hema** (Kwdi), **Noah** (Pederson), **Ghazal** (Assadipour), JW.
- **Privacy is NOT a constraint** (founder 2026-06-29): cloud LLM generation is fine; local is for
  COST (transcription credits) + SPEED (instant search), not secrecy. No redaction/Private-mode.

## 3. Hard constraints (locked)
1. **100% native Swift** (SwiftUI, Swift 6 strict concurrency). **No Python in the shipped app.**
2. **LLM generation = the founder's CLI subscriptions** (`claude -p` ⇄ `codex exec`), flip-floppable,
   NOT paid API keys. Env-scrubbed → subscription auth; tool-stripped/injection-inert. Embeddings local.
3. **Ingestion is transcript-first + paste-anything** (AI resolves any raw dump).
4. **Apple-Silicon-optimized, buttery-smooth, production-grade** UI (Fireflies look).
5. **Codex audits every completed phase** (`codex exec -s read-only`); **screenshot-verify every UI change**.

## 4. Locked stack (ARCHITECTURE §3)
SwiftUI + Swift 6 actors · **GRDB/SQLite** (source of truth) + **FTS5** (keyword) · **V1 vector =
embeddings-as-BLOB + in-Swift brute-force cosine** (sqlite-vec/usearch graduate at scale) · **RRF**
hybrid fusion + selectivity-routed hard filters · **nomic-embed-text** via **Ollama** (local embeddings)
· **WhisperKit + FluidAudio** for raw-video transcription/diarization (Phase 3, not built yet) ·
**`claude`/`codex` CLI** generation · Developer-ID sign + notarize + Sparkle, **direct-download only**.

## 5. Real data formats LEARNED (calibrated against the founder's actual exports)
- **Fireflies (free)** = COPY-PASTE `Speaker Name: H:MM:SS` then text (NOT JSON; JSON parser kept for
  future premium). Parser: `FirefliesCopyParser`.
- **Google Meet** = **"Notes by Gemini" `.docx`** — a STRUCTURED SUMMARY (title/date/participants/
  sections/bullets + `[Owner] Title: Desc` action items), not a verbatim transcript. Parser:
  `GeminiNotesParser` (operates on extracted text; native Swift `.docx` read = Phase 2).
- **Fathom** = copy `Name  M:SS` / `Name (M:SS):`. Parser: `FathomParser`.
- **Anything else** = `AIImporter`: detect known formats (deterministic) else `claude --json-schema`
  resolves the dump into structured turns + auto-titles it.

## 6. WHAT'S BUILT (✅ done + how verified) — as of 2026-06-30
**Engine (`Sources/CallBrainCore/`, 53 tests green, Codex-audited PASS, live-proven):**
- CTM (Meeting/Utterance/TranscriptChunk/Citation); parsers (FirefliesJSON, FirefliesCopy, Fathom,
  GeminiNotes); Chunker (speaker-turn-aware); GRDB Store (relational + FTS5 + embeddings BLOB);
  VectorMath (cosine/BLOB/topK) + RRF + SearchEngine (hybrid, selectivity-routed); OllamaEmbedder
  (nomic); ClaudeRunner (`claude -p` complete/completeJSON, env-scrub, injection-inert); AskEngine
  (cited answers + refuse-before-LLM); IngestEngine; AIImporter (paste-anything).
- **Live-validated on this Mac:** claude answers · ollama nomic 768-vec · full e2e · the REAL
  "morning sync" Gemini call ("Zade's action items?", "BitRouter status?" → grounded cited answers).
- **Codex gate ran for real:** Pass1 FAIL(6)→fix→Pass2 FAIL(2)→fix→**Pass3 PASS**.

**App (`Sources/CallBrainApp/`, builds clean, screenshot-verified):**
- SwiftUI shell (NavigationSplitView: Home/Ask AI/Meetings/Import/Settings); Home dashboard;
  Ask AI chat (suggested prompts, cited answers, refusal); paste/AI **Import**; **Meetings → Meeting
  Detail → Transcript viewer** (navigable, verified on real seeded morning sync); Settings.
- **Blank-window bug** (ImportView layout collapse) found + fixed; built a CoreGraphics window-id
  screenshot loop (`scratchpad/shot.sh`) — every screen verified rendering.
- Dev tool `cbseed` (ingest a file into a store path to populate the app for screenshot QA).
- Runs as a `.app` bundle (`.build/CallBrain.app`); `swift run CallBrainApp` for dev.

**Commits:** ~18 on `main` (see `git log`). **Tests:** 53 green.

## 7. WHAT WORKS end-to-end (proven)
Paste/import any transcript → detect/AI-resolve → structure + name + index (FTS5 + nomic vectors) →
Ask AI → hybrid retrieve → grounded, cited answer (or honest refusal). Verified live on the founder's
real morning sync.

## 8. WHAT'S LEFT (the remaining scope — do in order, do not creep)
**Phase 1 — ✅ COMPLETE + Codex-gated PASS (2026-06-30):**
- [x] Readable Fireflies-style transcript (persist utterances + turn-by-turn render).
- [x] Markdown Ask answers (headings/bold/bullets + accent `[S#]` chips).
- [x] Home right-side persistent Ask panel (Fireflies two-column) + message animations.
- [x] Navigable citations (tap "Sources" → source call's transcript, scroll+highlight).
- [x] Phase-1 Codex gate: FAIL(2 HIGH)→fixed→PASS. (Streaming moved to **Phase 5** where it belongs.)

**Phase 2** — Ingestion intelligence: full 3-stage auto-detect + routing, all parsers tolerant +
fingerprint-learning, **native Swift `.docx` read** (replace python extract), metadata/entity/NER,
two-tier BLAKE3 idempotency + dedupe, durable job queue + Import Queue/needs-review UI.
**Phase 3** — Local transcription: AVFoundation → WhisperKit + FluidAudio diarization (raw Meet video).
**Phase 4** — Retrieval depth: all 8 AI modes, hard date-gating, action-item extraction → Tasks, eval harness.
**Phase 5** — Provider resilience: Codex adapter + claude↔codex flip + fallback + streaming + quota queue.
**Phase 6** — Native polish: background jobs, notifications (overdue tasks), menu-bar, Google Drive sync, Duplicate Review.
**Phase 7** — Archive migration: bulk backfill of the real multi-year archive, threshold tuning, usearch at scale.
**Phase 8** — Packaging: Developer-ID sign + notarize + Sparkle, `.cbk` backup/restore, first-run wizard.
Each phase ends with a **Codex audit gate** (PHASE-PLAN has the per-phase checklist).

## 9. Transcript-viewer UI requirement (founder, 2026-06-30) — BAKED IN
The transcript must be **easy to read and follow, exactly like Fireflies/Otter**: render **turn-by-turn**
with each speaker's name as a distinct, color-coded label/avatar, the timestamp, and the text in a clean,
well-spaced block — NOT one undifferentiated wall of text. For Gemini *Notes* (a summary, one pseudo-
speaker) render as formatted notes/sections/bullets + an Action Items list (the `[Owner] Title: Desc`),
not a transcript wall. Persist **utterances** (individual turns) and render those, not packed chunks.

## 10. Tooling / how to verify (do NOT ship blind again)
- **Screenshot loop:** `bash scratchpad/shot.sh <out.png>` → builds, wraps `.build/CallBrain.app`,
  launches, finds the window via CoreGraphics (`scratchpad/winid.swift`), captures by id (works behind
  other windows, no focus-steal). Then `Read` the PNG. **Verify every UI change this way.**
- **Populate for QA:** `swift run cbseed "<store>" "<file>" gemini "<title>" "<date>"` (store =
  `~/Library/Application Support/CallBrain/callbrain.sqlite3`).
- **Tests:** `swift test --package-path /Users/z/CallBrain`. **Codex audit:** `codex exec -s read-only
  -C /Users/z/CallBrain ...` (verdict → ledger).
- Prereqs (present): `claude`, `codex` (logged in), `ollama` (running, `nomic-embed-text` pulled),
  Swift 6.3, Xcode. System python 3.14 → backend tooling uses uv-pinned 3.12 (only in `tools/`, never shipped).

## 11. The loop discipline (founder: "don't stop")
Driven by `/loop` (dynamic self-pace). Each iteration: do the next PHASE-PLAN step → screenshot-verify →
`swift test` → Codex-audit at phase boundaries → commit → update the PHASE-PLAN ledger + this file →
`ScheduleWakeup` to continue. Stop only when the whole plan is built + Codex-audited (then PushNotification).
