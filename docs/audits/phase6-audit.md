# Phase 6 — Codex Gate (native polish)

**Date:** 2026-06-30 · **Diff:** `997ab83..f254fc5` · **Tests:** 130 green.

Codex over the Phase-6 diff (Duplicate Review, notifications, menu-bar, background jobs). **No CRITICAL.**
1 HIGH + 2 MED + 2 LOW — all fixed + tested.

| # | Sev | Finding | Fix | Test |
|---|-----|---------|-----|------|
| 1 | HIGH | deleteMeeting left meeting chats + citation excerpts → "transcript removed" promise false | cascade meeting conversations + scrub citations referencing it from other messages | `deleteMeetingScrubs` |
| 2 | MED | dedup `max(people,title)`@0.5 → one shared person / "Untitled" = false dup | require ≥2 shared people + high Jaccard, OR cross-source same-call, OR strong non-generic title | `singleSharedPersonNotFlagged`, `genericTitlesNotFlagged` |
| 3 | MED | reminders not refreshed on task complete/import/delete → stale count fires | `refreshReminders()` at all three sites | (wiring) |
| 4 | LOW | toggle/auth desync | re-check desired state after the async authorization | (guard) |
| 5 | LOW | dismissed-dup key order-dependent → re-appears as B\|A | order-independent (sorted) suggestion id | `orderIndependentID` |

**Verdict: PASS.** Codex couldn't run the build (read-only sandbox); 130 tests green locally.

## ✅ Phase 6 — COMPLETE
Duplicate Review (strong-signal near-dup detection + safe cascade delete), daily action-item reminders,
menu-bar status, and background-job survival (beginActivity + window-close keeps the app in the menu bar).
**DEFERRED — needs founder credentials:** Google Drive auto-import sync (requires the founder's Google
OAuth client + consent); not built. Everything else in the Phase-6 deliverable list is done.
