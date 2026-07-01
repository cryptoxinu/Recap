# CallBrain — Final Polish & Ship audit record (2026-06-30)

Audit trail for the `polish-and-ship-2026-06-30` initiative (Phases 0–7). Every phase was
workflow/Codex-audited and findings remediated with no band-aids. This doc records the Phase-5 ship-gate
sweep and the residual items.

## Audits run this initiative
- **P0 beachball** — 2 Codex rounds; 6 findings (2 HIGH races) fixed.
- **P1 pinwheels** — 4-lens adversarial workflow (14 raw → 10 confirmed) + Codex re-audit (5 findings,
  incl. a HIGH `ensureConversation` reentrancy race the off-main change introduced) — all fixed.
- **P4 polish** — review workflow (60 raw → 34 confirmed) + Codex audit (8 findings incl. 2 HIGH retry
  bugs + a DateFormatter data-race) — all fixed.
- **P5 ship-gate** — 3-lens workflow (integration + security + Core correctness), 9 raw → 6 confirmed.

## Phase-5 ship-gate findings — ALL remediated

| Sev | Area | Finding | Fix |
|-----|------|---------|-----|
| MED | security | `Subprocess.run` env "scrub" was a denylist over the full inherited env — secrets (`GITHUB_TOKEN`, `AWS_*`, `ANTHROPIC_BASE_URL`) passed to the child CLI; "scrubbed" wording overstated it | Added `Subprocess.isSecretEnvKey` — pattern-strips `*_API_KEY`/`*_TOKEN`/`*_SECRET`/`*_BASE_URL`/`AWS_*`/`GOOGLE_APPLICATION_CREDENTIALS` on top of the named list (defense-in-depth without breaking CLI subscription auth). Test added. |
| MED | correctness | `SpeakerResolver.isGeneric` treated an already-clean `Speaker 1` as generic → renumbering could SWAP speakers appearing out of order | Only raw tokens (`SPEAKER_00`/`spk1`/`S2`/empty/`—`/bare `Speaker`) are generic; `Speaker N` (space+number) passes through. Test updated + swap case added. |
| MED | correctness | `Store.keywordSearch` / `vectors` bound one param per candidate chunk id → a large date-range exceeds SQLite's bound-parameter limit and fails | Switched both `IN (…)` clauses to `IN (SELECT value FROM json_each(?))` — one JSON-array param, no limit (`Store.jsonArray`). |
| LOW | integration | Fathom/Drive `connect()` completions weren't generation-guarded → a Disconnect racing the validation/OAuth could re-enable | Capture `connGen`/`syncGeneration` before the validating await; bail if it changed. |
| LOW | correctness | `EntityExtractor.mergePersonVariants` folded via a non-stable sort of equal-count names (non-transitive `areSamePerson`) → order-dependent result | Deterministic secondary sort key (name). |

## Residual (documented, not a defect to fix now)
- **[MED, accepted] Injection-defense is capability-first + verified-by-answer.** The grounded/research CLI
  args (`--tools "" --safe-mode --strict-mcp-config` on Claude; `-s read-only --ignore-user-config
  --ephemeral` on Codex) mean injected transcript text has no tool to invoke — but the current tests assert
  the ARGV is built correctly, not that a tool-call was actually DENIED at runtime, and the flag semantics
  could drift across CLI versions. The env-scrub above narrows the blast radius. A full runtime capability
  probe (spawn each CLI with a tool-attempt payload, assert no side-effect) is a deliberate FOLLOW-UP —
  it's omitted here rather than shipped as a flaky CI test. The existing CI grep-gate banning
  `--dangerously-*` remains. Tracked for a future hardening pass.

## Verification
`swift build` clean · `swift test` **193 tests** green (+ `Subprocess.isSecretEnvKey` test, updated
`SpeakerResolver` tests).
