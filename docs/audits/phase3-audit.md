# Phase 3 — Codex Gate (on-device transcription)

**Date:** 2026-06-30 · **Diff:** `83957da..0f91c04` · **Tests:** 112 green + live end-to-end verified.

Codex `exec -s read-only` over the Phase-3 diff (AudioDecoder, Transcriber/Diarizer protocols +
SpeakerAligner, TranscriptionPipeline, WhisperKit/FluidAudio adapters, Transcribe UI).
**No CRITICAL.** 2 HIGH + 5 MED + 1 LOW — all fixed + tested.

| # | Sev | Finding | Fix | Test |
|---|-----|---------|-----|------|
| 1 | HIGH | Unbounded `[Float]` materialization → 2h recording ~460 MB, OOM risk | reject > 6 h + `reserveCapacity` from duration | (guard) |
| 2 | HIGH | Diarization failure silently swallowed → false single-speaker | `Output.diarizationRequested/Succeeded`; coordinator shows "speakers not identified" | `pipelineStub` |
| 3 | MED | `@unchecked Sendable` adapters unsafe on concurrent reuse | lock-guarded one-shot init `Task` (+ `Box`); cached one instance in AppEnvironment | (compile) |
| 4 | MED | Diarized speakers marked `isInferredSpeaker: false` | always `true` (model guesses, not explicit labels) | `alignment` |
| 5 | MED | Local timestamps `.exact` vs CTM `.derived` | `.derived` | `alignment` |
| 6 | MED | Gap fallback attributes to a speaker minutes away | `maxGapSeconds = 3` → fall back beyond it | `maxGapFallback` |
| 7 | MED | No guard for zero aligned utterances → empty meeting persisted | throw `emptyAudio` if no utterances | (guard) |
| 8 | MED | `modelUnavailable` cause not surfaced | `friendly()` handles AudioDecode/Transcribe errors | (mapping) |
| 9 | LOW | Late progress task overwrites final message | `showProgress` guards `state == .running` | (guard) |

Codex couldn't run the build (read-only sandbox); build + 112 tests are green locally, and the pipeline
was **live-verified end-to-end** on real Downloads videos (M4 Max): a speech video → FluidAudio 2 speakers
+ WhisperKit transcript + alignment + ingest; a music promo → "[MUSIC PLAYING]".

**Verdict: PASS.**

## ✅ Phase 3 — COMPLETE
Raw recordings (`.mp4`/`.mov`/`.m4a`/…) → AVFoundation decode → WhisperKit transcription → FluidAudio
diarization → midpoint alignment → CTM utterances → ingested as a `gmeet_local` meeting (chunks /
embeddings / entities / Tasks / AskFred like any source). Drop-to-transcribe wired into Import with live
progress. Models download + compile on first use, then load once (cached).
Deferred-not-creep: cloud-transcription upgrade hook (Deepgram/AssemblyAI), `transcript_versions` v0/v1,
model signature-verify, Apple SpeechTranscriber live option.
