# CallBrain — Hard Session Rules (founder-set, 2026-06-30)

These are non-negotiable for the autonomous build loop. Re-read every iteration.

1. **Do NOT stop.** Drive `docs/PHASE-PLAN.md` end-to-end via the `/loop` (dynamic self-pace). Each
   iteration finishes a concrete build step then `ScheduleWakeup`s the next. Only stop when the entire
   plan is built + Codex-audited.
2. **100% native Swift.** No Python in the shipped app. SwiftUI + Swift 6 strict concurrency.
3. **Production-grade UI/UX.** Looks like Fireflies (docs/DESIGN-fireflies-reference.md): calm, clean,
   **animated, buttery-smooth**, fully functional. No template-y or broken screens.
4. **Verify EVERY UI change by screenshot.** Build → bundle → launch → capture the window by id
   (`scratchpad/shot.sh`) → actually LOOK at it. Never claim a screen works without seeing it. (This
   rule exists because a blank app shipped once — never again.)
5. **`swift test` stays green** every iteration.
6. **Codex audits every completed phase** (`codex exec -s read-only`), per the founder's standing rule.
   Fix HIGH/CRITICAL before moving on. Record the verdict in the ledger.
7. **Commit each chunk** with a clear message; keep the PHASE-PLAN ledger current (compaction-proof).
8. **Follow the plan; no scope creep.** Finish a phase before widening it.
9. **Fix, don't defer.** No bandaid fixes (founder standing rule).
