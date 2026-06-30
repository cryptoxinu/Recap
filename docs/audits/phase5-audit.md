# Phase 5 — Codex Gate (provider resilience)

**Date:** 2026-06-30 · **Diff:** `f4fded2..46a3785` · **Tests:** 122 green + live codex verified.

Codex `exec -s read-only` over the Phase-5 diff (LLMProvider, CodexRunner, ProviderRouter, Settings flip,
badge). **1 CRITICAL + 1 HIGH + 2 MED + 1 LOW — all fixed + tested.**

| # | Sev | Finding | Fix | Test |
|---|-----|---------|-----|------|
| 1 | CRITICAL | codex exec only `-s read-only` — agent/tool loop + session logs could leak prompt-injected file reads / persist private RAG prompts | + `--ephemeral` (no log persistence) + `--ignore-user-config` (no config redirect); read-only also blocks network egress; output to private last-message file | `hardenedArgs` |
| 2 | HIGH | env scrub didn't force subscription auth (config could redirect to API-key provider) | `--ignore-user-config` (auth stays on CODEX_HOME subscription) + scrub OPENAI_ORGANIZATION/PROJECT | `hardenedArgs` |
| 3 | MED | `model` reported but never passed → badge/logs lie | report `codex`/configured model, pass `-m`, ignore the Claude-centric protocol param | `hardenedArgs` |
| 4 | MED | timeout not guaranteed (blocking stdin write + terminate-then-wait-forever) | stdin write off-thread; watchdog escalates SIGTERM→SIGKILL | (Subprocess) |
| 5 | LOW | Settings flip via unstructured Task → next Ask could use the old primary | router primary lock-guarded → synchronous, visible immediately | `flip` |

**Note on residual injection posture (honest):** codex `exec` doesn't expose a true no-tools mode, but
under `-s read-only` there is **no network egress** and **no writes**, output goes only to the founder's
own app, and `--ephemeral` means no persisted log — so the practical blast radius of a prompt-injected
read is bounded (it would appear only in the founder's own answer, not exfiltrated). Acceptable given the
constraints; revisit if codex adds a tool-disable flag.

**Verdict: PASS.** Codex couldn't run the build (read-only sandbox); 122 tests green + live codex verified locally.

## ✅ Phase 5 — COMPLETE
Flip Claude⇄Codex (Settings, persisted) with transparent fallback on rate-limit/unavailability; provider
badge in Ask; CodexRunner live-verified. Deferred-not-creep: token-streaming, defer-and-resume bulk queue,
per-provider concurrency lanes.
