# Deferred-work sweep + Google Drive sync (2026-06-30)

Cleared the deferred backlog and built the headline deferred item (Google Drive cloud sync), then
multi-lens audited everything. Commits `e9bef40` → `a634bdf` on `main`. 150 tests green.

## Shipped
- **Delete/archive call** (`MeetingsView`): swipe + right-click → confirmation → `Store.deleteMeeting`
  cascade + pop the open workspace + refresh reminders. Closes the "no delete UI" gap.
- **In-meeting AskFred survival** (`AppEnvironment.meetingChat`): per-call chats are env-owned (cached,
  capped at 24, idle-evicted) so an in-flight answer survives leaving/returning the call.
- **Web-source URL polish** (`MarkdownAnswerView`): bare + markdown-link URLs keep balanced parens
  (Wikipedia-style), trailing punctuation trimmed.
- **Google Drive cloud sync** — the headline:
  - `Sources/CallBrainCore/Drive/`: `GoogleOAuth` (PKCE S256, loopback redirect, state CSRF, token
    bodies), `DriveAPI` (list/folder-search/folder-list/download/export builders, q-escaping,
    fetch-plan), `GoogleDriveClient` (actor: streaming download-to-file, 401-refresh-retry, non-Google
    host guard, pagination guard, epoch-guarded token writes), `KeychainStore` (DeviceOnly, checked
    update-else-add, returns success).
  - `Sources/CallBrainApp/GoogleDriveConnect.swift`: 127.0.0.1 loopback OAuth server (one-shot, leak-safe
    continuations, 300s timeout via `withTaskCancellationHandler`), connect/disconnect/sync coordinator
    (per-folder only — never whole Drive — unique+atomic cache files, dedupe, imported/failed reporting,
    periodic + on-launch auto-sync, folder picker), and `GoogleDriveDetect` zero-OAuth folder auto-detect.
  - Settings UI (Auto-import "Detect Drive folder" + "Google Drive (cloud sync)" section) +
    `docs/GOOGLE-DRIVE-SETUP.md`. 11 Drive unit tests incl. a mocked token-refresh lifecycle.
  - **Cannot be runtime-tested without the founder's Google OAuth client** — verified by unit tests +
    audit instead. The non-coder path (Detect Drive folder + folder-watch) needs zero OAuth.

## Audit (the founder's "Codex audits every phase, in parallel" + ultracode adversarial verify)
Five rounds: 2 parallel Codex audits → a 4-lens workflow (`apple-platform-security-sme`,
`swift-macos-sme`, `security-reviewer`, completeness critic) with per-finding adversarial verify (23→11
confirmed) → Codex re-audit → Codex re-audit → Codex final = **CLEAN**.

Real findings fixed (every confirmed one):
- **HIGH** — token exfil via arbitrary-URL download (host guard); multi-GB media buffered in RAM
  (streaming download-to-file); nil-folder = sync entire Drive (hard per-folder guard + picker);
  loopback `start()` continuation leak on early cancel; Keychain not `ThisDeviceOnly`; **OAuth-timeout
  hang** (the first fix was itself broken — `withThrowingTaskGroup` awaited a cancellation-unaware child
  forever → `withTaskCancellationHandler`); **connect/disconnect-during-token-exchange resurrection**
  (epoch guard before save).
- **MED** — same-name cache clobber (file-id + atomic replace); Keychain delete-then-add data loss
  (checked update-else-add returning success); disconnect/refresh actor↔main race (epoch); disconnect
  left stale folder/dedupe; no periodic/on-launch sync; q-injection backslash escaping; pagination loop;
  false "connected" on failed Keychain write (readback + Bool).
- **LOW** — RNG-failure PKCE fallback; symlink rejection in folder-detect; meetingChats cap; 401 tmp
  cleanup; markdown-link balanced parens; findFolder stable ordering.

## Still genuinely blocked (founder credentials)
- Google Drive **OAuth client creation** (a 5-min Google Cloud step; doc'd in GOOGLE-DRIVE-SETUP.md).
- Packaging: Apple notarytool profile, Sparkle EdDSA key, DMG/appcast hosting (docs/PACKAGING.md).
