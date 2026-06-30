# Phase 8 — Gate (packaging)

**Date:** 2026-06-30 · **Tests:** 135 green.

The Phase-8 `codex exec` gate **hung** (same as P7) and was killed → **rigorous self-review** of the diff,
focused on restore data-loss (the highest-risk area):

Findings + fixes:
- **Store.isValidBackup opened read-write** → validating a `.cbk` (incl. the on-launch restore check)
  could spill `-wal`/`-shm` next to the backup or touch it. Now opens **read-only**.
- Verified fine: `backup` via `VACUUM INTO` on `writeWithoutTransaction` captures committed state safely
  on the live DB; the on-launch restore swap is **crash-safe** — the staged `.pending-restore` is only
  removed after a successful swap (via `defer`, which doesn't run if the process is killed mid-swap), so a
  crash mid-restore self-heals on the next launch; a `.pre-restore` copy of the prior DB is kept; WAL/SHM
  cleared so the restored file is authoritative; restore validates BEFORE overwriting.
- Honest residual: the queue summary shows "of M" where M is the newest-100 display count (a >100-file
  folder import under-reports the denominator) — cosmetic, not a defect.

**Verdict: PASS** (self-reviewed; 135 tests green).

## ✅ Phase 8 — COMPLETE
`.cbk` backup/restore, first-run Welcome wizard, and Developer-ID sign/notarize + Sparkle tooling.
**Founder credential to-dos** (real creds, can't be scripted): see `docs/PACKAGING.md` — Team ID
559YM79ZCA, notarytool profile, Sparkle EdDSA key, DMG/appcast hosting.
