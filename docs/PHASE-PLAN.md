# CallBrain — Phased Build Plan

> Companion to `ARCHITECTURE.md`. **Path-B oriented:** the core capture→index→ask loop works at Phase 1; everything after is depth + polish. **Every phase ends with a Codex audit gate** — `codex exec -s read-only` over the branch diff against a written checklist (a second pair of eyes, per the founder's standing rule). Workstreams marked **∥** are parallelizable within a phase. Each phase ships behind a feature branch and is only "done" after its Codex gate is green and any HIGH findings are fixed.

**Audit protocol (every phase):** build green → eval/tests green → `codex exec -s read-only` review of the diff + the phase checklist → fix HIGH/CRITICAL → re-review if needed → mark phase complete in the ledger (§Ledger) → memory note updated.

---

## Phase 0 — Foundations & Ground-Truth Verification
- **Goal:** stand up the Swift project + the custom SQLite, and prove every external assumption against *real* artifacts before building on it.
- **Deliverables:**
  - **∥A** Xcode project (macOS 26, Swift 6 strict concurrency) + SPM deps wired: **GRDB** (custom SQLite build), **WhisperKit**, **FluidAudio**, **swift-embeddings**, **swift-subprocess**, **Sparkle**, (usearch deferred). CI + a **grep-gate** banning `--bare`, `--dangerously-*`, `ANTHROPIC_API_KEY=`.
  - **∥B** Custom SQLite build proven: FTS5 **and** sqlite-vec compiled into ONE library (`SQLITE_CORE`, static), opens via GRDB, a `vec0` table accepts a 768-float vector + metadata columns and does a KNN query. (Verify gate: §15 custom-build + notarization.)
  - **∥C** **CLI capability probe** harness: run the §5 micro-calls for `claude` 2.1.196 and `codex` 0.142.3, snapshot the JSON envelope shapes, confirm env-scrub forces subscription auth, confirm `--safe-mode --tools ""` answers cleanly + returns schema JSON.
  - **∥D** Embedding bring-up: nomic-embed-text-v1.5 returns a 768-vector for a doc + a query (in-process CoreML target; ollama fallback measured). Confirm query/doc prefixes.
  - **∥E** **Collect ~5 real samples of each source** (Fathom copy, Fireflies JSON, Gemini/Meet Doc, Cluely note, raw Meet `.mp4`); snapshot format fingerprints; verify whether the founder's Drive `Meet Recordings` has sibling Transcript Docs vs Notes-only.
- **Dependencies:** none.
- **Exit:** one real artifact of each available type round-trips through a throwaway parser into the CTM; `claude -p` and `codex exec` each return a clean answer + valid schema JSON; a 768-vector KNN round-trips through the custom-SQLite `vec0` table.
- **Codex gate:** env-isolation correctness (API-key scrub, empty sandbox), the verified-vs-assumed table, the custom-SQLite build flags, grep-gate coverage.

---

## Phase 1 — Core Capture→Index→Ask Loop (MVP, usable this week)
- **Goal:** drop a transcript → ask a cited question. The loop genuinely works.
- **Deliverables:**
  - **∥A** Parsers for the 2 formats the founder has most (**Fireflies JSON + Fathom copy**) → CTM normalize → speaker-turn **chunker** (512/128/768).
  - **∥B** **CallBrainDB** (GRDB): the canonical schema (§8) + FTS5 triggers + the `vec_chunks__nomic__v1` `vec0` table; write path (relational + FTS5 + vector).
  - **∥B** **SearchEngine**: hybrid retrieval — FTS5 BM25 ⊕ vector, **selectivity-routed (D6)** exact path, RRF (k=60), refusal/weak gates, citation validator.
  - **∥C** **EmbeddingActor** (nomic in-process) + **LLMRunner Claude adapter** (`complete` + `complete_json` + streaming) with env-scrub + injection-inert flags.
  - **∥D** Minimal SwiftUI shell: **Ask AI** (streaming + tappable citations), **Meetings** list, **Meeting Detail**, **Transcript Viewer** (jump-to-citation). **General Ask + Person** modes with the full citation envelope + real refusal on no-evidence.
- **Dependencies:** Phase 0.
- **Exit:** "What did Travis say about Render?" → correct cited answer with tap-to-jump anchors; a no-evidence question **refuses**; "compute provider" (semantic) surfaces Render/OpenRouter chunks; exact "Render" (keyword) ranks literal chunks #1.
- **Codex gate:** citation enforcement (no claim without a chunk), pre-filter correctness (date/speaker actually applied — the D6 exact path returns all in-scope golds), refusal-before-generation, actor isolation (no `@MainActor` blocking on DB/vector/subprocess).

---

## Phase 2 — Ingestion Intelligence & Durable Pipeline
- **Goal:** "just detect and do the right thing" for every source, idempotently, never silently.
- **Deliverables:** full **3-stage detector** + routing table + Meet sibling-pairing; all remaining parsers (Gemini Doc, Cluely, SRT/VTT, generic) tolerant + per-file confidence + **fingerprint learning**; metadata auto-heal + filename normalization; hybrid **entity/NER** (NaturalLanguage + gazetteer + LLM-assist); two-tier BLAKE3 idempotency + duplicate-group detection; the full **import state machine** with per-state checkpoints, **durable GRDB job queue**, never-silent-fail wrapper; **Import Queue + needs_review UI**; live progress stream.
- **∥:** (A) detector+router+pairing · (B) remaining parsers+fingerprints · (C) state machine+queue+resumability · (D) entities/NER · (E) Import Queue/needs_review UI.
- **Dependencies:** Phase 1.
- **Exit:** dropping a mixed folder routes each file correctly or parks it with a plain-English reason; crash mid-import resumes from the last checkpoint; re-dropping a file is a no-op.
- **Codex gate:** confidence-gate math (no coin-flip routing), idempotency (no dup meetings, no re-transcribe), state-machine resumability, every exception path → `failed`/`needs_review` (no silent drop).

---

## Phase 3 — Local Transcription Path (raw Google Meet video)
- **Goal:** a raw `.mp4` with no transcript becomes a first-class, diarized, cited meeting — on-device, no torch, credits saved.
- **Deliverables:** AVFoundation → 16 kHz mono; **WhisperKit `large-v3-turbo`** (word ts, VAD) + **FluidAudio** diarization + **midpoint word↔turn alignment** + churn smoothing; `transcript_versions` (local v0 immutable); per-file **"upgrade to cloud transcription"** (Deepgram/AssemblyAI); transcription progress as fraction-of-audio; first-run model download + signature-verify; Apple SpeechTranscriber live/bridge option.
- **∥:** (A) decode+WhisperKit · (B) FluidAudio+alignment · (C) model-asset download/verify · (D) cloud-upgrade hook + version UI.
- **Dependencies:** Phase 2.
- **Exit:** a real raw Meet recording → speaker-labeled, timestamped, citable transcript; cloud upgrade appends v1 without destroying v0; citations re-derive from the active version.
- **Codex gate:** diarization-alignment correctness, `is_inferred_speaker` propagation into citations, model signature verification before use, ANE/CPU resource caps (no UI starvation). **Verify gates: WhisperKit WER + FluidAudio DER on real crypto calls.**

---

## Phase 4 — Retrieval Depth & Anti-Hallucination
- **Goal:** all 8 modes, hard date-gating, action items, and a passing eval harness.
- **Deliverables:** remaining 6 modes (This Week, Company 6-slot, Technical Explainer w/ `explanatory_score`, Action-Item Extractor, Pre-Call Briefing, Post-Call Review); deterministic **query planner** + LLM-fallback; **local-tz date math**; action-item extraction + the reconciled "this week" gate (§7.5); weak-evidence labeling; the full **eval harness** (§15) wired to both adapters; query_logs audit.
- **∥:** (A) modes 2/3/4 · (B) modes 5/6 · (C) modes 7/8 + cross-refs · (D) planner+date math · (E) eval harness + golden corpus.
- **Dependencies:** Phase 1 retrieval; richer with Phases 2–3 data.
- **Exit:** the §15 table passes targets (citation precision ≥0.95, date-gating violations =0, attribution purity =1.0, refusal-correctness =1.0); the 2 negatives refuse.
- **Codex gate:** date-math boundary cases (week_start, DST, undated-task rule), explanatory rerank not leaking general knowledge, no mode delegates a hard filter to the LLM.

---

## Phase 5 — Provider Resilience (Codex adapter, flip-flop, fallback, streaming)
- **Goal:** the founder flips Claude↔Codex at will and never thinks about quotas.
- **Deliverables:** **Codex adapter** (`complete`/`complete_json` via `-o`/`--output-schema`, `--json` streaming); router `which()` + cached availability probes; full **fallback matrix** (rate-limit detection via `rate_limit_event`/`resetsAt` + codex stderr; defer-and-resume; opt-in local-model last-resort for bulk); token-bucket pacing + per-provider concurrency + isolated high-priority interactive lane; streaming bridge with provider+model badge + transparent fallback toast.
- **∥:** (A) Codex adapter · (B) router/availability/fallback · (C) queue pacing/lanes · (D) badge UI.
- **Dependencies:** Phase 1 (Claude adapter + queue).
- **Exit:** a forced Claude rate-limit transparently completes on Codex (badge change + toast); a 300-item backfill never blocks an interactive question; deferred jobs resume after the reset time.
- **Codex gate:** env-scrub on both adapters, rate-limit signal parsing, deadlock-freedom of the concurrency design, grep-gate ban list.

---

## Phase 6 — Native Polish (background, notifications, menu bar, Drive sync, Duplicate Review)
- **Goal:** Path-B premium feel; "set it and forget it."
- **Deliverables:** `beginActivity` to defeat App Nap during jobs; ⌘Q-with-jobs → **MenuBarExtra** background mode; **UserNotifications** (import/transcription complete, failure w/ Retry+Upgrade, **overdue/owed tasks** via `UNCalendarNotificationTrigger` firing even when quit); **Google Drive sync** (OAuth via `ASWebAuthenticationSession`, `Meet Recordings` watch via `drive_file_id` + `change_token`, security-scoped bookmarks); refined **Duplicate Review** UI (signal breakdown, one-tap confirm/reject, reversible).
- **∥:** (A) background+menu bar · (B) notifications+scheduling · (C) Drive sync+OAuth · (D) Duplicate Review UI.
- **Dependencies:** Phases 2 (dedupe, queue), 4 (task gate).
- **Exit:** quitting with jobs keeps them running in the menu bar; an overdue BGIN/Iceriver follow-up notifies while quit; new Drive recordings auto-import; a suggested duplicate is confirmed/undone losslessly.
- **Codex gate:** Keychain ownership (OAuth secret never leaves the app), notification date-gate correctness, Drive token handling, dedupe reversibility.

---

## Phase 7 — Archive Migration (bulk backfill of the real multi-year archive)
- **Goal:** import the founder's real, messy archive end-to-end.
- **Deliverables:** bulk-import driver over `data/raw` + Drive; **throttled pacing** under the 5-hour/weekly windows (local embeddings are free, so only generation/transcription paces); progress dashboard ("Indexing 142/318"); weekly-exhaustion pause ("resumes ~Tue"); duplicate-group resolution pass; **usearch graduation** if the corpus crosses ~250k chunks; post-migration **eval re-run on the real corpus** to tune refusal/`explanatory_score` thresholds from measured data.
- **∥:** (A) migration driver+pacing · (B) progress/reporting+usearch · (C) threshold tuning.
- **Dependencies:** Phases 2–5 (+6 for Drive).
- **Exit:** the entire archive is `done`/`duplicate`/`needs_review`/`awaiting_transcript` with zero silent drops; §15 eval still passes on the real corpus; thresholds locked from data.
- **Codex gate:** quota-safety of the bulk run, no redundant re-transcription, dedupe correctness at scale, tuned thresholds recorded (not hardcoded), selectivity-routing recall at scale.

---

## Phase 8 — Packaging, Signing, Notarization, Auto-update
- **Goal:** a signed, notarized, auto-updating **direct-download** app a non-coder installs by double-click.
- **Deliverables:** Developer-ID sign (leaf-first if any helpers) + entitlements (minimal; set fixed by the §15 MLX-JIT gate) + Hardened Runtime; `notarytool submit --wait` + `stapler staple`; **Sparkle** EdDSA appcast + hosting; `.cbk` backup/restore (`VACUUM INTO` + manifest); first-run wizard (resolve CLI paths, request notification auth, the one-line cloud-generation acknowledgment, model first-run download); static-ffmpeg license clearance (fallback only).
- **∥:** (A) sign+notarize · (B) Sparkle+hosting · (C) backup/restore · (D) first-run wizard.
- **Dependencies:** all prior.
- **Exit:** a clean Mac installs from DMG, passes Gatekeeper, completes first-run, ingests + answers; an auto-update is delivered + applied; restore from `.cbk` reconstructs state; **bundle is tens of MB with zero Python in the `.app`.**
- **Codex gate:** signing/entitlements minimality, notarization of every Mach-O, no secrets/API-key code path in the bundle, model assets downloaded (not bundled) where appropriate.

---

## Progress Ledger
*(Append one row per completed step: what was done · files touched · build/eval result · Codex gate result · any decision. Keep current before moving on — this survives compaction.)*

| Date | Phase/Step | What | Files | Verify | Codex gate | Notes |
|---|---|---|---|---|---|---|
| 2026-06-29 | Design | Two research passes (A: architecture, B: Swift-native stack) → reconciled into `ARCHITECTURE.md` + this plan | docs/ | n/a | n/a | Verdict: Swift-native (D1); privacy not a constraint (D2); sqlite-vec V1 (D5); single embed model (D7) |
| 2026-06-29 | Design | Repo pivoted Python→Swift-native (`Sources/ Tests/ tools/`; removed `backend/`); README rewritten; 9 phases → live TaskList; memory locked | repo root, README.md | n/a | n/a | `tools/` = dev model-prep python only (never shipped) |
| 2026-06-29 | P0 ∥C (start) | Verified ALL critical `claude`/`codex` CLI flags exist on this Mac before building adapters | (probe) | ✅ flags real | — | claude `--safe-mode`/`--tools`/`--json-schema`/`--output-format`/`--include-partial-messages` ✅; codex `--output-schema`/`-o`/`--json`/`-s`/`--ephemeral`/`--skip-git-repo-check` ✅. LLMRunner §5 command lines confirmed buildable. |
| 2026-06-29 | P0/P1 | `CallBrainCore` SwiftPM library + Canonical Transcript Model (`Meeting`/`Utterance`/`TranscriptChunk`/`Citation`, `Codable`+`Sendable`, Swift 6 strict concurrency) | Package.swift · Sources/CallBrainCore/Model/CTM.swift · Tests/CallBrainCoreTests/CTMTests.swift | ✅ `swift build` clean + **5/5 tests green** | (pending phase gate) | First compiled Swift; headless testable core (no Xcode/UI ceremony); deps added per-phase |
