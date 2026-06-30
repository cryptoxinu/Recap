# Phase 4 — Codex Gate

**Date:** 2026-06-30 · **Diff:** `ab685ec..30d6a45` · **Tests:** 104 green + live eval 3/3.

Codex `exec -s read-only` over the Phase-4 diff (date-gating, Tasks, eval harness, modes).
**No CRITICAL.** 3 HIGH + 3 MED — all fixed, each locked by a regression test.

| # | Sev | Finding | Fix | Test |
|---|-----|---------|-----|------|
| 1 | HIGH | `past week`/`past month` (no number) → `dateRange == nil` → date-gate silently disabled, whole-corpus search | QueryPlanner treats `past week/month` as last week/month | `pastSynonyms` |
| 2 | HIGH | `INSERT OR REPLACE INTO meetings` deletes the parent → `ON DELETE CASCADE` wipes tasks (user-toggled `done`) on re-save | UPSERT in place (`ON CONFLICT DO UPDATE`); derived data explicitly replaced; tasks `INSERT OR IGNORE` | `reSavePreservesTaskStatus` |
| 3 | HIGH | EvalHarness didn't catch fabricated citation **tags** (`[S99]` in prose, not attached) | `.answers` now flags dangling tags (referenced − attached) | live eval |
| 4 | MED | `• [Ghazal] …` lost attribution (ownerLine ran before bullet strip) | strip leading bullet glyph before owner detection | `bulletOwnerAndNegatives` |
| 5 | MED | "No action items identified." became a false open task | `isNegative()` placeholder filter | `bulletOwnerAndNegatives` |
| 6 | MED | AIImporter stored `prefix(10)` of an unparsed model date (`06/29/2026`) → date-gating excludes it | `normalizeDate()` → canonical YYYY-MM-DD or nil | `NormalizeDateTests` |

**Verdict: PASS** (all findings fixed + tested; live anti-hallucination eval 3/3).

### Phase 4 — deferred (noted, not scope-creep)
- Transcript LLM action-item extraction (Gemini deterministic covers the founder's real data; transcript
  tasks arrive with the Phase-3 transcription path / a later LLM pass).
- `explanatory_score` rerank for technical mode (needs a scoring pass; low near-term value).
- Company-6-slot / pre+post-call briefing answer templates (fold into Phase 4.5 workspace or later).
The anti-hallucination core (hard date-gating, citation enforcement, refusal, eval) + Tasks + the 5
ask modes are built, tested, and live-verified.
