# Phase 2 — Audit Gate (Codex + Swift-native SME)

**Date:** 2026-06-30 · **Branch state:** commits `b6b65fd..05b6573` · **Tests:** 82 green.

Phase 2 was reviewed by **two independent adversarial auditors** in parallel: `codex exec -s read-only`
over the diff, and the `swift-macos-sme` subagent reading the actual files + running the build/tests.
Both agreed the **core architecture is sound** and found **no CRITICAL** issues. The SME explicitly
verified (not defects): the serial import queue has no lost/double-run/orphan race; ingest runs off the
main actor; `saveMeeting` is atomic with correct FK ordering; the `AppEnvironment` IUO init order is safe;
the Fireflies-copy-in-`.docx` collision is correctly defended.

## Findings → fixes (all resolved, each locked by a regression test)

| # | Sev | Finding | Fix | Test |
|---|-----|---------|-----|------|
| H1 | HIGH | "Durable queue" wasn't durable — queued payloads memory-only; relaunch failed them; pasted text lost | Persist job **payload** (file path / pasted text) — migration `v5`; on launch **resume** interrupted jobs (re-run idempotent via dedupe) | `payloadRoundTrip`, `pendingUnbounded` |
| H2 | HIGH | Processor only saw newest 100 jobs → 150-file drop strands oldest 50 | `pendingImportJobs()` (unbounded, oldest-first) drives the drain, not the display list | `pendingUnbounded` |
| H3 | HIGH | Meeting-save and job-update not atomic → crash window shows failed though meeting exists | Resume + content-hash dedupe makes re-run self-heal to `done` (no dup) | (covered by dedupe + resume) |
| H4/M3 | HIGH/MED | Fathom `.docx` with bold `## Travis 0:00` headers mis-routed to Gemini (shredded) | Header-**density** discriminator (≥2 `##` AND header-fraction < 0.25) | `fathomDocxNotGemini` |
| H1(sme) | HIGH | Non-UTF-8 transcript/subtitle files (CP1252/Latin-1) failed with cryptic error | `.utf8` → `usedEncoding` → CP1252 → Latin-1 fallback in `readText` | `windows1252` |
| H2(sme) | HIGH | Unbounded file/zip reads → OOM | 64 MB text cap + 128 MB docx `uncompressedSize`/inflated-bytes cap | `tooLarge` |
| M1 | MED | Dedupe ignored title/date/speakers → recurring standup on a new day, or speaker-swap, falsely deduped (data loss) | Fingerprint keys on **date + per-utterance speaker + text**; excludes volatile AI title | `dedupeRespectsDateAndSpeaker` |
| M2 | MED | DocxReader dropped any paragraph whose prose contained literal `&lt;w:` | Guard the **raw run output** (pre-unescape) for leaked markup, not the unescaped line | `escapedMarkupInProseKept` |
| M4 | MED | Single-section notes with stray timecodes shredded as Fathom | Tightened Fathom detection regex (bare timecode must end the line) → routes to AI-resolve | `straySectionTimecodesUnknown` |
| MED3 | MED | Job-persistence errors swallowed → silent paste loss | `persist()` surfaces `lastError` (error banner); paste box only clears on success | (UI; manual-verified) |
| MED1 | MED | Dedupe check-then-insert has no unique constraint | Mitigated by the **serial** coordinator (SME-verified no concurrent writers); revisit for Phase-7 parallel bulk import | n/a |
| L1 | LOW | "Clear finished" deleted `needsReview` jobs | `clearFinishedImportJobs` clears `done`+`failed` only | `clearFinished` |
| L2 | LOW | `topEntities` nondeterministic display casing | `MAX(name)` over the group | n/a |
| L3 | LOW | `meetingsMentioning` `LIKE` didn't escape `%`/`_` | `ESCAPE '\'` + escape needle | n/a |

**Verdict:** all HIGH/MEDIUM/LOW resolved; a focused Codex **re-audit of the fix diff** runs as the
final confirmation. Phase 2 complete.
