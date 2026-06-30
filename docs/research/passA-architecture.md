# CallBrain — Architecture & Build Plan

> Single source of truth for the build. Synthesized from six design lanes. Where lanes conflicted, the conflict is called out explicitly and a winner is chosen with rationale (see §1.3). Confidence markers (HIGH/MED/LOW) are preserved on third-party claims; items needing real-file verification are gathered in §18 and §16.

---

## 1. Executive Summary & Architecture Verdict

CallBrain is a **private, local-first macOS meeting-intelligence app** — a personal meeting memory that stores, organizes, searches, and answers questions across months of crypto/decentralized-AI work calls, with hard citations, task extraction, pre-call briefings, and post-call reviews. The founder is a non-coder who wants it fully automated: *"detect and do the right thing."*

### 1.1 Architecture verdict — B (SwiftUI + Python sidecar)

| Option | Verdict | One-line reason |
|---|---|---|
| A — pure Swift | **Reject** | The ASR/diarization/embedding/vector/RAG stack (faster-whisper, pyannote, the local embedding model, LanceDB) is Python-native; re-implementing it in Swift is months of fragile work for zero user benefit. |
| **B — SwiftUI + local Python FastAPI sidecar** | **ADOPT** | Premium native macOS feel (menu bar, drag-drop, notifications, `NavigationSplitView`, Dark/Light) **plus** the mature Python ML ecosystem; process isolation keeps heavy jobs from blocking or crashing the UI. |
| C — Electron/Tauri | **Reject** | Still needs the Python ML process, so you pay B's cost *plus* a second non-native runtime; worse integration, non-native feel — fatal for a "premium Fathom" target. |
| D — web-wrapped | **Reject** | Strictly worse than C: web rendering with none of the native affordances the product promises. |

The **sidecar is the engine** (ingestion, ASR, embeddings, vector search, extraction, CLI-LLM orchestration, SQLite/LanceDB). The **Swift app is a thin, beautiful client + process supervisor**. No business logic lives in Swift.

### 1.2 The two defining constraints (stated crisply)

1. **LLM generation backend = the user's existing CLI *subscriptions*, never paid API keys.** Two interchangeable, hot-swappable adapters behind one `LocalCLIProvider` interface: **Claude Code CLI** (`claude -p …`) and **Codex/ChatGPT CLI** (`codex exec …`). Both are driven as **stateless, tool-stripped, sandboxed text endpoints** — we use none of their agentic loop, tools, memory, MCP, or config. API-key env vars are *scrubbed* from each child so the CLIs are forced to use subscription/OAuth auth. (Embeddings are separately, fully local via Ollama — no API of any kind for core function.)

2. **Ingestion is transcript-first.** Fathom, Fireflies, Cluely, and Gemini/Workspace already produce transcripts → we parse + normalize + index them and **never re-transcribe**. **Only a raw Google Meet video with no sibling transcript** is routed to local transcription (faster-whisper + pyannote diarization), with a per-file manual "upgrade to cloud transcription" toggle. Intelligent auto-detection + routing is *the* core feature; the user never picks a path.

### 1.3 Headline stack

SwiftUI (macOS 26, Swift 6 strict concurrency) → supervises → Python 3.12 (pinned via `uv`) FastAPI/uvicorn sidecar over loopback `127.0.0.1:<ephemeral>` with a per-launch bearer token → **SQLite (WAL + FTS5)** as source of truth + **LanceDB** as the derived vector index → **Ollama** `nomic-embed-text` for local embeddings → **`claude -p` / `codex exec`** for generation over subscriptions → **faster-whisper + pyannote** (downloaded Transcription Pack) only for raw video.

### 1.4 Cross-lane conflicts reconciled (winners chosen)

| # | Conflict | Lanes | Winner & rationale |
|---|---|---|---|
| C1 | **Embedding model**: `nomic-embed-text` (768-dim, 8192-ctx) vs `mxbai-embed-large` (1024-dim, 512-ctx) | Retrieval vs Data-Model | **`nomic-embed-text` v1.5 (default).** Our speaker-turn chunks (target 512, cap 768 tokens) routinely exceed mxbai's 512-token ceiling, silently truncating exactly the explanatory chunks the product is graded on. nomic handles 8192 tokens, is 25% smaller on disk, and the small MTEB gap is erased by the BM25 lane + RRF. `mxbai-embed-large` becomes the one-click "higher-quality (≤512-token chunks)" toggle. **Caveat carried forward:** Ollama defaults `num_ctx=2048`; the sidecar must set `num_ctx:8192` explicitly and assert it at startup, and use nomic's `search_document:` / `search_query:` task prefixes. (HIGH on 512-vs-8192; MED on MTEB order.) |
| C2 | **Vector store**: LanceDB vs sqlite-vec | Retrieval + Data-Model vs Native-App | **LanceDB.** Two lanes built deep designs on it (pre-filtering *inside* the ANN via scalar indexes — the mechanism that makes "only Travis, only this week" a hard guarantee; versioned per-space tables for safe re-embed). sqlite-vec was a one-line aside and lacks mature metadata pre-filter + space versioning. SQLite remains canonical truth; LanceDB is a rebuildable index. |
| C3 | **Claude minimizer flag**: `--bare` vs `--safe-mode` | Ingestion (`--bare`) vs LocalCLIProvider (`--safe-mode`) | **`--safe-mode --tools ""`.** `--bare`'s own help states it reads auth *only* from `ANTHROPIC_API_KEY`/apiKeyHelper and "OAuth and keychain are never read" → it would **break subscription auth** and force a paid key, violating Constraint 1. `--safe-mode` strips hooks/MCP/CLAUDE.md/skills **but keeps OAuth**, and `--tools ""` disables all built-in tools. The ingestion lane's `--bare` usage is corrected everywhere. (Verified live.) |
| C4 | **"This week" action gate**: due-in-week OR (undated AND meeting-in-week AND open) vs due-epoch-NOT-NULL-only | Retrieval vs Data-Model | **Retrieval lane's nuanced rule (canonical semantic).** It still satisfies the hard guarantee (an *old* undated task can never appear as "this week") while correctly surfacing a *fresh* undated task from a meeting that happened this week. Data-Model's SQL is the storage mechanism, extended to the OR form. |
| C5 | **Date-gate timezone**: local IANA tz vs UTC week bounds | Retrieval vs Data-Model | **Local IANA tz** (app sends tz with every request; bounds computed on local calendar days then converted to epoch). Matches human perception of "this week," DST-safe. UTC-only would mis-bucket evening/early-morning calls. |
| C6 | **Hash algorithm** | BLAKE3 (Ingestion) vs sha256 (Data-Model DDL columns) | **BLAKE3** for both dedupe keys (`file_hash`, `content_fingerprint`) — faster on large media; columns are TEXT and store `blake3:…`. |
| C7 | **Transcription packaging** | "vendor weights at build" (Ingestion) vs "downloaded Transcription Pack" (Native-App) | **Both, layered:** base app ships light (no torch/whisper); the **Local Transcription Pack** (faster-whisper/CTranslate2 + large-v3 model + pyannote 3.1 weights, accepted at *pack-build* time) is downloaded, signature-verified, and installed to `…/CallBrain/models/` on first raw-video detection. |

---

## 2. System Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  CallBrain.app  —  SwiftUI (macOS 26, Swift 6 strict concurrency, @MainActor)  │
│                                                                                │
│  Views (12 screens) ── @Observable VMs ──┐                                     │
│                                          │  (Sendable DTOs only)               │
│   ┌──────────────────────────────────────▼──────────────────────────────┐     │
│   │ SidecarSupervisor (actor)   SidecarClient (actor)   EngineStatusStore│     │
│   │   spawn/health/restart        typed async HTTP + SSE   status pill    │     │
│   └───────────────┬───────────────────────┬──────────────────────────────┘     │
└───────────────────┼───────────────────────┼───────────────────────────────────┘
                    │ Process spawn          │ HTTP/SSE  127.0.0.1:<ephemeral>
                    │ (ephemeral port +      │ Authorization: Bearer <per-launch token>
                    │  handshake file)       ▼
        ┌───────────▼───────────────────────────────────────────────────────────┐
        │  callbrain-sidecar  —  Python 3.12 (uv-pinned) · FastAPI / uvicorn      │
        │                                                                         │
        │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  ┌─────────────┐ │
        │  │ Watchers /  │→ │  Detection   │→ │   Routing      │→ │  Pipelines  │ │
        │  │ Import API  │  │  (3-stage    │  │  table         │  │  (state     │ │
        │  │ drag-drop   │  │  sniff/sig)  │  │                │  │  machine)   │ │
        │  └─────────────┘  └──────────────┘  └──────┬────────┘  └──────┬──────┘ │
        │                                            │ transcript-first │        │
        │                   ┌────────────────────────┘   │  raw video   │        │
        │                   ▼                            ▼              ▼        │
        │   ┌──────────────────────┐      ┌───────────────────┐  ┌───────────┐  │
        │   │ Parsers → CTM normal.│      │ ffmpeg→16k mono →  │  │ chunk →   │  │
        │   │ (Fireflies/Fathom/   │      │ faster-whisper +   │  │ embed →   │  │
        │   │  Gemini/Cluely/SRT)  │      │ pyannote diarize   │  │ extract → │  │
        │   └──────────┬───────────┘      └─────────┬─────────┘  │ summarize │  │
        │              └──────────────┬─────────────┘            └─────┬─────┘  │
        │                             ▼                                │        │
        │   ┌────────────────────────────────────────────┐            │        │
        │   │ Retrieval: QueryPlan → FTS5(BM25) ⊕ LanceDB │◄───────────┘        │
        │   │ (pre-filter ANN) → RRF → gates → context    │                     │
        │   └───────────────┬───────────────┬─────────────┘                     │
        │                   │               │                                   │
        │  Durable job queue │               │  LocalCLIProvider (subprocess)    │
        │  (SQLite-backed)   ▼               ▼                                   │
        │            ┌───────────────┐  ┌───────────────────────────────────┐   │
        │            │   SQLite      │  │  claude -p --safe-mode --tools ""  │   │
        │            │  (WAL, FTS5,  │  │  codex exec -s read-only ...       │   │
        │            │  source of    │  │  (env-scrubbed → subscription auth)│   │
        │            │  truth)       │  └───────────────────────────────────┘   │
        │            └───────────────┘                                          │
        │            ┌───────────────┐      ┌──────────────────────────────┐    │
        │            │  LanceDB      │      │  Ollama 127.0.0.1:11434       │    │
        │            │ (derived vec  │◄────►│  nomic-embed-text (embeddings)│    │
        │            │  index, per-  │      │  [opt] local LLM last-resort  │    │
        │            │  space tables)│      └──────────────────────────────┘    │
        │            └───────────────┘                                          │
        └─────────────────────────────────────────────────────────────────────┘
```

Data flow (capture→ask): file/paste → detect → route → (parse | transcribe) → normalize to CTM → chunk → embed (Ollama) → write SQLite + LanceDB + FTS5 → user asks → QueryPlan → hybrid retrieve (pre-filtered) → RRF fuse → evidence/refusal gates → assemble cited context → `LocalCLIProvider.generate` (claude/codex) → citation validator → answer envelope → SwiftUI renders with tappable citations.

---

## 3. Component Stack (final)

| Layer | Choice | Pin / version (verified this Mac) | One-line why |
|---|---|---|---|
| OS target | macOS 26 | 26.5.1 arm64 | Premium native + latest SwiftUI/`NavigationSplitView`. |
| UI | SwiftUI + Swift 6 strict concurrency | Swift 6.3.2 (`arm64-apple-macosx26`) | Native feel; actor isolation keeps engines off `@MainActor`. |
| Build/IDE | Xcode + `xcodebuild` | present | Standard. |
| Sidecar runtime | Python | **3.12** via `uv` (uv 0.10.4; py3.12.12 available) | System `python3 = 3.14.3` is **too new** — ML wheels lag; pin 3.12. |
| Web framework | FastAPI + uvicorn (programmatic `uvicorn.Server`) | latest 3.12-compatible | Async, typed, binds port 0 + writes handshake itself. |
| HTTP client (Swift) | `URLSession` (`.bytes` for SSE) | built-in | No third-party SSE dep. |
| Relational store | **SQLite** (WAL, FTS5, generated cols) | system 3.51 | Source of truth; FTS5 BM25 for exact crypto jargon; `VACUUM INTO` hot backup. |
| Vector store | **LanceDB** (IVF_PQ/HNSW + scalar indexes) | pin in uv lock (verify scalar-index API at build) | Pre-filtered ANN (hard date/speaker gate) + versioned per-space tables. |
| Embeddings | **Ollama `nomic-embed-text` v1.5** (768-dim, `num_ctx:8192`) | Ollama at `/opt/homebrew/bin/ollama` | Fully local, 8192-token window fits our chunks; **default**. `mxbai-embed-large` = optional toggle. |
| Keyword search | SQLite FTS5 (`porter unicode61 remove_diacritics 2`) | system | Exact tokens ("Iceriver", "Proof of Logits"). |
| Fusion | Reciprocal Rank Fusion, k=60 | — | Score-agnostic merge of BM25 + cosine. |
| LLM generation | **`claude` CLI** + **`codex` CLI** (subscriptions) | claude 2.1.196 (`~/.local/bin/claude`); codex 0.142.3 (`/opt/homebrew/bin/codex`) | Constraint 1; hot-swappable behind `LocalCLIProvider`. |
| Local LLM (last resort) | Ollama (e.g. `qwen2.5:7b`) | opt-in, default-off | Background extraction only when both CLIs rate-limited. |
| ASR | **faster-whisper `large-v3`** (CTranslate2, int8, word ts) | downloaded Pack | Light (no torch); `large-v3-turbo` toggle for speed. |
| Diarization | **pyannote `speaker-diarization-3.1`** | downloaded Pack (weights accepted at pack-build) | Speaker turns for raw video. |
| Media | **static arm64 `ffmpeg`/`ffprobe`** bundled in `Contents/Resources` | **NOT installed** on this Mac → bundle (LGPL/BSD build) | Non-coder won't `brew install`. |
| Hashing | BLAKE3 | — | Fast file + content fingerprints for dedupe. |
| Dedupe support | `datasketch` MinHash | — | Shingle-overlap for same-meeting detection. |
| NER | spaCy `en_core_web_trf` + domain gazetteer | — | PERSON/ORG + crypto vocab the gazetteer anchors. |
| Freezer | **PyInstaller `onedir`** | — | Stable signable dir (onefile trips Hardened Runtime). |
| Signing | Developer ID (Team 559YM79ZCA) + `notarytool` + `stapler` | `codesign`/`notarytool`/`xcodebuild` present | Direct-download, not App Store. |
| Auto-update | **Sparkle** (EdDSA appcast) | — | Direct-download updates. |
| Node (for codex) | node@20 | present | `codex` is a Node CLI. |

---

## 4. Source Matrix & Ingestion Contracts

The governing rule (Constraint 2): if a usable transcript exists, parse it; only a raw `.mp4` with **no sibling transcript** is transcribed locally. All sources normalize to one canonical model (§6.3). **`ts_confidence` ladder** powers honest citation labeling: `exact > coarse > derived > none`.

| Source | Artifact / format | Speakers | Timestamps | Fetch | Richest ingest | Auto-detect signature | Conf. |
|---|---|---|---|---|---|---|---|
| **Google Meet — transcript** (Gemini/Workspace) | Google **Doc** → export `text/html` | Yes (per turn) | **Coarse** (~5-min anchors) | Drive API `files.export` or local Drive sync | HTML export (preserves turn/bold-name structure) | In `Meet Recordings`; title `… - Transcript`; `Name:` turns + sparse `HH:MM:SS` | HIGH artifact / MED granularity |
| **Google Meet — Gemini Notes** | Google **Doc** (summary/next-steps) | Partial | Citations only | same | `text/plain` | title `… - Notes by Gemini` | HIGH — *secondary signal, never the transcript* |
| **Google Meet — recording** | `.mp4` (`video/mp4`) | No | — | Drive `files.get?alt=media` / local sync | n/a (transcribe **only if no sibling Doc**) | `Meet Recordings`, name `… (YYYY-MM-DD HH:MM GMT…).mp4` | HIGH |
| **Fathom (FREE)** | clipboard **plain text** (no free API/download) | Yes | **Exact** `H:MM:SS` per turn | manual copy/paste or `.txt` drop | pasted text | `fathom.video` URL and/or `Name H:MM:SS`/`Name (MM:SS):` blocks | HIGH copy-only / MED delimiter |
| **Fireflies** | `.json`/`.srt`/`.vtt`/`.txt` + free GraphQL API | Yes (`speaker_name`+`speaker_id`) | **Exact** seconds | GraphQL `sentences[]` (best) or export drop | GraphQL/JSON `sentences[]` | JSON `sentences[].speaker_name+start_time`; SRT/VTT cues | HIGH |
| **Cluely** | clipboard **plain text** (no file export) | Yes | **Likely none** (verify) | manual copy/paste | pasted text | speaker-labeled prose; optional `cluely.com` link | MED struct / LOW timestamps |
| **Generic SRT/VTT** | subtitle cues | rarely (`<v Speaker>`) | exact | drop | cue parse | `WEBVTT` / `N\n HH:MM:SS,mmm -->` | HIGH format |

**Citation hard rule:** a citation is emittable only when `title` + `started_at` + `speaker` + (`t_start` OR a transcript anchor offset) all exist. Cluely-with-no-timestamps ⇒ `ts_confidence:"none"`, cited by **meeting + speaker + sequence position**, never a fabricated `00:00`.

**Meet routing (the core auto-decision):** for each `.mp4` in `Meet Recordings`, search the same folder for a sibling Doc matching by title-stem + date (±a few min). **Sibling Doc → parse Doc, skip transcription. No Doc → queue for local whisper.** (MED — Gemini saves Doc + `.mp4` side-by-side; the #1 thing to verify against the user's real Drive, §18.)

**Verify before locking parsers (real artifacts, Phase 0):** (1) does "Meet premium" drop *verbatim Transcript* Docs or only *Gemini Notes*? (2) exact Meet Doc turn/timestamp layout; (3) exact Fathom clipboard delimiter; (4) does Cluely copy carry timestamps / is it plain vs markdown; (5) Fireflies free-tier API key availability; (6) `.gdoc` pointer-file behavior on local Drive sync. Parsers ship **tolerant (regex/structure-based, not fixed-column)** and emit per-file confidence.

---

## 5. LocalCLIProvider (LLM over Claude/Codex CLIs)

**Design thesis:** treat each CLI as a dumb, sandboxed, stateless text endpoint. We use none of the agentic loop, tools, memory, MCP, hooks, or config. Pass a fully-formed prompt in, extract one final text (or one JSON object) out, discard the process. All RAG retrieval, prompt assembly, and citation enforcement live in our sidecar.

### 5.1 Interface (FastAPI sidecar, async subprocess, no SDKs)

```python
class ProviderId(str, Enum): CLAUDE="claude"; CODEX="codex"; OLLAMA="ollama"

@dataclass(frozen=True)  # immutable (house style)
class Availability: installed:bool; logged_in:bool; model:Optional[str]; detail:str; rate_limited_until:Optional[float]=None
@dataclass(frozen=True)
class Completion: text:str; provider:ProviderId; model:str; usage:dict; notional_cost_usd:float; raw_envelope:dict
@dataclass(frozen=True)
class JSONCompletion: obj:dict; repaired:bool; provider:ProviderId; model:str
@dataclass(frozen=True)
class StreamToken: text:str; kind:str  # "delta"|"message"|"done"|"ratelimit"|"error"; meta:dict

class LocalCLIProvider(Protocol):
    id: ProviderId
    async def complete(self, prompt, *, system, model, timeout_s) -> Completion: ...
    async def complete_json(self, prompt, *, system, schema, model, timeout_s) -> JSONCompletion: ...
    async def stream(self, prompt, *, system, model, timeout_s) -> AsyncIterator[StreamToken]: ...
    async def availability(self) -> Availability: ...
```

Router-level `which(policy, live_availability)` resolves `per_call_override or default`, walking the fallback chain on unavailable/rate-limited. One **empty sandbox dir** (`~/Library/Application Support/CallBrain/cli-sandbox/`, no `.git`/`CLAUDE.md`/`AGENTS.md`) is the cwd for every child. The prompt (retrieved chunks + question) is piped on **stdin** (avoids `ARG_MAX`); retrieval budgets to ≈150k tokens (model window verified `contextWindow:200000`). Each child env has `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `OPENAI_API_KEY`, `OPENAI_BASE_URL` **deleted** → forces subscription auth.

### 5.2 Claude adapter — exact command lines (all verified live)

Shared base (every call): `claude -p --model <sonnet|opus> --safe-mode --tools "" --strict-mcp-config --no-session-persistence --permission-mode default --system-prompt "$SYSTEM"`.

`--safe-mode` strips the user's hooks/MCP/CLAUDE.md/skills but **keeps OAuth** (verified: hook lines 36,540→1.1k cached tokens, cost $0.219→$0.008). **Never `--bare`** (breaks subscription auth, §1.4 C3). **Never `--dangerously-skip-permissions`** (CI grep-gate bans it).

- **RAG / answer (`complete`)** — `… --output-format json` → parse `.result`; model badge = key of `.modelUsage`.
- **Structured extraction (`complete_json`)** — `… --output-format json --json-schema "$SCHEMA"` → read `.structured_output` (already parsed + schema-validated; `additionalProperties:false`).
- **Live chat (`stream`)** — `… --output-format stream-json --verbose --include-partial-messages` → emit `StreamToken(kind="delta")` per `content_block_delta.text`; emit `kind="ratelimit"` on `rate_limit_event` (inline `status`/`rateLimitType:"five_hour"`/`resetsAt` → proactive fallback); finalize on `result`. **Claude is the only true token-streaming provider.**

### 5.3 Codex adapter — exact command lines (all verified live)

Shared base: `codex exec -s read-only --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules -C "$SANDBOX" -m gpt-5.5 -c model_reasoning_effort="<low|medium>" -c preferred_auth_method="chatgpt" -` (prompt on stdin). No `--system-prompt`; prepend system rules as a delimited first block (`<<SYSTEM>> … <<END_SYSTEM>>`). **Default reasoning is `xhigh` — far too slow/costly; pin `low` (extraction) / `medium` (RAG).** (`codex login status` → "Logged in using ChatGPT" = subscription.)

- **RAG (`complete`)** — add `-o "$OUTFILE"`; answer = pristine `$OUTFILE` contents (verified clean; never scrape stdout banner).
- **Extraction (`complete_json`)** — add `--output-schema "$SCHEMA_FILE" -o "$OUTFILE"`; `$OUTFILE` holds schema-conformant JSON.
- **Streaming (`stream`)** — add `--json`; push each `item.completed` (type `agent_message`) as one `StreamToken(kind="message")`; surface `turn.started` as "thinking…" (Codex emits whole items, no token deltas).

### 5.4 JSON extraction — parse + repair (untrusted always)

(1) Native first (`.structured_output` / `$OUTFILE`) → `jsonschema.validate`. (2) Extract largest balanced `{…}`/`[…]`; strip ``` fences; **normalize CRLF before brace-matching** (prior macOS grapheme gotcha). (3) Local repair (`json-repair`) → re-validate. (4) One LLM repair retry ("JSON fixer, output only valid JSON"). (5) Fail closed → `ExtractionError` → item `needs_review` (never silently drop). Schemas always `additionalProperties:false` + `required`; extraction prompt: "If a field is absent, use null. Never fabricate."

### 5.5 Selection, throttling, fallback

- **Policy (immutable):** `default = claude|codex`, `per_call_override`, `allow_codex_fallback`, `allow_claude_fallback`, `allow_ollama_lastresort=False`, `ollama_model="qwen2.5:7b"`. One Settings toggle flips global default instantly (identical interface). Ask-AI box has a provider chip for per-call override.
- **Durable queue (SQLite):** `job(id,kind,payload,provider_pref,state,attempts,not_before,last_error,…)`; states `queued→running→done|needs_review|deferred`; survives restarts (years of recordings). Per-provider `asyncio.Semaphore` (claude=2, codex=2, ollama=1); **interactive Ask-AI uses a separate high-priority lane** so a 300-file backfill never blocks a question. Token-bucket pacing under the 5-hour window; exp backoff `min(2^attempt+rand,300s)`, ≤5 attempts.
- **Subscription limits (web):** Claude Pro/Max = 5-hour rolling window **+** weekly cap (HIGH; counts MED); ChatGPT Plus/Pro = local+cloud share 5-hour + weekly (HIGH; counts MED).
- **Fallback matrix:** transient → retry same provider; Claude rate-limited (inline `rate_limit_event`/`is_error` limit subtype/regex; capture `resetsAt`) → switch to Codex; Codex rate-limited (exit≠0 + `/429|quota|rate limit/i`) → switch to Claude; auth error → mark logged-out, switch + UI banner "Re-login to {provider}"; **both limited** → opt-in Ollama for *bulk only* (badged low-trust) else **defer** with `not_before=max(reset)` and UI "Will resume after 3:40 PM"; **empty retrieval → refuse before any CLI call** (never spend quota to say "I don't know"). Fallback is transparent: toast "Claude hit its 5-hour limit — answered with Codex."

### 5.6 Safety (these QA calls cannot shell/read/network)

Claude: `--tools ""` (no Bash/Read/Edit/Web), `--strict-mcp-config` (no MCP), `--safe-mode` (no hooks/skills), `--permission-mode default`, empty cwd, scrubbed env. Codex (higher risk — agentic by default): `-s read-only` (no writes; network off by default — MED-HIGH, mitigated by layers), `-C sandbox --skip-git-repo-check`, `--ignore-user-config --ignore-rules`. **Both:** prompt guard ("text-only QA function, no tools/shell/files/network; use ONLY the excerpts between markers"); subprocess hard-killed on timeout; output size-capped. **Prompt injection from transcripts** is neutralized **capability-first**: an injected "run rm -rf"/"email X" has no tool to call. Chunks wrapped in per-request random delimiters labeled DATA-not-instructions; output is rendered/validated, never `eval`'d or shell-executed.

---

## 6. Ingestion Intelligence

**North star:** zero configuration, never guess wrong silently. Every item is auto-handled with high confidence **or** parked in an explicit `needs_review` queue with a plain-English reason. **Deterministic-first, LLM-last:** routing/parsing/metadata/dedupe are deterministic; the local LLM only *enriches* (entity canonicalization, summaries) where a wrong answer degrades gracefully.

### 6.1 Detection (3 stages, confidence-scored)

- **Stage A — container sniff:** read first 4KB + last 1KB; pure-Python `filetype` + custom text sniffer; **magic bytes are truth, extension is a hint** (MP4 `ftyp`, Matroska `1A45DFA3`, WAV `RIFF…WAVE`, MP3 `ID3`/`FFFB`, PDF `%PDF-`, DOCX `PK\x03\x04`+`word/document.xml`, VTT `WEBVTT`, SRT int+`-->`, JSON parse, CSV sniff, text/markdown). A `.txt` whose bytes are MP4 is treated as MP4.
- **Stage B — source classification (structural signatures, score all, pick max with margin):** Fireflies JSON (`sentences[].speaker_name+start_time`) HIGH; Gemini/Meet Doc (footer "This editable transcript was computer generated" / `… - Transcript` + `Meet Recordings` co-location) HIGH; Fathom copy (`fathom.video` URL or `Name M:SS` blocks) MED; Cluely (speaker-labeled markdown) MED/LOW; SRT/VTT HIGH-format; generic transcript MED; raw media (no sibling) HIGH-is-media.
- **Stage C — confidence gate:** unknown/corrupt → `failed`; `score_top<0.55` → `needs_review("source unrecognized")`; `score_top−score_second<0.15` → `needs_review("ambiguous: X or Y")`; else accept. One-click override **also teaches the fingerprint store** so the next similar file auto-classifies.

### 6.2 Routing table

| Input (post-detect) | Route | Steps | Skipped |
|---|---|---|---|
| Fireflies JSON / Gemini Doc / Fathom copy / Cluely md / SRT-VTT / generic transcript | **PARSE** | normalize→meta→entities→chunk→embed→summarize | extracting_audio, transcribing |
| Media **with** matched sibling transcript | **PARSE + ATTACH** (`media_ref`) | parse sibling, attach media | extracting_audio, transcribing |
| Raw audio/video, **no** transcript | **TRANSCRIBE (local)** | `ffmpeg`→16k mono → faster-whisper large-v3 (int8, word ts) → pyannote 3.1 diarize → align words↔turns → normalize→… | — |
| Any item, user clicks "Upgrade to cloud transcription" | **TRANSCRIBE (cloud)** | re-run via cloud provider, append `version N` (local v0 never deleted) | — |

faster-whisper note: CTranslate2 has **no Metal/GPU on Apple Silicon** → CPU-bound (HIGH); ship `large-v3` default + `large-v3-turbo` toggle (~8× faster, small WER cost). pyannote 3.1 weights are HF-gated → **vendored into the Pack at pack-build time** (token only on build machine, never shipped).

### 6.3 Canonical Transcript Model (CTM)

```jsonc
// Meeting
{ "meeting_id":"uuidv7", "content_fingerprint":"blake3:…", "file_hash":"blake3:…",
  "title":"Travis sync — Render GPU pricing", "date":"2026-05-14",
  "started_at":"2026-05-14T16:00:00-07:00"|null, "duration_s":3120,
  "source":{"class":"fathom","detect_confidence":0.92,"original_filename":"…","managed_path":"…","media_ref":null},
  "participants":[{"person_id":"p_travis","raw_label":"Travis","role":"speaker"}],
  "transcript_versions":[{"version":0,"engine":"faster-whisper:large-v3+pyannote:3.1","provider":"local","active":true}],
  "entities":{…}, "summary":{"tldr":"…","decisions":[],"open_questions":[]}, "provenance":{…} }
// Utterance (atomic, ordered by t_start)
{ "utterance_id":"u_000123", "meeting_id":"…", "version":0, "seq":123,
  "person_id":"p_travis"|null, "speaker_raw":"Travis", "speaker_confidence":0.88,
  "t_start":742.30, "t_end":768.11, "text":"On Render, the GPU spot pricing…",
  "is_inferred_speaker":false, "ts_confidence":"exact" }
```

Normalization rules: all timestamps → float seconds from start; `speaker_raw` preserved verbatim; `PersonResolver` maps raw→`person_id` (exact alias → folded match → per-meeting hints → LLM-assist for ambiguous diarized labels, gated by confidence; below threshold `person_id=null` + "who is Speaker 2?" chip); "Me"/owner auto-mapped via owner alias set. Consecutive same-person utterances with gap <0.8s merged (fine-grained word ts retained in sidecar for precise seek); diarization churn median-filtered before merge. Explicit labels → `speaker_confidence=1.0, is_inferred_speaker=false`; diarized → pyannote posterior, `is_inferred_speaker=true` (answer lane footnotes weak attributions).

### 6.4 Metadata & entities

- **Filename convention (auto-healed, never blocks):** `YYYY-MM-DD - People - Company/Topic - Source.ext`. Tolerant named-group regex; missing fields filled by priority filename → container meta (`creation_time`, DOCX props, mtime) → content. Managed copy renamed canonically; original name preserved. **Date precedence:** filename > content > `creation_time` > mtime; conflict >±1d → low-severity `needs_review` chip (default filename).
- **Entities (hybrid, deterministic-first):** (1) spaCy `en_core_web_trf` PERSON/ORG/GPE + **crypto/decentralized-AI gazetteer** (validator, miner, ASIC, Proof of Logits, Render, OpenRouter, BGIN, Iceriver, Arena, Bittensor, Ambient, inference hardware; Travis/Max/JW). (2) LLM-assist via `LocalCLIProvider` (batched per meeting, JSON-schema'd) for missed entities + canonicalization + type; parse failure degrades to gazetteer-only, never fails import. **BGIN vs Iceriver are stored as separate canonical entities** linked by typed edges (`co_mentioned_with`, `possibly_same_as`) — **never auto-merged**; `possibly_same_as` is labeled *inferred* and needs a one-tap confirm. Topic graph (co-mention weighted by recency) powers "what to ask next" + briefings without inventing relationships.

### 6.5 Chunking (speaker-turn-aware, citation-stable)

Built from **merged utterances**; never split across a speaker change unless a monologue exceeds the cap. Target **~512 tokens, 128 overlap, hard cap 768** (counted with the embedding model's tokenizer; fits nomic's 8192 window). Turn-aware packing: greedily pack one speaker's utterances; over-cap monologue split at sentence boundaries (`part i/n`); short utterances get adjacent-speaker `context_before/after` stored separately (**not embedded as the speaker's words**). Stable `chunk_id = f(meeting_id, version, seq-range)` so re-embeds never break citations. Each chunk carries the full citation envelope (title, date, `person_id`, `speaker_raw`, `speaker_confidence`, `is_inferred_speaker`, `t_start/t_end`, `utterance_ids`, `deep_link callbrain://meeting/<id>?t=742.30`).

### 6.6 Import state machine (durable, resumable, never-silent-fail)

```
drop → [queued] → [detecting] ─┬─(transcript)──────────────────────────────┐
                               └─(media,no transcript)→[extracting_audio]→[transcribing]→
                                                                            ↓
[normalizing]→[extracting_meta]→[extracting_entities]→[chunking]→[embedding]→[summarizing]→[done]✅
   any state: file/content hash present → [duplicate]🔁
   any state: unrecoverable → [failed]⛔ (reason+retry)
   detecting: gate fails/ambiguous → [needs_review]🟡 (one-tap → re-enters detecting)
```

Two-tier idempotency: `file_hash` (BLAKE3 of bytes, computed in `queued` → exact re-drop = instant `duplicate`) and `content_fingerprint` (BLAKE3 of normalized text, computed in `normalizing` → same meeting via two sources → duplicate group). Per-state checkpoints write content-addressed artifacts (WAV, raw whisper JSON, CTM, chunks, vectors) → resume reuses completed work; **transcription never re-run if its artifact validates**. `pipeline_version` bump re-runs only downstream-of-change states. On startup, non-terminal rows reset to last checkpoint + re-enqueued (lease/heartbeat prevents double-grab). Every state body wraps exceptions into structured `ImportFailure {state, error_class, message_human, message_technical, is_retryable, retry_count}`; `transient` → backoff retry (5s/30s/2m ×4), `permanent` → `failed`, `ambiguous` → `needs_review`. `GET /imports` + SSE `/imports/stream`: live per-file %, `transcribing` reports fraction of audio duration. No path drops a file silently.

---

## 7. Hybrid Retrieval & Anti-Hallucination

**Cardinal rule:** structured guarantees ("this week", "what Travis said") are enforced by deterministic SQL/vector filters over structured metadata — never delegated to the LLM. The model only writes prose over a pre-filtered, pre-cited evidence set, and that output is validated before display.

### 7.1 Pipeline (exact order)

```
NL query + UI mode + local_tz
 → [1] QUERY PLAN {date,person,company,topic,call_type,source,action_only,mode,terms,boosts}
 → build ONE hard-filter predicate P (identical for both lanes; built from validated plan, never string-concat)
 → [2a] FTS5 BM25 (chunks_fts MATCH terms AND P, ORDER BY bm25, LIMIT 50)
   [2b] LanceDB vector (search(embed(terms)).where(P, prefilter=True).metric(cosine).limit(50))
 → [3] RRF fuse (k=60)
 → [4] gates: raw-evidence refusal floor · near-dup suppression (same-meeting cos≥0.97 → keep best source, fold into also_in_sources) · per-meeting diversity cap (≤3, except single-meeting modes) · mode rerank/boost
 → [5] numbered [S1..Sn] evidence blocks with full citation metadata
 → [6] generate (LocalCLIProvider: claude -p | codex exec read-only)
 → [7] citation validator (every claim → valid [S#]; strip/flag/refuse)
 → answer envelope
```

We **own the fusion** (FTS5 in SQLite + vectors in LanceDB, RRF in Python) rather than LanceDB's built-in hybrid builder — for exact-keyword fidelity, identical pre-filter on both lanes, determinism, and to sidestep LanceDB hybrid-builder inverted-prefilter issue #3095 (MED). **`prefilter=True`** is decisive: post-filtering applies the predicate only to the K rows ANN already returned and can silently yield <K or 0 in-scope results for selective filters (exactly the "this week"/"only Travis" case); pre-filter + scalar indexes guarantee correctness and are faster here (HIGH). Injection-safe: P uses whitelisted columns/operators + typed bound values; no NL→SQL path except through the schema-validated plan.

### 7.2 RRF (exact)

`RRF(d) = Σ_lane w_lane/(60 + rank_lane(d))`; `w_fts=w_vec=1.0` default. Mode-tunable: Person/Action lean lexical (`w_fts 1.3`), Technical Explainer / semantic queries lean vector (`w_vec 1.3`). **RRF is ordering only**; the refusal decision uses raw evidence (max cosine + BM25 presence), never RRF.

### 7.3 Query plan (deterministic-first, LLM-fallback)

~90% planned by regex + entity dictionary (alias-resolved people/companies, tag dictionary, temporal grammar). LLM planner (via `LocalCLIProvider`, JSON-only, tool-forbidden) only for genuinely ambiguous phrasing; output validated against the plan schema; on failure → safe deterministic plan (filters never silently dropped — if a filter can't be resolved we tell the user "I couldn't resolve X"). Plan schema fields: `mode, search_terms, date_filter{kind,start_epoch,end_epoch,applies_to,week_start,tz,confidence}, person_filter, company_filter, topic_filter, call_type, source_filter, action_items_only, owner_filter, boosts{recency,explanatory,w_fts,w_vec}, unresolved[]`.

### 7.4 Date math (local-tz, half-open `[start,end)`)

`now` = user-local; bounds computed on local calendar days then → epoch (DST-safe). today / yesterday / **this week** (`start_of_week`, **default Monday/ISO-8601**, user-switchable to Sunday) / last week / last N days / month / range. `applies_to`: `meeting`→`meeting_epoch`, `action_due`→`due_epoch`, `either`→OR (Action mode).

### 7.5 The 8 AI modes

| # | Mode | Hard filters | Boost | Prompt delta | Output |
|---|---|---|---|---|---|
| 1 | **General Ask** | plan-resolved | recency +0.1 | answer from sources only | prose + confirmed/inferred split + citations |
| 2 | **This Week** | `meeting_epoch ∈ this_week` | chronological | summarize this week, grouped by call | per-meeting digest, each line cited |
| 3 | **Person** | `speaker ∈ {X}` | `w_fts 1.3` | report ONLY what X said; never attribute others to X | "what X said" by call/date + quotes/timestamps; separate inference block |
| 4 | **Partner/Company** | `companies ∋ X` | recency +0.1 | 6-slot contract | 6 labeled sections (1 inference-only) |
| 5 | **Technical Explainer** | `topic` if any, else semantic over all | **`explanatory_score` rerank**, `w_vec 1.3` | explain using ONLY these calls; name gaps | explanation, each point cited + "based only on your calls" + gap list |
| 6 | **Action-Item Extractor** | `is_action_item` + date-gate (§7.6) + optional owner/company | — | extract tasks; mark unclear/not-specified; consolidate recurring | task list {text,owner,due,status,sources[]} |
| 7 | **Pre-Call Briefing** | `companies∋X ∪ participants∋X`, all history + open actions | recency | brief me: history, open loops both directions, what to ask next | last touchpoints · you owe/they owe · open Qs · agenda · "ask next" |
| 8 | **Post-Call Review** | `meeting_id=M` + cross-refs (same company/people) | — | review THIS call; flag new decisions/actions; note changes vs prior | summary · decisions · new actions (dated) · contradictions (both cited) · next steps |

Mode notes: **Person (3)** — the hard `speaker` filter makes misattribution structurally impossible; the model literally only sees X's chunks. **Company (4)** 6 slots: `what_they_said / what_they_want / what_we_can_offer / open_questions / next_steps` (all confirmed, cited) + `inferred_strategy` (the only synthesizing slot, typed `inferred`). **Explainer (5)** — `explanatory_score` (precomputed at ingest 0–1) up-weights long single-speaker definitional turns ("which means", "the way it works", "is defined as"), down-weights one-line mentions → "Explain Proof of Logits" pulls Max's actual *explanation*, not five mentions of the phrase; hard-bound "if your calls don't cover X, say so — do not fill from general knowledge."

### 7.6 Citation contract & date-gating

**Answer envelope (strict):** `{mode, status: answered|weak_evidence|no_sources, answer_markdown, claims[{claim_id,text,type:confirmed|inferred,evidence_strength,confidence,citation_ids}], citations[{citation_id,chunk_id,meeting_id,meeting_title,meeting_date,speaker,t_start,t_end,source,also_in_sources,quote,transcript_anchor}], action_items[], unanswered[], filters_applied, refusal_reason}`. Every citation carries **title + date + speaker + timestamp + chunk_id + clickable anchor**; `[S#]` are tap targets that scroll the transcript to `char_start`.

**Generation invariants (appended every mode):** use ONLY the SOURCES; tag every factual sentence `[S#]`; separate CONFIRMED vs INFERRED (inferred under its own hedged heading); if unanswerable output exactly `NO_SOURCED_EVIDENCE`; never invent speakers/dates/numbers/quotes; quote verbatim.

**Post-gen validator (deterministic, every answer):** extract `[S#]` per claim sentence; **unsupported claims** (zero valid tags) quarantined — if >20% of factual sentences, downgrade `status` and strip; dangling tags dropped; quoted sentences fuzzy-matched (≥0.9) against cited chunk text (fail → demote confirmed→inferred or strip); `NO_SOURCED_EVIDENCE` or everything stripped → refusal envelope.

**Refusal/weak gates (raw evidence, not RRF):** refuse (`no_sources`) when candidate set empty after hard filters **OR** (`max_cos<0.35 AND no BM25 hit`), with a filter-specific message ("No indexed call has Travis discussing Render" / "You have no calls in the selected week"). Weak (`weak_evidence`) when above floor but `max_cos<0.55` and ≤1 chunk → answered but banner-labeled "thin evidence — verify in transcript," claims inherit `evidence_strength=weak`. (Thresholds are config, tuned on §15 corpus.)

**Action-item "this week" hard gate (reconciled rule, C4/C5):** a task is current-this-week iff
```
(due_epoch IS NOT NULL AND due_epoch ∈ this_week)            -- explicit due this week, even from an old call (cite it)
 OR (due_epoch IS NULL AND meeting_epoch ∈ this_week AND status != 'done')  -- fresh undated task
```
An **old** undated task is **never** "this week." `owner_role=NULL` → "owner: unclear" (never silently "me"); "follow-ups I owe BGIN/Iceriver" = `is_action_item ∧ owner_role='me' ∧ companies∋{BGIN,Iceriver}`. `due_epoch=NULL` → "due: not specified." Recurring tasks consolidated by text+owner+company but **list every source citation with dates** (never drop a citation). Bounds computed by the app from *today* in **local tz**, never inferred by the model.

**Two-source dedupe:** at ingest, cluster into one canonical `meeting_id` (fuzzy: title×start±15min×participant-overlap≥0.6×duration±20%); at retrieval, suppress near-dups (cos≥0.97 or MinHash≥0.8), keep highest-quality source, fold dropped into `also_in_sources` — one clean quote, not two.

---

## 8. Data Model

**Principles:** SQLite is the source of truth, LanceDB is a rebuildable index (never store data only in LanceDB); **TEXT UUIDv7 PKs** (time-ordered, merge-safe for Drive sync/backup); normalize what's filtered, denormalize summary JSON (rebuilt from normalized rows in one txn so they can't drift); **dual dates** (ISO-8601 UTC text + generated epoch columns for range scans + LanceDB mirror); **link-not-delete** on dedupe; all timestamps UTC, rendered local in UI.

Per-connection PRAGMAs: `journal_mode=WAL; synchronous=NORMAL; foreign_keys=ON; busy_timeout=5000; temp_store=MEMORY; cache_size=-65536; wal_autocheckpoint=1000`.

### 8.1 SQLite DDL (canonical)

```sql
-- ── migrations / settings ──────────────────────────────────────────────
CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL,
  applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')), checksum TEXT);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')), CHECK(json_valid(value)));
-- seeded: active_embedding_space="chunks_emb__nomic__v1", embedding_model={"id":"nomic-embed-text","dim":768,"provider":"ollama"},
--         me_identities, source_trust_order, dedupe_thresholds, dedupe_hard_gates, drive_sync, provider_policy

-- ── dimensions ─────────────────────────────────────────────────────────
CREATE TABLE participants (id TEXT PRIMARY KEY, display_name TEXT NOT NULL, normalized_name TEXT NOT NULL,
  email TEXT, aliases TEXT NOT NULL DEFAULT '[]', is_me INTEGER NOT NULL DEFAULT 0,
  entity_id TEXT REFERENCES entities(id) ON DELETE SET NULL, first_seen TEXT, last_seen TEXT,
  meeting_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')));
CREATE UNIQUE INDEX ux_participants_email ON participants(email) WHERE email IS NOT NULL;
CREATE INDEX ix_participants_norm ON participants(normalized_name);

CREATE TABLE companies (id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE,
  aliases TEXT NOT NULL DEFAULT '[]', domain TEXT, kind TEXT, notes TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')));

CREATE TABLE tags (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, label TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'topic',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')));

CREATE TABLE entities (id TEXT PRIMARY KEY, canonical_name TEXT NOT NULL, normalized_name TEXT NOT NULL,
  entity_type TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '[]', description TEXT,
  mention_count INTEGER NOT NULL DEFAULT 0, first_seen TEXT, last_seen TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  UNIQUE(normalized_name, entity_type));
CREATE INDEX ix_entities_type ON entities(entity_type);

-- ── meetings (hub) ─────────────────────────────────────────────────────
CREATE TABLE meetings (id TEXT PRIMARY KEY, title TEXT NOT NULL, date TEXT NOT NULL,
  start_time TEXT, duration INTEGER,
  source TEXT NOT NULL,           -- fathom|fireflies|cluely|gmeet_gemini|gmeet_local|gmeet_cloud|srt_vtt|paste|manual
  company TEXT, call_type TEXT,   -- one_on_one|partner|internal|sales|research|interview|community|other
  topic_tags TEXT NOT NULL DEFAULT '[]', source_url TEXT, recording_url TEXT, transcript_url TEXT,
  local_file_path TEXT, raw_transcript TEXT, cleaned_transcript TEXT, summary TEXT,
  decisions TEXT NOT NULL DEFAULT '[]', action_items TEXT NOT NULL DEFAULT '[]',
  open_questions TEXT NOT NULL DEFAULT '[]', follow_ups TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'active',           -- active|archived|canonical|merged_into
  canonical_id TEXT REFERENCES meetings(id) ON DELETE SET NULL,
  processing_status TEXT NOT NULL DEFAULT 'pending',
  processing_error TEXT, content_hash TEXT,        -- blake3 of cleaned_transcript (content_fingerprint)
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  date_epoch  INTEGER GENERATED ALWAYS AS (CAST(strftime('%s', date) AS INTEGER)) STORED,
  start_epoch INTEGER GENERATED ALWAYS AS (CASE WHEN start_time IS NULL THEN NULL ELSE CAST(strftime('%s', start_time) AS INTEGER) END) STORED,
  CHECK(json_valid(topic_tags) AND json_valid(decisions) AND json_valid(action_items) AND json_valid(open_questions) AND json_valid(follow_ups)),
  CHECK(status IN ('active','archived','canonical','merged_into')));
CREATE INDEX ix_meetings_date ON meetings(date_epoch);
CREATE INDEX ix_meetings_source ON meetings(source);
CREATE INDEX ix_meetings_company ON meetings(company);
CREATE INDEX ix_meetings_status ON meetings(status);
CREATE INDEX ix_meetings_canonical ON meetings(canonical_id);
CREATE INDEX ix_meetings_chash ON meetings(content_hash);

-- ── join tables ────────────────────────────────────────────────────────
CREATE TABLE meeting_participants (meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  role TEXT, speaker_label TEXT, talk_seconds INTEGER, PRIMARY KEY(meeting_id, participant_id));
CREATE INDEX ix_mp_participant ON meeting_participants(participant_id);
CREATE TABLE meeting_companies (meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  company_id TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE, is_primary INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(meeting_id, company_id));
CREATE INDEX ix_mc_company ON meeting_companies(company_id);
CREATE TABLE meeting_tags (meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE, PRIMARY KEY(meeting_id, tag_id));
CREATE INDEX ix_mt_tag ON meeting_tags(tag_id);

-- ── chunks (retrieval unit) + entity mentions ──────────────────────────
CREATE TABLE transcript_chunks (chunk_id TEXT PRIMARY KEY,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, seq INTEGER NOT NULL,
  speaker TEXT, speaker_id TEXT REFERENCES participants(id) ON DELETE SET NULL,
  speaker_confidence REAL, is_inferred_speaker INTEGER NOT NULL DEFAULT 0,
  start_timestamp REAL, end_timestamp REAL, ts_confidence TEXT,  -- exact|coarse|derived|none
  text TEXT NOT NULL, token_count INTEGER, embedding_id TEXT,
  tags TEXT NOT NULL DEFAULT '[]', entities TEXT NOT NULL DEFAULT '[]',
  source_citation TEXT NOT NULL DEFAULT '{}', explanatory_score REAL,
  content_hash TEXT NOT NULL,                                    -- blake3(text) → re-embed trigger
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  CHECK(json_valid(tags) AND json_valid(entities) AND json_valid(source_citation)));
CREATE INDEX ix_chunks_meeting ON transcript_chunks(meeting_id, seq);
CREATE INDEX ix_chunks_speaker ON transcript_chunks(speaker);
CREATE INDEX ix_chunks_chash ON transcript_chunks(content_hash);

CREATE TABLE entity_mentions (mention_id TEXT PRIMARY KEY,
  entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  chunk_id TEXT NOT NULL REFERENCES transcript_chunks(chunk_id) ON DELETE CASCADE,
  surface_form TEXT NOT NULL, speaker TEXT, start_timestamp REAL, confidence REAL NOT NULL DEFAULT 1.0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')));
CREATE INDEX ix_em_entity ON entity_mentions(entity_id);
CREATE INDEX ix_em_chunk ON entity_mentions(chunk_id);

-- ── action items (date-gated) ──────────────────────────────────────────
CREATE TABLE action_items (task_id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT,
  assigned_to TEXT, assignee_id TEXT REFERENCES participants(id) ON DELETE SET NULL,
  assignee_is_me INTEGER NOT NULL DEFAULT 0, owner_role TEXT,  -- me|counterparty|unknown
  partner_or_company TEXT, company_id TEXT REFERENCES companies(id) ON DELETE SET NULL,
  source_meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  source_chunk_id TEXT REFERENCES transcript_chunks(chunk_id) ON DELETE SET NULL, source_timestamp REAL,
  due_date TEXT, confidence REAL NOT NULL DEFAULT 0.5, priority TEXT NOT NULL DEFAULT 'normal',
  status TEXT NOT NULL DEFAULT 'open', is_inferred INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  due_epoch INTEGER GENERATED ALWAYS AS (CASE WHEN due_date IS NULL THEN NULL ELSE CAST(strftime('%s', due_date) AS INTEGER) END) STORED,
  CHECK(priority IN ('low','normal','high','urgent')),
  CHECK(status IN ('open','in_progress','done','cancelled','stale')), CHECK(confidence BETWEEN 0 AND 1));
CREATE INDEX ix_ai_due ON action_items(due_epoch);
CREATE INDEX ix_ai_isme ON action_items(assignee_is_me, status, due_epoch);
CREATE INDEX ix_ai_company ON action_items(company_id);
CREATE INDEX ix_ai_meeting ON action_items(source_meeting_id);

-- ── files / imports / dedupe ───────────────────────────────────────────
CREATE TABLE imports (import_id TEXT PRIMARY KEY, source_channel TEXT NOT NULL, trigger TEXT NOT NULL,
  started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')), finished_at TEXT,
  files_seen INTEGER NOT NULL DEFAULT 0, files_new INTEGER NOT NULL DEFAULT 0,
  files_dup INTEGER NOT NULL DEFAULT 0, files_error INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'running', log_path TEXT, drive_change_token TEXT);
CREATE TABLE files (file_id TEXT PRIMARY KEY, import_id TEXT REFERENCES imports(import_id) ON DELETE SET NULL,
  meeting_id TEXT REFERENCES meetings(id) ON DELETE SET NULL, original_path TEXT NOT NULL, stored_path TEXT NOT NULL,
  source TEXT NOT NULL, kind TEXT NOT NULL, mime TEXT, size_bytes INTEGER, file_hash TEXT NOT NULL,  -- blake3 of bytes
  duration_seconds INTEGER, has_speaker_labels INTEGER, has_timestamps INTEGER,
  drive_file_id TEXT, drive_modified_time TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')));
CREATE UNIQUE INDEX ux_files_hash ON files(file_hash);   -- exact re-import = no-op
CREATE INDEX ix_files_meeting ON files(meeting_id);
CREATE INDEX ix_files_drive ON files(drive_file_id);

CREATE TABLE duplicate_links (link_id TEXT PRIMARY KEY,
  meeting_id_a TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  meeting_id_b TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  relation TEXT NOT NULL, composite_score REAL NOT NULL, signal_breakdown TEXT NOT NULL DEFAULT '{}',
  decision TEXT NOT NULL DEFAULT 'suggested',
  canonical_meeting_id TEXT REFERENCES meetings(id) ON DELETE SET NULL,
  decided_by TEXT NOT NULL DEFAULT 'system', decided_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
  UNIQUE(meeting_id_a, meeting_id_b), CHECK(meeting_id_a < meeting_id_b), CHECK(json_valid(signal_breakdown)),
  CHECK(decision IN ('auto_linked','suggested','confirmed','rejected','ignored')));
CREATE INDEX ix_dl_decision ON duplicate_links(decision);

-- ── embeddings registry + query logs ───────────────────────────────────
CREATE TABLE embeddings (embedding_id TEXT PRIMARY KEY,
  chunk_id TEXT NOT NULL REFERENCES transcript_chunks(chunk_id) ON DELETE CASCADE,
  space TEXT NOT NULL, vector_id TEXT NOT NULL, model_id TEXT NOT NULL, dim INTEGER NOT NULL,
  content_hash TEXT NOT NULL, embed_version INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')), UNIQUE(chunk_id, space));
CREATE INDEX ix_emb_space ON embeddings(space);
CREATE TABLE query_logs (query_id TEXT PRIMARY KEY,
  asked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')), query_text TEXT NOT NULL,
  query_type TEXT NOT NULL, date_filter TEXT, retrieved_chunk_ids TEXT NOT NULL DEFAULT '[]',
  cited_meeting_ids TEXT NOT NULL DEFAULT '[]', answer_text TEXT, refused INTEGER NOT NULL DEFAULT 0,
  refusal_reason TEXT, model_adapter TEXT, model_id TEXT, embedding_space TEXT, latency_ms INTEGER,
  token_estimate INTEGER, feedback TEXT,
  CHECK(json_valid(retrieved_chunk_ids) AND json_valid(cited_meeting_ids)));
CREATE INDEX ix_ql_asked ON query_logs(asked_at);

-- ── FTS5 (standalone, trigger-synced — NOT external-content) ────────────
CREATE VIRTUAL TABLE chunks_fts USING fts5(text, chunk_id UNINDEXED, meeting_id UNINDEXED, speaker UNINDEXED,
  tokenize='porter unicode61 remove_diacritics 2');
CREATE TRIGGER trg_chunks_fts_ai AFTER INSERT ON transcript_chunks BEGIN
  INSERT INTO chunks_fts(rowid,text,chunk_id,meeting_id,speaker) VALUES(new.rowid,new.text,new.chunk_id,new.meeting_id,new.speaker); END;
CREATE TRIGGER trg_chunks_fts_ad AFTER DELETE ON transcript_chunks BEGIN DELETE FROM chunks_fts WHERE rowid=old.rowid; END;
CREATE TRIGGER trg_chunks_fts_au AFTER UPDATE ON transcript_chunks BEGIN
  DELETE FROM chunks_fts WHERE rowid=old.rowid;
  INSERT INTO chunks_fts(rowid,text,chunk_id,meeting_id,speaker) VALUES(new.rowid,new.text,new.chunk_id,new.meeting_id,new.speaker); END;
CREATE VIRTUAL TABLE meetings_fts USING fts5(title, summary, body, meeting_id UNINDEXED,
  tokenize='porter unicode61 remove_diacritics 2');  -- maintained by analogous triggers; body=cleaned_transcript
```

Standalone (not external-content) FTS is deliberate: external-content FTS keys on integer `rowid`, unstable across `VACUUM` and clashing with TEXT-UUID PKs + Drive-sync portability; the extra text copy is trivial (transcripts are tens of MB) and buys robustness (HIGH). Migrations are forward-only, numbered, transactional; `VACUUM INTO 'premigrate-vN.sqlite3'` before each batch; non-trivial column changes use the 12-step table-rebuild recipe.

### 8.2 LanceDB layout

One table **per embedding space** `chunks_emb__{model}__v{n}` (default `chunks_emb__nomic__v1`, **DIM=768**; mxbai space = 1024 if toggled). PyArrow schema mirrors every filter column so pre-filtering happens inside the ANN scan:

```python
schema = pa.schema([
  ("id", pa.string()), ("chunk_id", pa.string()), ("meeting_id", pa.string()),
  ("vector", pa.list_(pa.float32(), 768)),
  ("date_epoch", pa.int64()), ("start_epoch", pa.int64()),
  ("speaker", pa.string()), ("company", pa.string()), ("source", pa.string()),
  ("call_type", pa.string()), ("is_action_item", pa.bool_()),
  ("action_due_epoch", pa.int64()), ("action_owner", pa.string()),
  ("is_canonical", pa.bool_()), ("explanatory_score", pa.float32()),
  ("text", pa.string()), ("model_id", pa.string()), ("embed_version", pa.int32()),
])
```

Vector index: HNSW while small, **IVF_PQ** past ~5–10k rows. **Scalar (BTREE/BITMAP) indexes** on `meeting_id, date_epoch, speaker, company, source, call_type, is_action_item, action_due_epoch, is_canonical` → true pre-filter (`prefilter=True`). 1:1 link `transcript_chunks.embedding_id → embeddings.embedding_id → LanceDB.id`. Re-embed on `content_hash` mismatch (single-row delete+add). **Model/version change = new space, atomic flip:** build new space in background → flip `settings.active_embedding_space` in one txn → GC old after grace period (instant rollback). *(VERIFY at build: exact scalar-index creation API + `where=` pushdown syntax for the pinned LanceDB wheel — §18.)*

### 8.3 Dedupe engine

Signals (each [0,1]): `s_filehash` (exact bytes), `s_date` (Gaussian σ=1800s + same-day bump), `s_participants` (Jaccard, email-keyed), `s_title` (token-set/Levenshtein/title-embedding cosine), `s_duration`, `s_transcript` (mean-pooled chunk-vector cosine ∨ MinHash on first ~800-word shingles), `s_filename`.

```
composite = 0.28·s_transcript + 0.22·s_participants + 0.20·s_date
          + 0.15·s_title + 0.08·s_duration + 0.07·s_filename
```

| composite | decision | action |
|---|---|---|
| `s_filehash==1` | `auto_linked` (exact_file) | file-level dedupe, no new meeting |
| ≥0.92 **and** ≥2 strong signals¹ **and** passes hard gates² | `auto_linked` (same_meeting_diff_source) | link + canonicalize |
| 0.75–0.92 | `suggested` | **Duplicate Review** queue, await human |
| <0.75 | `ignored` | no link |

¹ 2 of {`s_participants≥0.6`, `s_date≥0.8`, `s_transcript≥0.7`}. ² **Hard false-merge gates (override composite):** `s_participants<0.5` → never auto-link; `|Δdate|>24h` → never auto-link (recurring "Weekly Travis Sync" must not collapse across weeks); conflicting calendar/event id → never auto-link. **Canonical priority** (lower tier wins): T1 transcript w/ speakers+timestamps > T2 w/ speakers > T3 transcript no speakers > T4 summary/notes only > T5 A/V only; tie-break by completeness × source-trust × earliest `created_at`. **Link-not-delete:** non-canonical rows get `status='merged_into', canonical_id=…`, retained in full; canonical absorbs complementary fields by precedence (action_items = union-with-dedupe, every citation kept); only canonical chunks are `is_canonical=true` in LanceDB (others searchable via "include linked sources" toggle); fully reversible.

### 8.4 Storage layout, naming, backup

Root `~/Library/Application Support/CallBrain/`:
```
data/raw/{fathom,fireflies,cluely,gmeet_recordings,manual}/   # immutable originals
data/processed/{transcripts,audio,metadata}/                  # cleaned CTM, 16k wav, <id>.json sidecars
data/exports/                                                 # briefings, reviews, .cbk backups
database/callbrain.sqlite3 (+ -wal,-shm)   database/vectors.lancedb/
models/{whisper,diarization}/   runtime/{handshake-*.json,single.lock,logs/}   config.json
```
Originals copied/hard-linked, never mutated. Canonical filename `YYYY-MM-DD - People - Company/Topic - Source.ext` (auto-applied to the managed copy; UUID is real identity). **Backup = one `.cbk`** (zstd tar): `callbrain.sqlite3` via `VACUUM INTO` (hot, consistent), `processed/`, optional `vectors.lancedb/` (or `reembed_required` flag — vectors are derivable), and `manifest.json` (schema_version, app_version, embedding_model+dim+active_space, sha256 inventory). Restore validates manifest → migrates if older / refuses if newer → re-embeds if model/dim mismatch → atomic temp-dir swap with `.restore-backup` rollback. Drive sync layers on `files.drive_file_id` + `imports.drive_change_token`.

---

## 9. Native App, Sidecar & Packaging

### 9.1 App architecture (Swift 6 strict concurrency)

View models are `@MainActor @Observable`; `SidecarSupervisor`/`SidecarClient` are **actors off the main actor**; all DTOs `Codable, Sendable`. **12 screens via one `NavigationSplitView`** (9 sidebar destinations + 3 detail/secondary): Home, Ask AI (⌘⇧A), Meetings (3-column), Meeting Detail, Transcript Viewer (`openWindow` tear-off + ⌘F), Tasks (⌘⇧T), People, Partners/Companies, Topics, Import Queue (badge), Duplicate Review (sheet from Import Queue), Settings (⌘,). Meetings uses the three-column form; Transcript Viewer tears into its own window so the user reads the transcript while chatting (the "verify the citation" flow). `SidecarClient` (actor) carries `Authorization: Bearer <token>`, typed `SidecarError` enum, and a semver `/version` handshake (refuses incompatible sidecar). SSE via `URLSession.bytes`/`.lines` (no third-party SSE lib): Ask AI streams `delta` then terminal `citations`+`confidence` frames; Import Queue subscribes to one long-lived `GET /events` (reconnect with `Last-Event-ID`). Drag-drop via `.dropDestination(for: URL.self)` (files+folders) → POST **paths** to `/import` (sidecar reads directly, no copy). Shortcuts: ⌘K palette, ⌘⇧A Ask, ⌘⇧T Tasks, ⌘N import, ⌘F in-transcript, ⌘R reprocess, ⌘, settings.

### 9.2 Sidecar lifecycle

Supervisor state machine: `idle→launching→waitingForHandshake→healthy` (↔`degraded`/`restarting` backoff → `failed`). **Dev:** `uv run --project backend python -m callbrain` (pyproject `requires-python=">=3.12,<3.13"` so uv never picks system 3.14). **Packaged:** spawn `Bundle.main.resourceURL/callbrain-sidecar/callbrain-sidecar` (PyInstaller onedir). **Handshake:** app generates `token=base64url(32B)` + unique handshake path; spawns sidecar with `CALLBRAIN_TOKEN/HANDSHAKE_PATH/BIND_HOST=127.0.0.1/PARENT_PID`; sidecar binds **`127.0.0.1:0`** (kernel-assigned ephemeral port), atomically writes `{pid,port,version,startedAt}` (chmod 0600, **no token on disk**); app watches via `DispatchSource`, transitions `healthy` after `/healthz` 200. Per-request bearer constant-time-compared → 401 otherwise; token regenerated every launch. Health check every ~5s (2s timeout); 3 failures or unexpected exit → exp backoff restart (1,2,4,8,16s; max 5/60s) → `failed` with "Restart engine / Show logs". Graceful ⌘Q: `POST /shutdown` flushes job queue to SQLite, removes handshake, exits 0 (≤5s then SIGTERM/SIGKILL). **Parent-death watchdog (macOS has no `PR_SET_PDEATHSIG` — HIGH):** sidecar checks `os.getppid()==PARENT_PID` every 1s, self-terminates if app died. Single-instance: app `flock` on `single.lock`; sidecar kills+respawns any stale handshake pid (re-warm is near-zero since embeddings live in the always-on Ollama daemon).

### 9.3 Packaging (heavy deps + ffmpeg)

**PyInstaller `onedir`** (not onefile — onefile unpacks to `$TMPDIR` each launch and unsigned extracted dylibs trip Hardened Runtime). Rejected py2app (weak with torch/ctranslate2) and briefcase. **Base bundle is LIGHT** (~tens of MB, fast notarization): FastAPI+uvicorn+httpx+pydantic+numpy+**LanceDB**+spaCy — **no torch, no whisper**. **Local Transcription Pack** (Developer-ID-signed + notarized zip, hosted by us) downloaded on first raw-video detection: faster-whisper/CTranslate2 (no torch) + large-v3 model + pyannote 3.1 (+ its torch sub-component) with HF-accepted weights vendored at pack-build; installed to `…/CallBrain/models/`, signature-verified (`spctl`/`codesign --verify`) before activation. **Bundle a static arm64 `ffmpeg`/`ffprobe`** in `Contents/Resources` (LGPL/BSD build — legal sign-off; not installed on this Mac, non-coder won't `brew`); invoked by absolute path. Because embeddings are Ollama-local, the base app needs no Python ML stack at all. **Sign inside-out (leaf-first):** every Mach-O (`.so`/`.dylib`, frozen sidecar, embedded Python, ffmpeg) signed Developer ID + `--options runtime` + `--timestamp` + entitlements; `.app` last; **never `codesign --deep`**. **Notarize:** `notarytool submit --wait` → `stapler staple` (app + Pack separately). **Distribute** DMG/zip; **Sparkle** EdDSA appcast for updates.

### 9.4 Security & entitlements

**Hardened Runtime YES, App Sandbox NO** (direct-download, not App Store — matches founder rule; sidecar must spawn `claude`/`codex` from `~/.local/bin`,`/opt/homebrew/bin` and read user files freely). Entitlements: main app Hardened Runtime; sidecar adds `cs.disable-library-validation` (frozen Python + differently-signed Pack dylibs — MED-HIGH), `cs.allow-unsigned-executable-memory` (numpy/CTranslate2/cffi — MED), `cs.allow-dyld-environment-variables` (PyInstaller `DYLD_*`). Spawning `claude`/`codex` as separate processes is unaffected by library validation (HIGH). **PATH gotcha (HIGH):** Finder-launched apps don't inherit shell `PATH`; resolve CLIs by probing absolute locations (`~/.local/bin/claude`, `/opt/homebrew/bin/codex`, …) + one-time `zsh -lic 'command -v claude codex'`, persist + allow Settings override, and pass a curated child `PATH` (also lets `codex` find `node`).

---

## 10. Privacy & Security Model

- **Local-first by construction:** originals, normalized audio, transcripts, embeddings (Ollama), vector index, SQLite, extraction — all on-device. No cloud dependency for core function (Constraint 1).
- **The one honest caveat — generation egress:** Ask-AI / extraction send **transcript excerpts to the user's Claude/ChatGPT CLI subscription, which are cloud models.** Surfaced explicitly: one-time first-Ask consent + persistent indicator on every AI surface ("Answers come from your Claude/ChatGPT subscription, a cloud service; relevant excerpts are sent there. Embeddings, search, and storage stay on your Mac"), a **"Preview what's sent"** affordance showing the exact context window before egress, and an optional fully-local fallback (Ollama LLM, zero egress) for privacy-maximalists. Future: optional PII redaction before egress (flag, not V1).
- **No generation/embedding API keys exist** (Constraints 1+3) — a genuine privacy win to advertise. The **only true secret** is the Google OAuth refresh token (Drive sync, later), stored in the login Keychain (`kSecClassGenericPassword`, service `com.callbrain.app`), owned by the Swift app; the sidecar receives only short-lived access tokens over authenticated loopback, never written to disk or passed to CLIs. Provider/model/effort choices are config, not secrets. Handshake token is ephemeral, in-memory.
- **Engine boundary hardening:** loopback-only bind + per-launch constant-time bearer (no other local app/user can drive the engine); env-key scrubbing forces subscription auth; CLI capability-denial + injection delimiting (§5.6); CI grep-gate bans `--bare`, `--dangerously-*`, and any `ANTHROPIC_API_KEY=` in the provider module.
- **AI-agent-trap alignment:** all transcript/web/MCP content is untrusted DATA, never instructions; the agentic CLIs have no tool/shell/network in our calls, so an injected imperative is inert.

---

## 11. Phased Build Plan

Path-B oriented: the core capture→index→ask loop works in Phase 1; everything after is depth and polish. **Every phase ends with a Codex audit gate** (`codex exec -s read-only` over the branch diff + a written checklist; a second pair of eyes per Constraint 8). Workstreams within a phase are parallelizable where marked.

### Phase 0 — Foundations & Ground-Truth Verification
- **Goal:** prove every assumption against real artifacts and stand up the skeleton.
- **Deliverables:** repo scaffold (§13); uv 3.12 env + pinned `pyproject`/lock; Ollama running + `nomic-embed-text` pulled, `num_ctx:8192` asserted; CLI capability probe (run §5.2/§5.3 micro-calls, snapshot envelope shapes for `claude` 2.1.196 / `codex` 0.142.3); empty CLI sandbox dir; **collect ~5 real samples of each source** (Fathom copy, Fireflies JSON, Gemini/Meet Doc, Cluely note, raw Meet `.mp4`) and snapshot format fingerprints; verify Drive `Meet Recordings` has sibling Docs; static ffmpeg fetched.
- **Parallel:** (A) repo+env+CI grep-gate; (B) Ollama+embedding bring-up; (C) CLI probes; (D) real-artifact collection + fingerprinting.
- **Dependencies:** none.
- **Exit:** one real artifact of each available type round-trips through a throwaway parser into the CTM; `claude -p` and `codex exec` each return a clean answer + valid schema JSON; embedding call returns a 768-vector at 8192 ctx.
- **Codex audit gate:** reviews env-isolation correctness (3.12 pin, API-key scrubbing, sandbox emptiness), the verified-vs-assumed table, and that no `--bare`/`--dangerously-*` appears anywhere.

### Phase 1 — Core Capture→Index→Ask Loop (MVP, usable this week)
- **Goal:** drop a transcript → ask a cited question. The loop genuinely works.
- **Deliverables:** parsers for the 1–2 formats the user actually has most (likely Fireflies JSON + Fathom copy) → CTM normalize → speaker-turn chunker → embed (nomic) → SQLite+FTS5+LanceDB write; hybrid retrieval (FTS5⊕LanceDB, RRF, `prefilter=True`) + refusal gate + citation validator; `LocalCLIProvider` **Claude adapter only** (`complete`/`complete_json`); **General Ask + Person modes** with full citation envelope; minimal SwiftUI shell (Ask AI, Meetings list, Meeting Detail, Transcript Viewer) + `SidecarSupervisor`/handshake/health.
- **Parallel:** (A) parsers+normalize+chunk; (B) stores+retrieval+RRF; (C) Claude adapter+citation validator; (D) SwiftUI shell+supervisor.
- **Dependencies:** Phase 0.
- **Exit:** "What did Travis say about Render?" returns a correct, cited answer with tappable transcript anchors; a no-evidence question refuses; supervisor survives a forced sidecar kill (auto-restart).
- **Codex audit gate:** reviews citation enforcement (no claim without a chunk), the pre-filter correctness (date/speaker actually applied inside ANN), refusal-before-generation, and actor isolation (no `@MainActor` blocking).

### Phase 2 — Ingestion Intelligence & Durable Pipeline
- **Goal:** "just detect and do the right thing" for every source, idempotently, never silently.
- **Deliverables:** full 3-stage detector + routing table + sibling-pairing; all parsers (Gemini Doc, Cluely, SRT/VTT, generic) tolerant + per-file confidence + fingerprint learning; metadata auto-heal + filename normalization; hybrid entity/NER pass (spaCy + gazetteer + LLM-assist); two-tier BLAKE3 idempotency + duplicate-group detection; the full import state machine with per-state checkpoints, durable SQLite job queue, never-silent-fail wrapper; `GET /imports` + SSE; Import Queue + needs_review UI.
- **Parallel:** (A) detector+router+pairing; (B) remaining parsers+fingerprints; (C) state machine+queue+resumability; (D) entities/NER; (E) Import Queue/needs_review UI.
- **Dependencies:** Phase 1 (normalize/chunk/embed exist).
- **Exit:** dropping a mixed folder routes each file correctly or parks it with a plain-English reason; crash mid-import resumes from last checkpoint; re-dropping a file is a no-op.
- **Codex audit gate:** reviews the confidence-gate math (no coin-flip routing), idempotency (no dup meetings, no re-transcribe), state-machine resumability, and that every exception path lands in `failed`/`needs_review` (no silent drop).

### Phase 3 — Local Transcription Path (raw Google Meet video)
- **Goal:** raw `.mp4` with no transcript becomes a first-class, diarized, cited meeting.
- **Deliverables:** bundled ffmpeg → 16k mono; faster-whisper large-v3 (int8, word ts) + `large-v3-turbo` toggle; pyannote 3.1 diarization + word↔turn alignment + churn smoothing; `transcript_versions` with local v0 immutable; per-file "upgrade to cloud transcription" action; transcription progress as fraction-of-audio; **Local Transcription Pack** download/verify/install flow.
- **Parallel:** (A) ffmpeg+ASR; (B) diarization+alignment; (C) Pack packaging+download/verify; (D) cloud-upgrade hook + version UI.
- **Dependencies:** Phase 2 (routing sends raw media here).
- **Exit:** a real raw Meet recording produces a speaker-labeled, timestamped, citable transcript; cloud upgrade appends v1 without destroying v0; citations re-derive from the active version.
- **Codex audit gate:** reviews diarization-alignment correctness, `is_inferred_speaker` propagation into citations, Pack signature verification before activation, and CPU-bound resource caps (no UI starvation).

### Phase 4 — Retrieval Depth & Anti-Hallucination
- **Goal:** all 8 modes, hard date-gating, action items, and a passing eval harness.
- **Deliverables:** remaining 6 modes (This Week, Company 6-slot, Technical Explainer w/ `explanatory_score`, Action-Item Extractor, Pre-Call Briefing, Post-Call Review); deterministic query planner + LLM-fallback; local-tz date math; action-item extraction + the reconciled "this week" gate (§7.6); weak-evidence labeling; full **eval harness** (§15) wired to both adapters; query_logs audit.
- **Parallel:** (A) modes 2/3/4; (B) modes 5/6; (C) modes 7/8 + cross-refs; (D) planner+date math; (E) eval harness + golden corpus.
- **Dependencies:** Phase 1 retrieval; benefits from Phases 2–3 data breadth.
- **Exit:** the §15 table passes targets (citation precision ≥0.95, date-gating violations =0, attribution purity =1.0, refusal-correctness =1.0); negatives 11–12 refuse.
- **Codex audit gate:** reviews date-math boundary cases (week_start, DST, undated-task rule), explanatory rerank not leaking general knowledge, and that no mode delegates a hard filter to the LLM.

### Phase 5 — Provider Resilience (Codex adapter, flip-flop, fallback, streaming)
- **Goal:** the founder flips Claude↔Codex at will and never thinks about quotas.
- **Deliverables:** Codex adapter (`complete`/`complete_json` via `-o`/`--output-schema`, `--json` streaming); router `which()` + availability probes (30s cached health); full fallback matrix (rate-limit detection via inline `rate_limit_event`/`resetsAt` and codex stderr; defer-and-resume; opt-in Ollama last-resort for bulk); token-bucket pacing + per-provider semaphores + high-priority interactive lane; SSE bridge (`/chat/stream`) with provider+model badge and transparent fallback toast.
- **Parallel:** (A) Codex adapter; (B) router/availability/fallback; (C) queue pacing/semaphores; (D) SSE bridge + badge UI.
- **Dependencies:** Phase 1 (Claude adapter + queue).
- **Exit:** a forced Claude rate-limit transparently completes on Codex with a badge change + toast; a 300-item bulk backfill never blocks an interactive question; deferred jobs resume after the reset time.
- **Codex audit gate:** reviews env-scrubbing on both adapters, rate-limit signal parsing, deadlock-freedom of the semaphore/lane design, and the grep-gate ban list.

### Phase 6 — Native Polish (background, notifications, menu bar, Drive sync, Duplicate Review)
- **Goal:** Path-B premium feel; "set it and forget it."
- **Deliverables:** `beginActivity` to defeat App Nap during jobs; ⌘Q-with-jobs prompt → `MenuBarExtra` background mode; `UserNotifications` (import/transcription complete, failure w/ Retry + Upgrade actions, **overdue/owed tasks via `UNCalendarNotificationTrigger`** firing even when quit); Google Drive sync (OAuth via `ASWebAuthenticationSession`, `Meet Recordings` watch via `files.drive_file_id` + `drive_change_token`, security-scoped bookmarks); refined **Duplicate Review** UI (signal breakdown, one-tap confirm/reject, reversible).
- **Parallel:** (A) background+menu bar; (B) notifications+task scheduling; (C) Drive sync+OAuth; (D) Duplicate Review UI.
- **Dependencies:** Phases 2 (dedupe, queue), 4 (task gate).
- **Exit:** quitting with jobs keeps them running in the menu bar; an overdue BGIN/Iceriver follow-up notifies while the app is quit; new Drive recordings auto-import; a suggested duplicate is confirmed/undone losslessly.
- **Codex audit gate:** reviews Keychain ownership (secrets never reach the sidecar/CLIs), notification date-gate correctness, Drive token handling, and dedupe reversibility.

### Phase 7 — Archive Migration (bulk backfill of scattered history)
- **Goal:** import the user's real, messy multi-year archive end-to-end.
- **Deliverables:** bulk-import driver over `data/raw` + Drive `Meet Recordings`; throttled pacing under the 5-hour/weekly windows; progress dashboard ("Indexing 142/318"); duplicate-group resolution pass; a post-migration eval re-run on the real corpus to tune refusal/`explanatory_score` thresholds.
- **Parallel:** (A) migration driver+pacing; (B) progress/reporting; (C) threshold tuning on real data.
- **Dependencies:** Phases 2–5 (full pipeline + resilience), 6 (Drive).
- **Exit:** the entire archive is `done`/`duplicate`/`needs_review` with zero silent drops; the §15 eval still passes on the real corpus; thresholds locked from measured data.
- **Codex audit gate:** reviews quota-safety of the bulk run, that transcription is never redundantly re-run, dedupe correctness at scale, and that tuned thresholds are recorded (not hardcoded magic).

### Phase 8 — Packaging, Signing, Notarization, Auto-update
- **Goal:** a signed, notarized, auto-updating direct-download app a non-coder installs by double-click.
- **Deliverables:** PyInstaller onedir build script (leaf-first signing) + entitlements; notarize + staple (app + Pack); static-ffmpeg license clearance; Sparkle EdDSA appcast + hosting; `.cbk` backup/restore; first-run wizard (detect/start Ollama, pull model, resolve CLI paths, request notification auth, egress consent).
- **Parallel:** (A) freeze+sign+notarize; (B) Sparkle+hosting; (C) backup/restore; (D) first-run wizard.
- **Dependencies:** all prior.
- **Exit:** clean Mac installs from DMG, passes Gatekeeper, completes first-run wizard, ingests + answers; an auto-update is delivered and applied; restore from `.cbk` reconstructs state.
- **Codex audit gate:** reviews signing/entitlements minimality (no over-broad entitlements), notarization of every Mach-O, Pack signature verification, and that the shipped bundle contains no secrets and no API-key code path.

---

## 12. MVP Scope (Phase-0/1 — the usable slice this week)

The smallest thing the founder can actually use: **drop a transcript, ask a cited question.**

**In scope:** Phase 0 setup + Phase 1. Parsers for the two formats the user has most (Fireflies JSON + Fathom copy — confirmed in Phase 0); normalize→chunk→embed (nomic via Ollama)→SQLite+FTS5+LanceDB; hybrid retrieval + RRF + `prefilter`; **Claude adapter only**; **General Ask + Person** modes with full citations (title + date + speaker + timestamp + tappable transcript anchor) and a real refusal on no-evidence; minimal SwiftUI (Ask AI, Meetings list, Meeting Detail, Transcript Viewer) + supervised sidecar.

**Explicitly deferred:** local video transcription (Phase 3), the other 6 modes + action-item date-gating (Phase 4), Codex adapter + fallback + streaming (Phase 5), dedupe/Drive/notifications/menu bar (Phase 6), bulk migration (Phase 7), packaging (Phase 8). MVP runs via `uv run` (no notarized bundle yet).

**First-run founder flow:** paste/drop 5–10 Fathom/Fireflies transcripts → ask "What did Travis say about Render?" and "What did Max explain about Proof of Logits?" → get cited answers, click a citation, land on the exact transcript line. That is the product's core promise, working, in week one.

---

## 13. Repo Structure

```
callbrain/
├── backend/
│   ├── pyproject.toml            # requires-python ">=3.12,<3.13"; uv lock
│   ├── callbrain/
│   │   ├── __main__.py           # programmatic uvicorn.Server, bind :0, write handshake
│   │   ├── app.py                # FastAPI app, auth dependency, lifespan
│   │   ├── config.py settings.py
│   │   ├── api/                  # routers: ask, meetings, tasks, imports, people, orgs, topics,
│   │   │                         #          duplicates, events(SSE), config, version, healthz, shutdown
│   │   ├── providers/            # base.py claude.py codex.py ollama.py router.py json_repair.py
│   │   ├── ingest/
│   │   │   ├── detect/           # sniff.py signatures.py gate.py fingerprints.py
│   │   │   ├── parse/            # fireflies.py fathom.py gmeet_doc.py cluely.py srt_vtt.py generic.py
│   │   │   ├── normalize/        # ctm.py person_resolver.py merge.py timestamps.py
│   │   │   ├── transcribe/       # ffmpeg.py whisper.py diarize.py align.py pack.py cloud_upgrade.py
│   │   │   ├── meta.py entities.py chunk.py
│   │   │   └── statemachine.py jobqueue.py router.py
│   │   ├── retrieve/             # plan.py datemath.py fts.py vector.py rrf.py gates.py dedupe_runtime.py
│   │   ├── answer/               # modes/ (8) prompts.py citations.py validator.py envelope.py
│   │   ├── dedupe/               # signals.py combiner.py canonical.py merge.py
│   │   ├── store/                # sqlite.py migrations/ lancedb.py embeddings.py backup.py
│   │   └── eval/                 # harness.py fixtures/ assertions.py
│   └── tests/                    # unit/ integration/ eval/ fixtures/(real-sample snapshots)
├── macos-app/
│   ├── CallBrain.xcodeproj
│   └── CallBrain/
│       ├── App/                  # CallBrainApp.swift Commands.swift MenuBarExtra.swift
│       ├── Engine/               # SidecarSupervisor.swift SidecarClient.swift SSE.swift DTOs.swift Errors.swift
│       ├── Stores/               # EngineStatusStore.swift + feature VMs
│       ├── Views/                # Home/ Ask/ Meetings/ Transcript/ Tasks/ People/ Orgs/ Topics/ Imports/ Duplicates/ Settings/
│       ├── Design/               # tokens, semantic colors (DESIGN.md-driven)
│       └── Resources/            # bundled ffmpeg, ffprobe, entitlements
├── scripts/                      # build_sidecar.sh sign.sh notarize.sh make_pack.sh appcast.sh dev_up.sh
├── docs/                         # this plan, ADRs, source-format findings, eval reports
├── data/                         # (gitignored) raw/ processed/ database/ models/ exports/ runtime/
└── README.md
```

---

## 14. Local Backend API

All under `http://127.0.0.1:<ephemeral>`, `Authorization: Bearer <token>` required (except `/healthz`). Responses use the house envelope `{success, data, error}`; streams are `text/event-stream`.

| Method | Path | Params / body | Response |
|---|---|---|---|
| GET | `/healthz` | — | `{status:"ok"}` (no auth) |
| GET | `/version` | — | `{version, schema_version, embedding_model, dim, active_space}` |
| GET | `/config` · PUT `/config` | settings patch (JSON) | current settings (provider_policy, week_start, embedding toggle, …) |
| POST | `/import` | `{paths:[…], source_hint?}` | `{import_id, queued:[file_id…]}` |
| GET | `/imports` | `?state=` | list `[{import_id, file, state, pct, reason?}]` |
| GET | `/imports/stream` | SSE | per-file state/pct events |
| GET | `/jobs` · POST `/jobs/{id}/retry` | — | queue state / retry |
| GET | `/events` | SSE (`Last-Event-ID`) | multiplexed job + engine events |
| POST | `/meetings/{id}/reprocess` | — | re-chunk/re-embed/re-extract |
| GET | `/meetings` | `?q&from&to&speaker&company&source&limit&cursor` | `[{id,title,date,source,participants,company,call_type,status}]` |
| GET | `/meetings/{id}` | — | meeting envelope (summary, decisions, actions, versions, sources) |
| GET | `/meetings/{id}/transcript` | `?version` | ordered utterances w/ speaker/timestamps/anchors |
| POST | `/needs_review/{id}/resolve` | `{source_class \| is_raw_video}` | re-enters detecting; teaches fingerprint |
| POST | `/ask` | `{query, mode?, tz, provider_override?}` | answer envelope (§7.6) |
| GET | `/chat/stream` | `?query&mode&tz&provider_override` (SSE) | `token`/`ratelimit`/`done{provider,model,citations}`/`error{reason,fallback}` |
| GET | `/tasks` | `?window=this_week\|overdue\|all&owner&company&tz` | `[{task_id,title,owner,owner_role,due,status,sources[]}]` (date-gated) |
| GET | `/people` · `/people/{id}` | — | participants + per-person meeting/quote rollups |
| GET | `/orgs` · `/orgs/{id}` | — | companies + 6-slot rollup feed |
| GET | `/topics` · `/topics/{id}` | — | tags/entities + topic-graph edges |
| GET | `/duplicates` | `?decision=suggested` | `[{link, signal_breakdown, a, b, proposed_canonical}]` |
| POST | `/duplicates/{link_id}` | `{decision, canonical?}` | confirm/reject/undo (reversible) |
| GET | `/briefing` | `?person\|company&tz` | Pre-Call Briefing envelope (mode 7) |
| POST | `/meetings/{id}/review` | — | Post-Call Review envelope (mode 8) |
| POST | `/backup` · POST `/restore` | `{path}` | `.cbk` create / validated restore |
| POST | `/shutdown` | — | graceful flush + exit |
| GET | `/providers/availability` | — | per-provider `{installed,logged_in,model,rate_limited_until}` |

---

## 15. Eval Tests & Success Criteria

Each fixture: `{query, expected_plan, gold_chunk_ids, assertions}`; the harness runs the full pipeline (plan→retrieve→generate→validate) against **both** adapters; assertions are pure functions over the answer envelope. **Targets: citation precision ≥0.95 · date-gating violations =0 · speaker-attribution purity =1.0 · refusal-correctness =1.0.**

| # | Canonical question | Mode | Expected filters | Checkable success criterion |
|---|---|---|---|---|
| 1 | "What did Travis say about Render?" | Person | speaker=Travis; terms=Render | 100% citations `speaker=Travis`; each cited chunk contains "Render"/alias; no non-Travis chunk in context (purity=1.0) |
| 2 | "What did Max explain about Proof of Logits?" | Explainer | topic=proof_of_logits | top-3 `explanatory_score≥0.6`; cited = Max's explanatory turns; ≥1 confirmed; "based only on your calls" present |
| 3 | "Action items assigned to me this week (only)?" | Action | is_action_item; owner=me; this_week; either | **zero** items violate §7.6; old undated tasks absent; null owner/due labeled |
| 4 | "Follow-ups I owe BGIN/Iceriver?" | Action | owner_role=me; companies∋{BGIN,Iceriver} | every item owner=me ∧ company∈set; recurring consolidated w/ all source dates cited |
| 5 | "Any mentions of ASICs?" | General | terms=ASIC | BM25 returns literal "ASIC" chunks; every citation contains the token; no fabrication |
| 6 | "Explain validators based only on my calls." | Explainer | topic=validators | cites only call chunks; thin coverage → explicit gap statement; unsupported-claim count=0 |
| 7 | "What should I ask Travis next?" | Pre-Call | participant/company=Travis + open actions | every suggested question grounded in ≥1 cited prior chunk; owed-both-directions enumerated |
| 8 | exact keyword "Render" | General | terms=Render (lexical) | FTS5 ranks exact-token chunks #1; literal "Render" in every top citation |
| 9 | semantic "compute provider" | General | terms (semantic) | vector lane surfaces Render/OpenRouter/GPU chunks **without** the literal phrase (recall@5 ≥1 gold) |
| 10 | same call from 2 sources | any | — | one canonical meeting; dup chunks suppressed; surviving citation lists `also_in_sources`; no double-count |
| 11 (neg) | "Travis on Solana staking?" (never discussed) | Person | speaker=Travis | `status=no_sources`; refusal names the gap; zero fabricated claims |
| 12 (neg) | "Action items this week" when none exist | Action | this_week | `status=no_sources` ("no calls in the selected week"); no old tasks leak |

Negatives (11–12) are first-class: a graceful, specific refusal is a **pass**; a confident answer is a **fail**. Date-gating violations and attribution-purity breaches are **release-blocking**.

---

## 16. Migration Plan (the user's scattered archive)

1. **Inventory & verify (Phase 0/7):** point the migration driver at `data/raw` + Drive `Meet Recordings`; produce a manifest of every file with detected `container_type`/`source_class`/confidence. Confirm the §4/§18 unknowns on real samples (Meet Transcript-vs-Notes, Fathom delimiter, Cluely timestamps).
2. **Stage originals immutably:** copy/hard-link each into `data/raw/<source>/` (never mutate); compute `file_hash` (BLAKE3) → instant skip on exact re-drops.
3. **Route deterministically:** run the 3-stage detector; transcript-first items → PARSE; raw `.mp4` with a matched sibling Doc → PARSE+ATTACH; raw `.mp4` with no Doc → TRANSCRIBE queue; ambiguous → `needs_review` (surfaced, never guessed).
4. **Throttled bulk processing:** drain the durable queue under per-provider token-buckets (stay below the 5-hour/weekly windows); transcription is the expensive, checkpointed step — never re-run if its artifact validates. Live "Indexing N/Total" + per-file %.
5. **Normalize → enrich → index:** CTM → chunk → embed (nomic) → SQLite+FTS5+LanceDB; entity/NER + summaries.
6. **Dedupe pass:** compute composite scores; `auto_link` only above 0.92 + hard gates; everything 0.75–0.92 → **Duplicate Review** for one-click confirm; pick canonical by tier/trust.
7. **Resolve the review queues:** founder clears `needs_review` (source overrides teach fingerprints) and Duplicate Review; nothing is dropped.
8. **Validate & tune:** re-run the §15 eval on the real corpus; tune refusal (`max_cos` 0.35/0.55) and `explanatory_score` weights from measured data; record tuned values in `settings`.
9. **Backup:** produce a `.cbk` snapshot (`VACUUM INTO` + manifest) as the user-owned escape hatch.

Resumable throughout: a crash mid-migration restarts from the last per-file checkpoint, not from scratch.

---

## 17. Risks & Mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| **Meet "premium" drops only Gemini Notes, not verbatim Transcript Docs** | HIGH | Phase 0 verifies on real Drive; either way the router pairs Doc↔mp4 and falls back to local whisper when no verbatim Doc — graceful. (#1 unknown, §18) |
| **Undocumented export drift** (Fathom clipboard, Cluely) | MED-HIGH | tolerant multi-pattern parsers + per-file confidence + first-import fingerprint calibration + `needs_review` fallback |
| **CLI version drift** (flag/envelope changes across `claude`/`codex`) | HIGH | pin observed versions; startup capability-probe asserts envelope shape; degrade to text-mode + local JSON repair on mismatch |
| **Quota exhaustion mid-bulk** (hundreds of meetings) | HIGH | durable SQLite queue + token-bucket pacing + 5h/weekly awareness (`rate_limit_event`/`resetsAt`) + claude↔codex fallback + defer-and-resume + opt-in Ollama; interactive lane isolated |
| **Prompt injection from transcripts** | HIGH | capability denial first (`--tools ""` / `-s read-only`, no MCP), DATA-not-instructions delimiting, output validated never executed |
| **Accidental API billing** (`ANTHROPIC_API_KEY` in env or `--bare`) | MED | scrub keys from child env; CI grep-gate bans `--bare`/`--dangerously-*`/`ANTHROPIC_API_KEY=` |
| **faster-whisper CPU-only on Apple Silicon** (slow, battery) | MED | `large-v3` default + `large-v3-turbo` toggle; transcription in background queue; future whisper.cpp+CoreML accel path |
| **pyannote 3.1 HF-gated weights** | MED | vendor accepted weights into the Pack at pack-build (token only on build machine, never shipped) |
| **LanceDB scalar-index / prefilter API differs on pinned wheel** | MED | verify exact API in Phase 0/2 against the uv-locked version before relying on pre-filter performance (§18) |
| **Hardened-Runtime entitlements for frozen torch** | MED | empirically notarize a torch-bearing test bundle; add only the minimum entitlement that resolves the actual crash signature |
| **Static ffmpeg licensing** | MED | choose LGPL/BSD redistribution-safe arm64 build; legal sign-off on codecs |
| **False meeting merges** | MED | hard gates (participants<0.5 / Δdate>24h / conflicting event-id never auto-link) + ≥2-strong-signal rule; default = suggest+confirm |
| **Non-determinism / model updates** | MED | reasoning-effort pinning; cache answers by (prompt-hash, model, provider); model badge; golden-set regression (§15) |
| **Orphan/zombie sidecars** | LOW | parent-death watchdog (no `PR_SET_PDEATHSIG` on macOS), kill-and-respawn on stale handshake, single-instance `flock` |
| **Ollama down / no model** | LOW | first-run wizard detects/starts/pulls; embeddings queue and degrade gracefully, never block UI |

---

## 18. Open Questions for the Founder (blocking only)

1. **Does your "Meet premium" actually save a *verbatim Transcript* Google Doc beside each recording, or only a *Gemini Notes* summary?** This is the single biggest fork: verbatim Docs → most Meet calls skip transcription; Notes-only → those calls route to local whisper (slower, battery). We will confirm against your real Drive in Phase 0, but knowing now sets expectations.

2. **Which sources dominate your actual archive — mostly Fathom, mostly Fireflies, or a real mix?** This decides which two parsers we build first for the Phase-1 MVP so you have something usable this week.

3. **Default generation provider — Claude or Codex — and do you want the optional fully-local (Ollama) fallback for maximum privacy on by default?** You can flip per-call anytime; this just sets the starting point and how aggressively we degrade when a subscription hits its 5-hour limit.

4. **Drive sync now or later?** It is the only feature needing a Google OAuth secret (Keychain). If you'd rather stay 100% offline for V1, we ship drag-drop/paste import first and add Drive in Phase 6 — no architectural change either way.
