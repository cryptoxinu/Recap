# Recap

**A private, local-first macOS meeting-intelligence app — a personal RAG over months (or years) of
your work calls.** Capture → organize → search → **ask AI** → extract tasks, with strict citations
(meeting · date · speaker · timestamp) and a hard no-hallucination rule: if the answer isn't in your
calls, Recap says so instead of making it up.

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
  a docked **Ask** chat scoped to the call, Find-in-transcript with timestamp jump, and clean
  speaker attribution.
- **Tasks** — every action item across your calls in one place: *For you* vs *Everyone*, collapsible
  per-person groups, name/task search, and AI tidy-up. Later calls that report a task done ("I wrapped
  that up") auto-complete the matching open task.
- **Local-first + fast** — everything lives in a local SQLite database. Embeddings + summaries run
  on-device via Ollama; premium answers use your `claude` / `codex` CLI subscription (flip between them
  from the Home screen).

---

## Requirements

- **macOS on Apple Silicon** (M1 or newer).
- **[Ollama](https://ollama.com)** for on-device embeddings + summaries.
- A **Swift 6 toolchain** (Xcode 16 or the matching command-line tools) to build from source.
- *(Optional, for premium answers)* at least one AI CLI, already logged in to its subscription:
  - **Claude** — the `claude` CLI (looked up at `~/.local/bin/claude`), or
  - **Codex** — the `codex` CLI (looked up at `/opt/homebrew/bin/codex`).

Everyday search and summaries run locally and are free; the premium CLIs only power "Regenerate with AI"
summaries and premium Ask answers.

---

## Build & run

```bash
git clone https://github.com/cryptoxinu/Recap.git
cd Recap

# One command: release build → assemble Recap.app → ad-hoc sign → install to /Applications
# (+ a Desktop shortcut). No Apple Developer account needed for local use.
bash tools/install-local.sh
```

Then open **Recap** from /Applications or Spotlight. On first launch macOS asks once for Keychain +
folder access — click *Allow* and it won't ask again.

Prefer to just compile or run the tests?

```bash
swift build -c release     # compile only
swift test                 # run the test suite
```

For a fully **notarized** build for distribution (needs your Apple Developer Team ID, a `notarytool`
keychain profile, and a Sparkle EdDSA key), use `tools/package.sh`, which produces a signed, stapled
`Recap.app` + a `.dmg`.

### Install the local models (Ollama)

```bash
# Install Ollama from https://ollama.com, then pull the two models Recap uses:
ollama pull qwen2.5:3b          # on-device call summaries (fast, JSON-reliable)
ollama pull nomic-embed-text    # on-device embeddings for search
```

Recap talks to Ollama at `http://127.0.0.1:11434`. It only loads a model when there's work to do and
unloads it when idle, so it won't sit on your RAM or spin your fans. The Home screen's **Engine** card
shows live status (green = ready).

### Optional connectors

- **Fathom** — Settings → *Fathom* → paste your API key (fathom.video → Settings → Integrations → API).
  Recap then pulls every new call automatically (transcript + attendees) and stores it locally.
- **Google Drive** — Settings → *Google Drive*. "Detect Drive folder" watches your local Google-Drive
  "Meet Recordings" folder with zero setup; a one-time Google OAuth client enables cloud sync of Gemini
  notes + recordings.

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
Recap/
├── Sources/CallBrainApp/         # SwiftUI app — views, coordinators, connectors
├── Sources/CallBrainCore/        # engines — Store (GRDB), Ingest, Retrieve, Answer, Providers, Embedding
├── Sources/CallBrainAppCore/     # app-layer state machines (live transcript, local server, native messaging)
├── Sources/CallBrainTranscribe/  # WhisperKit + FluidAudio transcription/diarization
├── Tests/                        # 680+ unit tests + eval harness + fixtures
├── tools/                        # icon + install/packaging (sign/notarize) tooling
├── extension/                    # Chrome extension for live Google-Meet captions + pairing
└── data/                         # YOUR data lives here at runtime (gitignored)
```

> The Swift module names keep the original `CallBrain*` prefix — an internal identifier only. The app
> and product are **Recap** everywhere a user sees them.

---

## Privacy model

Local-first: your calls, transcripts, embeddings, and summaries live in a local SQLite database on your
Mac. On-device models (Ollama) handle embeddings + everyday summaries. Premium answers and "Regenerate"
use your own `claude`/`codex` CLI subscription — Recap scrubs the environment so those run under your
subscription auth, with web/file tools stripped. Web-research mode is opt-in and clearly separated from
your call data. (Not a secrecy tool — local processing is for cost + speed; cloud generation is fine.)

---

## Development

- `swift build` / `swift test` (680+ tests).
- Diagnostics: `CALLBRAIN_WATCHDOG=1` logs any main-thread stall.

## License

[MIT](LICENSE) © 2026 Recap contributors.
