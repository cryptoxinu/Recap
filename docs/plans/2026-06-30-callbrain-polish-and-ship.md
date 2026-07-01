# CallBrain — Final Polish & Ship initiative (2026-06-30)

**Founder directive (verbatim intent):** wire the dead Home cards into real controls, kill EVERY
pinwheel (root-cause, not band-aid), fix transcript speaker/name recognition, give the whole app one
final professional polish + edge-case hardening, run a big Codex audit sweep, install it to
`/Applications` (+ Desktop shortcut, app icon) so it's one-click to open, then create a **private
GitHub repo under `cryptoxinu`** with a production-grade README and commit/push/merge everything.

**Non-negotiables (founder standing rules):** 100% native Swift · fix-don't-defer, no band-aids ·
no handwaving — verify, don't claim · screenshot-verify every UI change · **Codex audits every
phase** · drive everything (founder is a non-coder) · production-grade.

**Branch:** `polish-and-ship-2026-06-30`. **Canonical state:** `docs/STATE.md`.

---

## Progress Ledger

| Phase | Title | Status | Verify |
|-------|-------|--------|--------|
| 0 | Launch beachball — all Keychain I/O off-main | ✅ DONE | cold launch 0.28–0.57s (was 16s); 184 tests; 2× Codex |
| 1 | Pinwheel root-cause sweep (main-thread audit) | ✅ DONE | every Store call off-main; cliclick tab-flip verified; 4-lens audit → 10 findings ALL remediated |
| 2 | Transcript speaker / name recognition rebuild | ✅ DONE | EntityExtractor.clean + SpeakerResolver, off-main wiring; 192 tests (+8) |
| 3 | Home cards → live provider picker + engine status | ☐ | — |
| 4 | Final UI/UX polish + edge-case hardening | ☐ | — |
| 5 | Big Codex audit sweep + remediate | ☐ | — |
| 6 | Install to /Applications + Desktop + icon | ☐ | — |
| 7 | Private GitHub repo (cryptoxinu) + README + push/merge | ☐ | — |

Each phase: **build (`swift build`) + `swift test` + Codex audit (`-s read-only`, high reasoning) +
screenshot-verify (UI) → fix all CRIT/HIGH (and MED where sane) no-band-aid → commit.**

---

## Phase 0 — Launch beachball (✅ DONE, folded into this branch)

Root cause: `AppEnvironment.init` synchronously read the Keychain (Fathom + Drive connectors) on the
main thread; on an unsigned binary a Keychain read is ~6s (ACL evaluation) → ~16s frozen launch.

Fix: connectors cache their `connected`/`hasClient` flags in `UserDefaults` (instant), reconcile the
real Keychain **off-main**, and use a **connection-generation guard** to detect disconnect WITHOUT a
Keychain read — eliminating the per-loop main-thread `store.load()` calls that froze the UI mid-sync.
All connect/disconnect/configure/watermark Keychain I/O moved off-main. Two Codex rounds; 6 findings
(2 HIGH races, 4 MED/LOW) remediated. **Verified:** cold launch 0.28–0.57s, 184 tests green, Ollama
idle on launch (only the tiny embedder loads transiently for new imports, auto-unloads).

---

## Phase 1 — Pinwheel root-cause sweep (the "built well, not band-aid" ask)

**Goal:** find and fix EVERY main-thread-blocking operation, not just the two the founder named.
Phase 0 proved this class of bug exists; Phase 1 sweeps the rest.

**Investigation (running):** two parallel Explore agents map (a) all synchronous main-thread DB/file/
parse/subprocess calls reachable from a view `body`/`.task`/button/computed-prop, and (b) the two named
paths — Summary↔Transcript tab switch and the Ask submit path — before the first async yield.

**Named bugs to fix (root cause):**
1. **Summary↔Transcript tab flip pinwheel** — trace `MeetingDetailView`/`MeetingWorkspaceView` tab
   change. Suspect: snapshot rebuild / store read / transcript re-load / re-parse happening on the main
   actor on every flip. Fix: build once off-main, cache both tab payloads, switch is a pure view swap.
3. **Ask AI pinwheel** ("ask about this") — trace `AskView`→`ChatModel`→`AppEnvironment.askChat`→
   `AskEngine`. Suspect: synchronous retrieval (FTS/vector), embedding of the query, or subprocess
   spawn on the main actor before the first `await` yield. Fix: everything heavy off-main; the UI shows
   a real streaming/“thinking” state, never a frozen main thread.

**Method:** for each confirmed site — move the work into a `Task.detached`/actor and assign results on
`@MainActor`; cache where re-derivation is repeated; replace any compute-in-`body` with precomputed
`@State`. Add a lightweight `MainThreadWatchdog` (debug-only) that logs if the main thread is blocked
>250ms, so regressions are caught, not guessed.

**Exit:** click every primary surface (open call, flip tabs, Ask, scroll the list, switch category,
delete) and confirm **zero** pinwheel; the watchdog logs clean. Screenshot/scripted-verify.

---

## Phase 2 — Transcript speaker / name recognition rebuild

**Goal:** speaker attribution in the Transcript view is accurate and clean ("who is talking" is right).

**Investigation (running):** an Explore agent traces the speaker pipeline: ingest (Fathom line
speakers, Gemini-notes/Fireflies parsers, WhisperKit+FluidAudio diarization), normalization (is there
any `SPEAKER_00`→real-name mapping? NER cross-reference?), storage (utterances/speakers), and display
(TurnGroup grouping, name rendering).

**Likely defects (to confirm + fix):** raw diarization labels (`SPEAKER_00`) shown verbatim; empty
speaker rendered as "Speaker"; no grouping so the name repeats every line; Gemini-notes calls (no
per-line speaker) showing nothing; mono-attribution (everything to one person); names not matched
across the call.

**Fix direction:** (a) a speaker-normalization layer — map diarization labels to stable display names,
fold the known attendee/NER person list onto diarization clusters where confidence is high, fall back
to "Speaker 1/2/3" (never raw `SPEAKER_00` or empty); (b) clean transcript rendering — group
consecutive same-speaker turns under one labeled header with timestamp, consistent initials/avatar.
Add tests against real founder fixtures (Fathom + Gemini + a recorded call).

**Exit:** open a Fathom call, a Gemini-notes call, and a recorded call — speakers are correctly named,
grouped, and readable. Screenshot-verify each.

---

## Phase 3 — Home cards → live provider picker + engine status

Replace the three dead/static Home cards with real, wired controls (keep the visual style):

1. **"Ask AI" card → premium-provider quick picker.** Tap → popover with **Claude CLI** and **Codex
   CLI**; shows the current primary (`ProviderRouter`/`providerPrimary`), one tap flips it (persists to
   `providerKey`), with a live "available?" check (probe `claude`/`codex` on `PATH`, green/red dot).
2. **"Engine" card → engine/model status.** Tap → popover showing: local summarizer model
   (`qwen2.5:3b`), embedder (`nomic-embed-text`), **Ollama running?** (health probe), and the premium
   provider — each with a green/red health dot and the model size. "Local + cloud" becomes truthful and
   inspectable.
3. **"Calls indexed" card → tap navigates to Meetings** (nice-to-have; cheap win).

All probes run **off-main** (Phase-0/1 discipline) and cache, so opening Home never blocks. Better-idea
latitude: surface "X summaries pending" / "Ollama warming" micro-status if cheap.

**Exit:** tap each card; popovers work, provider flip persists + visibly changes, health dots reflect
real state (test by stopping Ollama). Screenshot-verify both popovers in light + dark.

---

## Phase 4 — Final UI/UX polish + edge-case hardening

- Sweep every screen for: stretched cards/bubbles (hug content), inconsistent spacing, off-token
  colors in light/dark, owed/janky animations, raw markdown flashes, dead buttons.
- Edge cases: empty states (no calls / no tasks / no transcript / no summary), error states (Ollama
  down, CLI missing, import failure), very long titles/transcripts, a call with one speaker, a call
  with no speakers, offline.
- Honest loading/empty/error copy everywhere (no silent failures).

**Exit:** drive every screen in light + dark at two window sizes; screenshot-verify; no visual defects.

---

## Phase 5 — Big Codex audit sweep + remediate

Full-app Codex audit (parallel passes by area: app/UI concurrency, Core ingest/store, Ask/retrieval,
connectors) + a `swift-macos-sme` / `native-mac-qa-sme` adversarial pass. Remediate every CRIT/HIGH
no-band-aid, MED where sane; re-audit until clean. Write `docs/audits/2026-06-30-polish-ship-audit.md`.

**Exit:** Codex final = clean; tests green; ledger updated.

---

## Phase 6 — Install to /Applications + Desktop + icon

Build release, assemble the signed-style `.app` (ad-hoc local sign), copy to `/Applications/CallBrain.app`
with the real `AppIcon.icns`, create a `~/Desktop/CallBrain` alias, and verify it launches from both with
the icon showing. (Full Developer-ID notarization remains founder-credential-blocked — `docs/PACKAGING.md`
— but local install needs no notarization.) Document the one-liner in the README.

**Exit:** double-click `/Applications/CallBrain.app` and the Desktop alias → app opens fast with icon.

---

## Phase 7 — Private GitHub repo (cryptoxinu) + README + push/merge

- Create a **private** repo under `cryptoxinu` (e.g. `cryptoxinu/CallBrain`), add as `origin`.
- Write a production-grade `README.md`: what CallBrain is, screenshots, the local-first architecture,
  full setup (install Ollama + `qwen2.5:3b` + `nomic-embed-text`; premium CLI subscriptions claude/
  codex; optional Fathom API key; optional Google Drive OAuth via `docs/GOOGLE-DRIVE-SETUP.md`),
  build/run, packaging (`docs/PACKAGING.md`), and the privacy model.
- Commit the whole initiative, push the branch, open + merge the PR to `main`.

**Exit:** `cryptoxinu/CallBrain` private, `main` has everything, README renders, clone-and-setup works
from the doc alone.

---

## Compaction-proof protocol
- Keep the Progress Ledger above current — flip the status + add the verify result BEFORE moving on.
- The harness TaskList mirrors these phases; reconcile after each phase.
- Each phase ends with a local commit on `polish-and-ship-2026-06-30`; Phase 7 pushes + merges.
