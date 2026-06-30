# CallBrain — Architecture (Canonical v1)

> **This is THE source of truth for the build.** It reconciles two research passes:
> - `docs/research/passA-architecture.md` — deep system logic (detection, routing, CTM, retrieval, citation contract, date-gating, DDL, dedupe, AI modes, eval). *All of this logic is kept.*
> - `docs/research/passB-stack-decision.md` — the Apple-Silicon best-in-class component bake-off + the **Swift-native-first** verdict + the buttery-smooth performance playbook + on-device verify gates.
>
> Where the two conflict, **this document wins.** Pass A was written assuming a Python sidecar; that runtime is dropped (§0). Everything else from Pass A is preserved and re-expressed in Swift.

---

## 0. Reconciliation Decisions (the deltas — read this first)

| # | Decision | Rationale |
|---|---|---|
| **D1** | **Runtime = 100% Swift-native. No Python in the shipped app. No FastAPI, no sidecar, no localhost port, no handshake.** Pass A's pipeline/retrieval/CLI-provider/dedupe **logic** is kept and re-expressed as Swift actors. | Pass A's only justification for Python was "the ML stack is Python-native." Pass B proved that false for 2025-2026 Apple Silicon: transcription (WhisperKit), diarization (FluidAudio — the one thing that used to force Python), embeddings (CoreML/MLX), vectors (sqlite-vec/usearch) all have native options; the LLM is a subprocess either way. Result: tens-of-MB bundle, **<1s launch, low RAM, clean notarization, buttery** — exactly what the founder demanded. |
| **D2** | **Privacy is NOT a product constraint** (founder, 2026-06-29). Cloud LLM generation is fine. **Dropped:** redaction pass, per-answer egress disclosure UI, on-device "Private mode." **Kept:** one honest Settings line. | Founder: "I don't care about privacy… use all the AI you want." Other tools already process/store everything. This *removes* a subsystem and simplifies the app. |
| **D3** | **Local stays only for COST + SPEED, never privacy.** Local transcription avoids burning transcription credits; local embeddings are free + make search instant. Cloud transcription is a one-click per-file upgrade when it parses better. | Transcript-first ingestion means we rarely transcribe at all; when we do, local-by-default protects credits, cloud-on-demand protects quality. |
| **D4** | **LLM generation = `claude -p` ⇄ `codex exec` subprocess** (the founder's CLI subscriptions, flip-floppable), driven from a Swift `Subprocess` actor. Env-scrubbed → subscription auth, tool-stripped, sandboxed. **Identical command lines to Pass A §5** (verified live). | This is a cost decision (no paid API keys), unaffected by D1/D2. The exact verified flags carry over verbatim. |
| **D5** | **V1 storage = ONE SQLite database** (GRDB custom build) holding relational tables **+ FTS5** (keyword) **+ sqlite-vec** (vectors) compiled into a single custom SQLite library (`SQLITE_CORE`, static, no loadable extension → notarizes clean). **usearch (HNSW)** graduates in only when the corpus exceeds ~250k chunks (Pass B). | Pass A used LanceDB for pre-filtered ANN; Pass B flagged HNSW filtered-recall hazards + the loadable-extension notarization trap. One-file sqlite-vec is exact, correct under hard filters, trivially backed up, and the simplest thing that is correct at MVP scale. See §8. |
| **D6** | **Retrieval hard-filter guarantee via selectivity routing.** Hard filters (date/speaker/company) resolve to a candidate `chunk_id` set in SQL **first**; selective queries → **exact brute-force vector scan** over that subset (no recall loss — this is the "only Travis / this week" case); broad queries → ANN. | Resolves Pass B's #1 retrieval risk (HNSW silently drops in-scope results under selective metadata filters) while keeping Pass A's "filters are a hard guarantee, never delegated to the LLM" cardinal rule. See §7. |
| **D7** | **One embedding model for BOTH query and documents** (never mix models → mixing = different vector spaces = broken retrieval). **V1 default: `nomic-embed-text-v1.5`** (768-dim, 8192-ctx, fits our 512–768-token chunks), run **in-process** (CoreML/ANE via `swift-embeddings`; `ollama` is the zero-effort fallback). ANE-resident = always-warm = instant search. **Qwen3-Embedding-0.6B (MLX)** is an optional *whole-corpus* quality re-embed. | Both passes independently converged on nomic as the sane default (Pass A for ctx-fit, Pass B as the ANE-resident butter option). A single model keeps query/doc spaces consistent — a correctness requirement. See §11. |
| **D8** | **Transcription = WhisperKit** (CoreML/ANE) default; **Apple SpeechTranscriber** the live/low-power option; cloud (Deepgram/AssemblyAI) the per-file upgrade. **Diarization = FluidAudio** (CoreML/ANE). Both **only** for raw video lacking a transcript. | Pass B best-in-class, native, no torch. Carries Pass A's word↔turn alignment + version-immutability logic. See §10. |

Everything below is the reconciled, Swift-native design. Confidence markers (HIGH/MED/LOW) and the **VERIFY-ON-DEVICE** gates from Pass B §6 are preserved in §15.

---

## 1. What CallBrain Is

A private, **local-first macOS** meeting-intelligence app — a personal meeting memory over months/years of (crypto / decentralized-AI) work calls. It ingests scattered call material (Fathom, Fireflies, Cluely, Google Meet, Drive), auto-detects and normalizes each source, transcribes only what must be, indexes everything, and answers questions with **hard citations** (meeting, date, speaker, timestamp, tap-to-jump). It does task extraction, pre-call briefings, and post-call reviews. The founder is a non-coder who wants it fully automatic: *"detect and do the right thing."*

**The core promise (Fireflies-grade catalogue search, but yours + cited):** instant **keyword/filter** search across the whole archive **fused** with **AI semantic + answer** search — see §7. The app must feel **native and buttery** for daily use (§12, §15).

---

## 2. Architecture Verdict & System Diagram

**Verdict: single Swift-native macOS app (no Python).** Engines are actor-isolated off `@MainActor`; the only out-of-process calls are subprocesses (`claude`/`codex`; `ffmpeg` only if AVFoundation can't decode a container). LLM generation uses the founder's CLI subscriptions.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  CallBrain.app  —  SwiftUI (macOS 26, Swift 6 strict concurrency)               │
│                                                                                │
│  Views (12 screens) ── @Observable @MainActor view models                      │
│        │  (Sendable value snapshots only cross actor boundaries)               │
│        ▼                                                                        │
│  ┌───────────────────────────── Engine actors (off main) ──────────────────┐  │
│  │ IngestEngine   SearchEngine    EmbeddingActor   TranscriptionActor       │  │
│  │ (detect/route/ (FTS5 ⊕ vec →   (nomic CoreML/   (WhisperKit + FluidAudio │  │
│  │  parse/chunk)   RRF → gates)     ANE, in-proc)    — raw video only)       │  │
│  │ JobQueue (GRDB-backed, durable, resumable)   LLMRunner (subprocess actor)│  │
│  └───────────────┬───────────────────────────────┬─────────────────────────┘  │
│                  ▼                                ▼                             │
│   ┌──────────────────────────────┐   ┌─────────────────────────────────────┐  │
│   │  ONE SQLite DB (GRDB, WAL)    │   │ claude -p --safe-mode --tools ""     │  │
│   │  • relational (source of      │   │ codex exec -s read-only ...          │  │
│   │    truth)                     │   │ (env-scrubbed → subscription auth,   │  │
│   │  • FTS5 (keyword/BM25)        │   │  tool-stripped, injection-inert)     │  │
│   │  • sqlite-vec (vectors)       │   └─────────────────────────────────────┘  │
│   │  [usearch HNSW file = ANN     │   ┌─────────────────────────────────────┐  │
│   │   cache once >250k chunks]    │   │ Local model assets (first-run DL):   │  │
│   └──────────────────────────────┘   │ WhisperKit, FluidAudio, nomic CoreML │  │
│                                       └─────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Data flow (capture → ask):** file/paste → **detect** → **route** → (parse | transcribe+diarize) → normalize to **CTM** → **chunk** → **embed** (nomic, in-proc) → write SQLite (relational + FTS5 + sqlite-vec) → user asks → **QueryPlan** → **hybrid retrieve** (FTS5 ⊕ vector, selectivity-routed, hard-filtered) → **RRF** fuse → **evidence/refusal gates** → assemble cited context → **LLMRunner** (`claude`/`codex`) → **citation validator** → answer envelope → SwiftUI renders with tappable citations.

---

## 3. Component Stack (final, Swift-native)

| Layer | Choice | Pin / notes | Why |
|---|---|---|---|
| OS / language | macOS 26, SwiftUI, Swift 6 strict concurrency | 26.5.1 arm64, Swift 6.3.2 | Native feel; actor isolation keeps engines off `@MainActor`. |
| SQL + source of truth | **SQLite via GRDB** (custom build) | WAL, FTS5, sqlite-vec compiled in (`SQLITE_CORE`) | One durable file; lose-nothing; FTS5 BM25 for exact crypto jargon. |
| Keyword search | **SQLite FTS5** (`porter unicode61 remove_diacritics 2`) | in the custom build | Exact tokens ("Iceriver", "Proof of Logits"). |
| Vector store (V1) | **sqlite-vec** (`vec0`) in the same DB | static-compiled (Pass B §5B) | Exact brute-force, correct under hard filters, one-file backup. |
| Vector store (scale) | **usearch** (HNSW, Swift SPM) | graduates >~250k chunks | Real ANN at scale; rebuildable cache over the SQLite truth. |
| Fusion | Reciprocal Rank Fusion, k=60 | mode-tunable weights | Score-agnostic merge of BM25 + cosine. |
| Embeddings | **nomic-embed-text-v1.5** (768-dim, 8192-ctx) in-process (CoreML/ANE via `swift-embeddings`) | `ollama` fallback; same model for query+doc (D7) | Free, always-warm = instant search; fits our chunks. |
| Embeddings (upgrade) | **Qwen3-Embedding-0.6B** via MLX-Swift | optional whole-corpus re-embed | Higher MTEB; behind a re-embed toggle. |
| LLM generation | **`claude` CLI + `codex` CLI** (subscriptions) | claude 2.1.196, codex 0.142.3 | No API keys; hot-swappable behind `LLMRunner` (§5). |
| LLM (last-resort, opt-in) | local model via MLX/`ollama` | default-off, bulk only | When both subscriptions are rate-limited. |
| Transcription | **WhisperKit** `large-v3-turbo` (CoreML/ANE) | first-run model DL; Apple **SpeechTranscriber** live option | Raw video only; on-device, no torch. |
| Diarization | **FluidAudio** (`community-1`, CoreML/ANE) | first-run model DL | Raw video only; pyannote-grade, no Python. |
| Audio/video decode | **AVFoundation / AudioToolbox** first | static `ffmpeg` only as signed CLI helper for exotic containers | Native decode; ffmpeg is a fallback, not a dependency. |
| Hashing | **BLAKE3** | `file_hash`, `content_fingerprint` | Fast dedupe keys on large media. |
| NER | NaturalLanguage (Apple) + domain gazetteer; LLM-assist via `LLMRunner` | — | PERSON/ORG + crypto vocab; degrades to gazetteer-only. |
| Packaging | Developer-ID sign + notarize + **Sparkle** (EdDSA) delta updates | Team 559YM79ZCA, **direct-download only** | Tens-of-MB; trivial notarization (no Python). |

---

## 4. Source Matrix & Transcript-First Ingestion

Governing rule (Constraint): **if a usable transcript exists, parse it; only a raw `.mp4` with no sibling transcript is transcribed.** All sources normalize to one Canonical Transcript Model (§6). The `ts_confidence` ladder (`exact > coarse > derived > none`) powers honest citations.

*(Full per-source table, auto-detect signatures, and the "verify against real artifacts in Phase 0" list are in `docs/research/passA-architecture.md §4`. Summary below.)*

| Source | Artifact | Speakers | Timestamps | Detect signature |
|---|---|---|---|---|
| Google Meet — Transcript Doc (Gemini/Workspace) | Google Doc → HTML export | Yes | Coarse (~5-min) | in `Meet Recordings`, title `… - Transcript`, "computer generated" footer |
| Google Meet — Gemini Notes | Google Doc (summary) | Partial | — | title `… - Notes by Gemini` — *secondary signal, never the transcript* |
| Google Meet — recording | `.mp4` | No | — | `Meet Recordings`; transcribe **only if no sibling Doc** |
| Fathom (FREE) | clipboard plain text | Yes | Exact `H:MM:SS` | `fathom.video` URL or `Name H:MM:SS` blocks |
| Fireflies | `.json`/`.srt`/`.vtt`/`.txt` (+ free GraphQL API) | Yes | Exact seconds | JSON `sentences[].speaker_name+start_time` |
| Cluely | clipboard plain text | Yes | likely none (verify) | speaker-labeled prose |
| Generic SRT/VTT | subtitle cues | rarely | exact | `WEBVTT` / SRT cue format |

**Citation hard rule:** a citation is emittable only when `title` + `date` + `speaker` + (`t_start` OR a transcript anchor offset) all exist. No fabricated `00:00`.

**Meet routing (core auto-decision):** for each `.mp4`, search the same Drive folder for a sibling Doc by title-stem + date (±few min). Sibling Doc → parse Doc, **skip transcription**. No Doc → queue local WhisperKit. *(MED — the #1 thing to verify against the founder's real Drive, §16.)*

---

## 5. LLMRunner — generation over the Claude & Codex CLIs (Swift)

**Thesis (unchanged from Pass A §5):** treat each CLI as a dumb, sandboxed, stateless **text endpoint**. We use none of its agentic loop/tools/memory/MCP/config. Pass a fully-formed prompt in, get one final text (or one JSON object) out, discard the process. All retrieval, prompt assembly, and citation enforcement live in our Swift engines. Driven from a **`LLMRunner` actor** wrapping `Subprocess` (swift-subprocess / `Process`) with `AsyncSequence` stdout for streaming + structured cancellation.

**Env scrub (every child):** delete `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `OPENAI_API_KEY`, `OPENAI_BASE_URL` → forces subscription/OAuth auth. Empty sandbox cwd (`…/Application Support/CallBrain/cli-sandbox/`, no `.git`/`CLAUDE.md`/`AGENTS.md`). Prompt (chunks + question) piped on **stdin** (avoids `ARG_MAX`); retrieval budget ≈150k tokens.

### 5.1 Claude adapter — exact command lines (verified live, Pass A §5.2)
Base: `claude -p --model <sonnet|opus> --safe-mode --tools "" --strict-mcp-config --no-session-persistence --permission-mode default --system-prompt "$SYSTEM"`
- **RAG answer:** `… --output-format json` → parse `.result`; model badge = key of `.modelUsage`.
- **Structured extraction:** `… --output-format json --json-schema "$SCHEMA"` → read `.structured_output` (schema-validated, `additionalProperties:false`).
- **Live chat (streaming):** `… --output-format stream-json --verbose --include-partial-messages` → emit a token per `content_block_delta.text`; emit a rate-limit signal on `rate_limit_event` (capture `resetsAt`); finalize on `result`. **Claude is the only true token-streamer.**
- **Never** `--bare` (it reads auth only from `ANTHROPIC_API_KEY` → breaks subscription, Pass A C3). **Never** `--dangerously-skip-permissions` (CI grep-gate bans it).

### 5.2 Codex adapter — exact command lines (verified live, Pass A §5.3)
Base: `codex exec -s read-only --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules -C "$SANDBOX" -m gpt-5.5 -c model_reasoning_effort="<low|medium>" -c preferred_auth_method="chatgpt" -` (prompt on stdin; pin effort `low`=extraction / `medium`=RAG — default `xhigh` is too slow).
- **RAG:** add `-o "$OUTFILE"`; answer = pristine `$OUTFILE` (never scrape stdout banner).
- **Extraction:** add `--output-schema "$SCHEMA_FILE" -o "$OUTFILE"`.
- **Streaming:** add `--json`; push each `item.completed`(`agent_message`) as one chunk (Codex emits whole items, no token deltas).

### 5.3 JSON extraction, selection, throttling, fallback (Pass A §5.4–5.6, carried)
- **Parse+repair:** native schema output → validate → extract balanced `{…}` (normalize CRLF first) → local `json-repair` equivalent → one LLM repair retry → **fail closed to `needs_review`** (never silently drop).
- **Provider policy (one Settings toggle):** `default=claude|codex`, `per_call_override`, fallback flags, `ollama_lastresort=false`. Ask-AI box has a provider chip.
- **Durable GRDB job queue:** `job(id,kind,payload,provider_pref,state,attempts,not_before,last_error)`; states `queued→running→done|needs_review|deferred`; survives restarts; per-provider concurrency limits; **interactive Ask-AI on a separate high-priority lane** so a 300-file backfill never blocks a question; token-bucket pacing under the 5-hour/weekly windows; exp backoff.
- **Fallback matrix:** transient → retry; Claude rate-limited (`rate_limit_event`/`resetsAt`) → Codex; Codex rate-limited (exit≠0 + `/429|quota|rate limit/i`) → Claude; both limited → opt-in local model (bulk only) else **defer** with "resumes ~3:40 PM"; **empty retrieval → refuse before any CLI call** (never spend quota to say "I don't know"). Transparent toast on fallback.
- **Safety / injection:** `--tools ""` + `--strict-mcp-config` + `--safe-mode` (Claude) / `-s read-only` + `--ignore-*` (Codex) → an injected "run rm -rf"/"email X" from transcript text has **no tool to call**. Chunks wrapped in per-request random delimiters labeled DATA-not-instructions; output rendered/validated, never `eval`'d.

---

## 6. Ingestion Intelligence (Pass A §6, carried; Swift)

**North star:** zero configuration, never silently guess wrong. Every item is auto-handled with high confidence **or** parked in an explicit `needs_review` queue with a plain-English reason. **Deterministic-first, LLM-last.** Full detail (3-stage detector, routing table, normalization rules, PersonResolver, entity/topic graph, metadata auto-heal) lives in `docs/research/passA-architecture.md §6`. Key points:

- **Detection (3 stages):** (A) container sniff — magic bytes are truth, extension is a hint (a `.txt` that's really MP4 is MP4); (B) source classification by structural signature, score-all-pick-max-with-margin; (C) confidence gate — `score<0.55` → `needs_review("unrecognized")`, `top−second<0.15` → `needs_review("ambiguous: X or Y")`; one-click override **teaches the fingerprint store**.
- **Routing:** transcript-present → PARSE; media+sibling transcript → PARSE+ATTACH (`media_ref`); raw media, no transcript → TRANSCRIBE (local WhisperKit+FluidAudio); user upgrade → TRANSCRIBE (cloud), append `version N` (local v0 never deleted).
- **Canonical Transcript Model (CTM):** Meeting + ordered Utterances `{speaker, speaker_confidence, t_start, t_end, text, is_inferred_speaker, ts_confidence}`. Speaker labels normalized to canonical `person_id` (alias → folded match → per-meeting hints → LLM-assist gated by confidence; below threshold → `null` + "who is Speaker 2?" chip). Explicit labels → confidence 1.0; diarized → posterior, `is_inferred_speaker=true` (answers footnote weak attributions).
- **Chunking (citation-stable):** built from merged utterances, never split across a speaker change unless a monologue exceeds the cap. **~512 tokens, 128 overlap, hard cap 768** (embedding tokenizer; fits nomic's 8192). Stable `chunk_id = f(meeting_id, version, seq-range)` so re-embeds never break citations. `explanatory_score` (0–1) precomputed at ingest (up-weights definitional turns "which means…", "is defined as…") for Technical Explainer mode. Each chunk carries the full citation envelope + `callbrain://meeting/<id>?t=742.30` deep link.
- **Import state machine (durable, resumable, never-silent-fail):** `queued→detecting→[extracting_audio→transcribing]→normalizing→extracting_meta→extracting_entities→chunking→embedding→summarizing→done | duplicate | failed | needs_review`. Two-tier BLAKE3 idempotency (`file_hash` of bytes → instant re-drop dedupe; `content_fingerprint` of normalized text → same-meeting-via-two-sources group). Per-state content-addressed checkpoints → resume reuses completed work; **transcription never re-run if its artifact validates.** Every exception → structured `ImportFailure {state, class, human_msg, technical_msg, retryable}`; transient→backoff, permanent→`failed`, ambiguous→`needs_review`. No path drops a file silently.

---

## 7. Hybrid Retrieval & Anti-Hallucination (Pass A §7, carried + D6)

**Cardinal rule:** structured guarantees ("this week", "what Travis said") are enforced by **deterministic SQL/vector filters over structured metadata — never delegated to the LLM.** The model only writes prose over a pre-filtered, pre-cited evidence set, and that output is validated before display.

### 7.1 Pipeline (exact order)
```
NL query + UI mode + local_tz
 → [1] QUERY PLAN {date,person,company,topic,call_type,source,action_only,mode,terms,boosts}  (deterministic ~90%; LLM-fallback for ambiguous, schema-validated)
 → build ONE hard-filter predicate P (whitelisted columns/operators + typed bound values; no NL→SQL)
 → [2] resolve in-scope chunk set via SQL using P
 → [3] SELECTIVITY ROUTING (D6):
        selective (small in-scope set)  → EXACT brute-force cosine over those vectors (sqlite-vec)   ⊕  FTS5 BM25 over P
        broad     (large in-scope set)  → ANN (sqlite-vec / usearch) prefiltered by P                 ⊕  FTS5 BM25 over P
 → [4] RRF fuse (k=60)
 → [5] gates: raw-evidence refusal floor · near-dup suppression (same-meeting cos≥0.97 → keep best source, fold into also_in_sources) · per-meeting diversity cap (≤3) · mode rerank/boost
 → [6] numbered [S1..Sn] evidence blocks with full citation metadata
 → [7] generate (LLMRunner: claude | codex)
 → [8] citation validator (every claim → valid [S#]; strip/flag/refuse)
 → answer envelope
```
**Why D6 selectivity routing:** exact brute-force over a SQL-filtered subset is correct *and* fast precisely in the selective case ("only Travis, only this week") where HNSW pre-filtering silently under-returns. ANN is used only when the filter is broad (where its recall is fine). This makes the hard-filter guarantee unconditional. RRF is **ordering only**; the refusal decision uses raw evidence (max cosine + BM25 presence), never RRF.

### 7.2 The two kinds of search, fused (the "Fireflies catalogue" promise)
- **Keyword/catalogue lane (FTS5/BM25):** exact tokens + structured filters → instant "find every call mentioning Iceriver / by Travis / last week." No AI.
- **Semantic lane (vector):** meaning-based recall ("compute provider" → finds Render/OpenRouter without the literal phrase).
- **RRF** fuses them so the catalogue search *and* the AI search are one box. Mode-tunable weights (Person/Action lean lexical `w_fts 1.3`; Technical Explainer leans vector `w_vec 1.3`).

### 7.3 The 8 AI modes
*(Full filter/boost/prompt/output table in `passA-architecture.md §7.5`.)* General Ask · This Week · Person (hard `speaker` filter → misattribution structurally impossible) · Partner/Company (6 slots: said / want / can-offer / open-questions / next-steps / inferred-strategy — only the last synthesizes) · Technical Explainer (`explanatory_score` rerank, "based only on your calls", names gaps) · Action-Item Extractor (date-gated, §7.5) · Pre-Call Briefing · Post-Call Review.

### 7.4 Citation contract (strict envelope)
`{mode, status: answered|weak_evidence|no_sources, answer_markdown, claims[{claim_id,text,type:confirmed|inferred,evidence_strength,citation_ids}], citations[{citation_id,chunk_id,meeting_id,meeting_title,meeting_date,speaker,t_start,t_end,source,also_in_sources,quote,transcript_anchor}], action_items[], unanswered[], filters_applied, refusal_reason}`. Every citation carries **title + date + speaker + timestamp + chunk_id + clickable anchor**; `[S#]` are tap targets that scroll the transcript to the cited line.

**Generation invariants (every mode):** use ONLY the SOURCES; tag every factual sentence `[S#]`; separate CONFIRMED vs INFERRED; if unanswerable output exactly `NO_SOURCED_EVIDENCE`; never invent speakers/dates/numbers/quotes; quote verbatim.

**Post-gen validator (deterministic):** extract `[S#]` per claim; unsupported claims quarantined (if >20% of factual sentences → downgrade status + strip); dangling tags dropped; quoted sentences fuzzy-matched (≥0.9) against the cited chunk (fail → demote confirmed→inferred or strip); everything stripped → refusal envelope.

**Refusal/weak gates (raw evidence, not RRF):** refuse (`no_sources`) when the candidate set is empty after hard filters **OR** (`max_cos<0.35 AND no BM25 hit`), with a filter-specific message ("No indexed call has Travis discussing Render"). Weak (`weak_evidence`) when above floor but `max_cos<0.55` and ≤1 chunk → answered but banner-labeled "thin evidence." Thresholds are config, tuned on the §15 corpus.

### 7.5 Action-item "this week" hard gate (local-tz, reconciled)
A task is current-this-week iff:
```
(due_epoch IS NOT NULL AND due_epoch ∈ this_week)                              -- explicit due this week, even from an old call (cite it)
 OR (due_epoch IS NULL AND meeting_epoch ∈ this_week AND status != 'done')     -- fresh undated task
```
An **old undated** task is **never** "this week." `owner_role=NULL` → "owner: unclear" (never silently "me"). `due_epoch=NULL` → "due: not specified." Recurring tasks consolidated by text+owner+company but **every source citation kept with dates.** Week bounds computed by the app from *today* in **local IANA tz** (half-open `[start,end)`, default Monday/ISO-8601, user-switchable), never inferred by the model.

---

## 8. Data Model (Pass A §8 DDL, carried; LanceDB→sqlite-vec)

**Principles (unchanged):** SQLite is the source of truth; the vector index is a rebuildable derivative; **TEXT UUIDv7 PKs** (time-ordered, merge-safe); normalize what's filtered, denormalize summary JSON (rebuilt in one txn so it can't drift); **dual dates** (UTC text + generated epoch columns for range scans); **link-not-delete** on dedupe; timestamps UTC, rendered local.

PRAGMAs: `journal_mode=WAL; synchronous=NORMAL; foreign_keys=ON; busy_timeout=5000; temp_store=MEMORY; cache_size=-65536; wal_autocheckpoint=1000`.

**The full canonical DDL** (tables: `schema_migrations, settings, participants, companies, tags, entities, meetings, meeting_participants, meeting_companies, meeting_tags, transcript_chunks, entity_mentions, action_items, imports, files, duplicate_links, embeddings, query_logs` + FTS5 virtual tables + triggers) is in **`docs/research/passA-architecture.md §8.1`** and is adopted **verbatim**, with these **adaptations**:

- **Vector store = sqlite-vec, not LanceDB.** Replace the LanceDB per-space table (§8.2) with a sqlite-vec `vec0` virtual table per embedding space:
  ```sql
  CREATE VIRTUAL TABLE vec_chunks__nomic__v1 USING vec0(
    chunk_id TEXT PRIMARY KEY,
    embedding FLOAT[768],
    -- auxiliary metadata columns for fast hard pre-filtering inside the vec scan:
    +meeting_id TEXT, +date_epoch INTEGER, +start_epoch INTEGER,
    +speaker TEXT, +company TEXT, +source TEXT, +call_type TEXT,
    +is_action_item INTEGER, +action_due_epoch INTEGER, +is_canonical INTEGER,
    +explanatory_score FLOAT
  );
  ```
  The `embeddings` registry table (1:1 with `transcript_chunks`, with `space, model_id, dim, content_hash, embed_version`) is retained and now points at the `vec0` rowid instead of a LanceDB id. Re-embed on `content_hash` mismatch (single-row delete+insert). **Model/version change = new `vec_chunks__<model>__v<n>` table, atomic flip of `settings.active_embedding_space`** (instant rollback). The hard-filter predicate P is applied as a `WHERE` over the `+`-prefixed metadata columns (exact, no recall loss).
- **`embeddings.vector_id`** stores the `vec0` rowid; `transcript_chunks.embedding_id → embeddings.embedding_id → vec0 rowid`.
- **usearch (scale):** when a space exceeds ~250k chunks, build a usearch HNSW file as an ANN cache keyed by `chunk_id`, rebuilt from the `vec0`/`embeddings` truth; selectivity routing (D6) still sends selective queries to the exact `vec0` path.
- **All Swift access via GRDB** over the custom SQLite build (FTS5 + sqlite-vec compiled in, `SQLITE_CORE` static — Pass B §5B). Migrations forward-only, numbered, transactional; `VACUUM INTO 'premigrate-vN.sqlite3'` before each batch.

**Dedupe engine (Pass A §8.3, carried):** weighted composite over signals (`s_filehash, s_date, s_participants, s_title, s_duration, s_transcript [chunk-vector cosine ∨ MinHash on first ~800 words], s_filename`); `auto_link` only ≥0.92 + ≥2 strong signals + **hard false-merge gates** (`s_participants<0.5` / `|Δdate|>24h` / conflicting event-id → never auto-link, so "Weekly Travis Sync" never collapses across weeks); 0.75–0.92 → **Duplicate Review** (human confirm); **link-not-delete** (`status='merged_into', canonical_id=…`, fully reversible). Canonical priority: transcript+speakers+timestamps > +speakers > transcript-only > summary > A/V-only.

**Storage layout** `~/Library/Application Support/CallBrain/`: `data/raw/{fathom,fireflies,cluely,gmeet_recordings,manual}/` (immutable originals) · `data/processed/{transcripts,audio,metadata}/` · `database/callbrain.sqlite3` (+wal/shm) · `models/{whisperkit,fluidaudio,nomic}/` · `data/exports/` (`.cbk` backups) · `runtime/`. Canonical managed-copy filename `YYYY-MM-DD - People - Company/Topic - Source.ext` (UUID is real identity). **Backup = one `.cbk`** (zstd tar of `VACUUM INTO` snapshot + `processed/` + manifest; vectors are derivable → optional). Drive sync (later) layers on `files.drive_file_id` + `imports.drive_change_token`.

---

## 9. Native App & Performance (Pass A §9.1 + Pass B §4)

**App architecture (Swift 6 strict concurrency):** view models `@MainActor @Observable`; engines are **actors off the main actor**; all DTOs `Codable, Sendable`; only `Sendable` value snapshots cross boundaries. **12 screens via one `NavigationSplitView`** (9 sidebar destinations + 3 detail/secondary): Home, Ask AI (⌘⇧A), Meetings (3-column), Meeting Detail, Transcript Viewer (tear-off window + ⌘F), Tasks (⌘⇧T), People, Partners/Companies, Topics, Import Queue (badge), Duplicate Review (sheet), Settings (⌘,). Shortcuts: ⌘K palette, ⌘⇧A, ⌘⇧T, ⌘N import, ⌘F in-transcript, ⌘R reprocess, ⌘,. Drag-drop via `.dropDestination(for: URL.self)` → hand paths to `IngestEngine` (no copy). Streaming Ask-AI consumed from the `LLMRunner` `AsyncStream`; import progress via an `AsyncStream` from `JobQueue`.

**Buttery-smooth playbook (Pass B §4 — the three laws):** (1) render only what's on screen — `body` cost never scales with archive size; (2) the main actor only diffs views — all DB/vector/FTS/subprocess/markdown work on an actor; (3) invalidate at the property, not the object (`@Observable` per row). Per-surface:
- **Meetings list:** `List`/`Table` with light `Equatable Sendable` rows keyed on stable id; **page the data (never `SELECT *`)**, GRDB date-bucketed pages at a bottom sentinel; thumbnails decoded off-main + downsampled.
- **Transcript viewer (10k+ utterances — the risk surface):** primary = **AppKit `NSTableView` via `NSViewRepresentable`** (cell reuse reliably hits frame budget); highlight ranges computed off-main as per-row `NSAttributedString`; pre-measured row heights. Try-first SwiftUI `LazyVStack` only if Animation-Hitches passes at 10k rows; else escalate to `NSTableView`.
- **Ask-AI streaming:** coalesce token writes to display cadence (~16–33 ms), render append-only plain text while streaming, parse Markdown only at closed-block boundaries (no flicker).
- **Cmd-K search:** `.task(id: query)` cancels in-flight; ~150–250 ms debounce; FTS5 + vector off-main; the query-embedder is ANE-resident/always-warm (D7) so first post-idle search is instant.
- **Launch/RAM:** no eager graph at `App.init`; warm DB/index in a post-first-frame `.task` behind a skeleton; engines lazy-created. **Targets (Instruments, Release, ≥2-yr seeded archive): cold launch <1s · idle RAM <150 MB · zero hangs >250 ms · transcript fling within frame budget (8.3 ms @120Hz / 16.6 ms @60Hz) · warm search <250 ms · first token <150 ms.**

---

## 10. Transcription & Diarization (raw video only)

Only a raw `.mp4` with **no** sibling transcript reaches this path. **Decode audio with AVFoundation → 16 kHz mono.** Default **WhisperKit `large-v3-turbo`** (CoreML/ANE, word timestamps, VAD chunking for hours-long files) + **FluidAudio** offline `community-1` diarization (CoreML/ANE); align words↔speaker turns by **midpoint interval intersection** (assign each word to the speaker segment containing its midpoint; tie-break to max overlap); run transcription + diarization in parallel, then merge; median-filter diarization churn before utterance-merge. `transcript_versions` keeps local **v0 immutable**; the per-file **"upgrade to cloud transcription"** action (Deepgram/AssemblyAI) appends `v1` without destroying `v0`; citations re-derive from the active version. Models downloaded + signature-verified on first raw-video detection (first-run/offline caveat → §15 gates). Apple **SpeechTranscriber** is the live/low-power option (and the bridge while WhisperKit downloads). Rationale = **save transcription credits** (D3), not privacy.

---

## 11. Embeddings (single model, in-process, consistent)

**One model for query and documents** (D7) — mixing models = incompatible vector spaces = broken retrieval. **V1 default: `nomic-embed-text-v1.5`** (768-dim, 8192-ctx; task prefixes `search_document:` / `search_query:`), run **in-process** via `swift-embeddings` (CoreML, ANE-resident → always warm → instant search). `ollama` (`/api/embeddings`, `num_ctx:8192` asserted) is the zero-effort fallback if the Swift CoreML path needs more bake time. The `embeddings` registry + per-space `vec0` table (§8) make re-embedding cheap and citation-stable. **Quality upgrade:** `Qwen3-Embedding-0.6B` via MLX-Swift as an optional **whole-corpus** re-embed (new space, atomic flip) — both query and doc re-embed together to keep the space consistent. The choice between nomic-default and Qwen3-default is settled by the §15 on-device recall@10 + butter benchmark.

---

## 12. Packaging & Distribution

Pure-Swift app → **Developer-ID signed + notarized + stapled**, **direct-download only** (never App Store — founder hard rule), **Sparkle** EdDSA appcast for tens-of-MB delta updates. No Python runtime, no PyInstaller, no torch → notarization is trivial vs Pass A's Python-bundle minefield. **Hardened Runtime YES, App Sandbox NO** (the app spawns `claude`/`codex` from `~/.local/bin` & `/opt/homebrew/bin` and reads user files). **Entitlement set is determined by the §15 MLX-JIT gate** — if the embedding runtime needs `allow-jit`/`allow-unsigned-executable-memory`, switch the default to the entitlement-free CoreML path. **PATH gotcha (HIGH):** Finder-launched apps don't inherit shell `PATH`; resolve CLIs by probing absolute paths + one-time `zsh -lic 'command -v claude codex'`, persist + allow Settings override, pass a curated child `PATH` (also lets `codex` find `node`). `ffmpeg`: AVFoundation-first; a static arm64 `ffmpeg` is bundled (signed) only as a fallback for exotic containers.

---

## 13. Privacy & Security (simplified per D2)

- **Not privacy-first** (founder). Cloud LLM generation is expected and fine. **One honest Settings line:** "Answers use your Claude/ChatGPT subscription, a cloud service; relevant transcript excerpts are sent there to generate the answer." No redaction pass, no Private-mode, no per-answer egress UI.
- **The genuine security bits that remain:** (1) **no generation/embedding API keys exist** — env-scrub forces subscription auth; (2) **injection-inert CLIs** — `--tools ""`/`-s read-only`, transcript text is DATA not instructions (§5.3); (3) **CI grep-gate** bans `--bare`, `--dangerously-*`, and any `ANTHROPIC_API_KEY=` in the provider code; (4) the **only real secret** is the future Google OAuth refresh token (Drive sync), stored in the login **Keychain** (`com.callbrain.app`), owned by the Swift app.

---

## 14. Repo Structure (Swift-native) & Build Order

The Python `backend/` layout from Pass A §13 is **replaced**. New layout:
```
CallBrain/
├── CallBrain.xcodeproj  (or Package.swift workspace)
├── Sources/
│   ├── CallBrainApp/        # SwiftUI: App, Commands, the 12 screens, @Observable VMs, Design tokens
│   ├── CallBrainCore/       # engines: Ingest, Search, Embedding, Transcription, JobQueue, LLMRunner — actors
│   ├── CallBrainDB/         # GRDB models, migrations, custom-SQLite (FTS5 + sqlite-vec) build config
│   ├── Ingest/              # detect/ parse/(fireflies,fathom,gmeet,cluely,srt_vtt) normalize/ chunk/ entities/
│   ├── Retrieve/            # plan, datemath, fts, vector, rrf, gates, dedupe
│   ├── Answer/              # modes/(8) prompts, citations, validator, envelope
│   └── Providers/           # ClaudeRunner, CodexRunner, router, json-repair, availability
├── Tests/                   # unit + eval harness + fixtures (real-sample snapshots, injection payloads)
├── tools/                   # dev/model-prep ONLY (Python ok here, never shipped): MLX quantize, CoreML convert, embedding parity
├── scripts/                 # sign.sh notarize.sh appcast.sh dev_run.sh
├── docs/                    # ARCHITECTURE.md (this), PHASE-PLAN.md, research/
└── data/                    # (gitignored) raw/ processed/ database/ models/ exports/
```
The **phased build plan** (Path-B, with a Codex audit gate per phase) is in **`docs/PHASE-PLAN.md`**.

---

## 15. Eval Tests + On-Device Verify Gates

**Eval harness (Pass A §15, carried):** each fixture `{query, expected_plan, gold_chunk_ids, assertions}`; the harness runs plan→retrieve→generate→validate against **both** adapters. **Release-blocking targets: citation precision ≥0.95 · date-gating violations =0 · speaker-attribution purity =1.0 · refusal-correctness =1.0.** The 12 canonical questions (Travis/Render, Max/Proof-of-Logits, this-week actions, BGIN/Iceriver follow-ups, ASIC mentions, explain validators, ask-Travis-next, exact "Render", semantic "compute provider", two-source dedupe, + 2 negatives that **must refuse**) are in `passA-architecture.md §15` with per-row success criteria.

**Verify-on-device gates (Pass B §6, must pass before locking each):**
- [ ] WhisperKit `large-v3-turbo` on a real 2–3 hr Meet file: RAM, wall-clock, RTF, word-timestamp drift; **WER on 3–5 real crypto calls** is the binding quality bar (not clean-read benchmarks).
- [ ] FluidAudio offline `community-1` **DER on real crypto calls** (crosstalk, accents) — benchmark DER is not representative; spot-check turn boundaries + speaker count. Escalation: tune → cloud upgrade → (last resort) opt-in pyannote helper (never bundled).
- [ ] **Embedding runtime entitlement:** confirm the CoreML/MLX embedding path notarizes + runs under Hardened Runtime with **no** `allow-jit`/`allow-unsigned-executable-memory`; if MLX needs it, default to the CoreML path (§11/§12).
- [ ] **Custom SQLite build:** FTS5 + sqlite-vec coexist in ONE statically-compiled library, register via `SQLITE_CORE`, load under Hardened Runtime + notarization with **no** loadable-extension prompt (Pass B §5B).
- [ ] **Selectivity-routed retrieval (D6):** recall@10 under realistic predicate selectivity (single-meeting, narrow date range) — confirm the exact brute-force path returns all in-scope golds; confirm the sqlite-vec→usearch graduation threshold (~250k).
- [ ] Embedding throughput + RAM at scale (to ~1M chunks); cold-vs-warm first-query latency → sets the §9 warm policy; numerical parity (cosine ≥0.999 vs reference) on a probe set.
- [ ] GRDB+WAL durability: kill mid-index → SQLite recovers, vector index rebuilds from truth.
- [ ] Full Instruments table green (§9) on the pinned Mac + display with a ≥2-yr seeded archive.
- [ ] Clean Developer-ID sign + notarize + Sparkle delta, models downloading on first run, tens-of-MB bundle, **zero Python in the `.app`.**

---

## 16. Open Questions for the Founder (non-blocking — I proceed on defaults)

1. **Does your "Meet premium" save a verbatim *Transcript* Doc beside each recording, or only *Gemini Notes*?** Verbatim Docs → most Meet calls skip transcription; Notes-only → those route to local WhisperKit. *I'll confirm against your real Drive in Phase 0; the app handles both either way.*
2. **Which sources dominate your archive — mostly Fathom, mostly Fireflies, or a real mix?** Decides which two parsers I build first for the usable-this-week MVP. *(You said: mix, with Fathom going forward + Drive videos. Default: build Fireflies-JSON + Fathom-copy parsers first.)*
3. **Default generation provider — Claude or Codex — to start?** *(Default: Claude; you flip per-call or globally anytime.)*
4. **Drive sync now or later?** Only feature needing a Google OAuth secret. *(Default: drag-drop/paste first, Drive in a later phase — no architectural change.)*

*Privacy question intentionally removed per D2.*
