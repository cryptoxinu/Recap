# CallBrain

**A private, local-first macOS meeting-intelligence app — a personal RAG over months (or years) of
your work calls.** Capture → organize → search → **ask AI** → extract tasks, with strict citations
(meeting · date · speaker · timestamp) and a hard no-hallucination rule: if the answer isn't in your
calls, CallBrain says so instead of making it up.

Think Fireflies / Fathom / Otter — but native, fast, and running on **your** machine against **your**
data, using **your** AI CLI subscriptions instead of a metered API.

> 100% native Swift (SwiftUI + Swift 6 strict concurrency). No Python in the shipped app. Apple-Silicon only.

---

## What it does

- **Capture** — import transcripts (Fireflies / Fathom / Google-Meet "Notes by Gemini" `.docx` / SRT /
  VTT / plain text), **paste any raw dump** (an LLM structures it), transcribe local **audio/video**
  on-device (WhisperKit + FluidAudio diarization), bulk-import a whole folder, auto-import a watched
  folder, or pull your **Fathom** calls automatically via the Fathom API.
- **Organize** — a durable import queue (survives relaunch), content-hash dedupe + a Duplicate-Review
  screen, on-device NER (people / orgs / places), auto-extracted **action items**, and
  auto-classification into ventures with a filter + category tag.
- **Ask** — hybrid retrieval (SQLite **FTS5** keyword ⊕ local vector cosine ⊕ **RRF** fusion) with
  strict inline **[S#] citations** that jump to the exact moment in the call, an agentic reasoning
  timeline, multi-turn follow-ups, and an optional **web-research** mode. It refuses rather than
  hallucinates.
- **Workspace** — a Fireflies-grade call view: **Summary** (on-device model) and **Transcript** tabs,
  a docked **AskFred** chat scoped to the call, Find-in-transcript with timestamp jump, and clean
  speaker attribution.
- **Local-first + fast** — everything lives in a local SQLite database. Embeddings + summaries run
  on-device via Ollama; premium answers use your `claude` / `codex` CLI subscription (flip between them
  from the Home screen).

---

## Requirements

- **macOS on Apple Silicon** (M1 or newer).
- **[Ollama](https://ollama.com)** for on-device embeddings + summaries.
- At least one premium AI CLI, already logged in to its subscription:
  - **Claude** — the `claude` CLI (looked up at `~/.local/bin/claude`), or
  - **Codex** — the `codex` CLI (looked up at `/opt/homebrew/bin/codex`).
- **Xcode command-line tools** / a Swift 6 toolchain to build from source.

---

## Setup

### 1. Install the local models (Ollama)

```bash
# Install Ollama from https://ollama.com, then pull the two models CallBrain uses:
ollama pull qwen2.5:3b          # on-device call summaries (fast, cool, JSON-reliable)
ollama pull nomic-embed-text    # on-device embeddings for search
```

CallBrain talks to Ollama at `http://127.0.0.1:11434`. It only loads a model when there's work to do
and unloads it when idle, so it won't sit on your RAM or spin your fans.

### 2. Have a premium CLI ready

Install and sign in to **either** CLI (switch anytime from the Home screen's *Premium AI* card):

- Claude Code CLI → `claude` (CallBrain looks in `~/.local/bin/claude`).
- Codex CLI → `codex` (CallBrain looks in `/opt/homebrew/bin/codex`).

These power the "Regenerate with AI" summaries and premium Ask answers. Everyday search + summaries run
locally and are free.

### 3. Build & run

```bash
git clone https://github.com/cryptoxinu/CallBrain.git
cd CallBrain
swift build -c release
tools/package.sh          # assemble (and, with your creds, sign + notarize) CallBrain.app
open .build/CallBrain.app
```

The Home screen's **Engine** card shows live status — whether Ollama is running and each model is
installed — so you can confirm setup at a glance (green = ready).

### 4. (Optional) Connect Fathom — automatic call import

Settings → *Fathom* → paste your API key (fathom.video → Settings → Integrations → API). CallBrain then
pulls every new call automatically (transcript + attendees) — on app foreground and on a background
timer — and stores them locally so you never lose a call.

### 5. (Optional) Connect Google Drive

Settings → *Google Drive*. Two paths:
- **Zero-setup** — "Detect Drive folder" watches your local Google-Drive "Meet Recordings" folder.
- **Cloud sync** — a one-time Google OAuth client (5 minutes; see `docs/GOOGLE-DRIVE-SETUP.md`) pulls
  Gemini notes + recordings, including files shared with you.

---

## Architecture

| Layer | Choice |
|-------|--------|
| UI | SwiftUI + Swift 6 strict concurrency, `NavigationSplitView`, `@Observable` |
| Storage | GRDB / SQLite (source of truth) + FTS5 for keyword search |
| Vector | embeddings-as-BLOB + in-Swift brute-force cosine (graduates to sqlite-vec at scale) |
| Retrieval | FTS5 ⊕ vector ⊕ **Reciprocal Rank Fusion**, selectivity-routed hard filters, strict citations |
| Embeddings | `nomic-embed-text` via Ollama (local) |
| Summaries | `qwen2.5:3b` via Ollama (local); `claude`/`codex` CLI for premium regenerate |
| Transcription | WhisperKit (ASR) + FluidAudio (diarization), on-device |
| Generation | `claude` / `codex` CLI subscriptions — env-scrubbed, tool-stripped, injection-inert |
| Distribution | Developer-ID sign + notarize + Sparkle, **direct-download** (not the App Store) |

All Store I/O runs off the main thread (the UI never blocks on a query), and the connectors cache their
state so launch is instant.

### Repo layout

```
CallBrain/
├── Sources/CallBrainApp/   # SwiftUI app — views, coordinators, connectors
├── Sources/CallBrainCore/  # engines — Store (GRDB), Ingest, Retrieve, Answer, Providers, Embedding
├── Sources/CallBrainTranscribe/  # WhisperKit + FluidAudio transcription/diarization
├── Tests/                  # unit + eval harness + fixtures
├── tools/                  # icon + packaging (sign/notarize) tooling
├── docs/                   # ARCHITECTURE.md, STATE.md, PACKAGING.md, plans/, audits/
└── data/                   # YOUR data (gitignored)
```

---

## Privacy model

Local-first: your calls, transcripts, embeddings, and summaries live in a local SQLite database on your
Mac. On-device models (Ollama) handle embeddings + everyday summaries. Premium answers and "Regenerate"
use your own `claude`/`codex` CLI subscription — CallBrain scrubs the environment so those run under your
subscription auth, with web/file tools stripped. Web-research mode is opt-in and clearly separated from
your call data. (Not a secrecy tool — local processing is for cost + speed; cloud generation is fine.)

---

## Packaging (maintainers)

`docs/PACKAGING.md` covers the Developer-ID sign + notarize + Sparkle flow (`tools/package.sh`). A
release needs your Apple Developer Team ID, a `notarytool` keychain profile, and a Sparkle EdDSA key.

## Development

- `swift build` / `swift test` (192 tests).
- Architecture: `docs/ARCHITECTURE.md`. Build history + audits: `docs/STATE.md`, `docs/audits/`, `docs/plans/`.
- Diagnostics: `CALLBRAIN_SKIP_RECONCILE=1` (UI-test build without connector prompts),
  `CALLBRAIN_WATCHDOG=1` (log any main-thread stall).

## License

Private / personal.
