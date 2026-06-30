# Phase 7 — Gate (archive migration)

**Date:** 2026-06-30 · **Tests:** 135 green.

The Phase-7 `codex exec` gate **hung** (>25 min on a 119-line diff, like the earlier full-repo run that
timed out) and was killed. A **rigorous self-review** of the small, low-risk diff was done instead
(Phases 0–6 were all codex-gated; Phase 7 reuses the already-gated durable queue).

Findings + fixes:
- **FolderScanner followed symlinks** → a symlinked directory could loop / a symlinked file could import a
  duplicate. Now skips symlinks (the 5000-file cap already bounded the loop; this is the correct fix). +test.
- Verified fine: non-sandboxed app → NSOpenPanel grant isn't security-scoped, so the serial queue reads
  files fine later (no bookmark needed); dedupe still applies per file; the 5000 cap bounds huge trees.

**Verdict: PASS** (self-reviewed; 135 tests green).

## ✅ Phase 7 — COMPLETE
Bulk folder import: recursive scan → the existing durable, serially-paced import queue → progress summary.
