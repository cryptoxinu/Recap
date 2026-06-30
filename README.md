# CallBrain

> Private, local-first **macOS** meeting-intelligence app. Your personal meeting memory:
> capture → organize → search → ask AI → extract tasks across months of calls —
> with strict citations (meeting · date · speaker · timestamp) so nothing hallucinates.
> Fireflies-grade catalogue search, but **yours, native, and cited.**

**Status:** architecture locked, building in phases. See **`docs/ARCHITECTURE.md`** (source of truth)
and **`docs/PHASE-PLAN.md`** (build order + Codex audit gate per phase).

---

## What it is

A **100% native SwiftUI app** (macOS 26, Swift 6) — no Python, no web view, no bundled runtime,
so it launches instantly and stays buttery. It ingests your scattered call material
(Fathom / Fireflies transcripts, Cluely notes, Google Meet recordings), **auto-detects** each
source, **transcribes only what needs it**, indexes everything into a hybrid **keyword + semantic**
search engine, and answers questions with **citations** you can tap to jump to the exact line.

Two deliberate decisions shape it:

1. **Answers run on your CLI subscriptions, not paid API keys.** An `LLMRunner` actor drives the
   **Claude Code CLI** (`claude -p`) and **Codex CLI** (`codex exec`); you flip between them at will,
   with automatic fallback when one hits its rate limit. Embeddings run **fully local** (free, instant).
2. **Ingestion is transcript-first.** Fathom / Fireflies / Cluely already have transcripts → they're
   parsed and indexed (never re-transcribed). Only raw Meet videos with no transcript get on-device
   **WhisperKit** + **FluidAudio** (to save transcription credits), with a one-click cloud upgrade per file.

Not privacy-first — cloud LLM generation is expected and fine; local processing is for **cost + speed**, not secrecy.

## Stack (decided — see `docs/ARCHITECTURE.md §3`)

SwiftUI + Swift 6 actors · **SQLite via GRDB** (source of truth) with **FTS5** (keyword) + **sqlite-vec**
(vectors) in one custom build · **RRF** hybrid fusion with selectivity-routed exact filtering ·
**nomic-embed-text** embeddings on the Neural Engine · **WhisperKit** + **FluidAudio** transcription/diarization ·
**`claude`/`codex`** CLI generation · Developer-ID signed + notarized, **Sparkle** auto-update, **direct-download only**.

## Repo layout

```
CallBrain/
├── Sources/      # Swift: app (SwiftUI), Core engines (actors), DB (GRDB), Ingest, Retrieve, Answer, Providers
├── Tests/        # unit + eval harness + fixtures
├── tools/        # dev/model-prep ONLY (Python ok here, never shipped)
├── scripts/      # sign / notarize / appcast / dev-run
├── docs/         # ARCHITECTURE.md, PHASE-PLAN.md, research/
├── sample_data/  # tiny fixtures
└── data/         # YOUR data (gitignored): raw/ processed/ database/ models/ exports/
```

## Prerequisites (this Mac)

- macOS 26 / Apple Silicon, Xcode (Swift 6) — ✅ present
- `claude` & `codex` CLIs, logged in — ✅ present (answer backends; no API keys)
- `ollama` — ✅ present (embedding fallback)
- `ffmpeg` — optional; AVFoundation handles most decode natively

## License

Private / personal.
