# CallBrain — Packaging & Distribution (Phase 8)

**Direct-download only — never the App Store** (founder hard rule). Signed with Developer-ID, notarized,
auto-updates via Sparkle.

## What's code-side (done)
- `.app` assembly + `tools/package.sh` (release build → bundle → codesign → DMG → notarize → staple).
- `tools/Info.plist` (bundle id `com.callbrain.app` — enables notifications + Sparkle), `tools/CallBrain.entitlements`.
- `tools/appcast.xml` Sparkle feed template.
- `.cbk` **backup/restore** (Store `VACUUM INTO` + validate; Settings → Back up / Restore; restore swaps
  in on next launch with a `.pre-restore` safety copy).
- First-run **Welcome** wizard.

## Founder actions (need real credentials — cannot be scripted blind)
1. **Apple Developer Team ID** — `559YM79ZCA` (already have; Developer-ID signing live per memory). Set
   `TEAM_ID` + `SIGN_ID` in `tools/package.sh` (or export them).
2. **notarytool profile** — once:
   `xcrun notarytool store-credentials "callbrain-notary" --apple-id <email> --team-id 559YM79ZCA --password <app-specific-pw>`
3. **Sparkle EdDSA key** — `./bin/generate_keys` (from the Sparkle release); put the **public** key in
   `Info.plist` `SUPublicEDKey`, keep the private key in the login keychain. Add the Sparkle SPM dep +
   a `SPUStandardUpdaterController` when wiring auto-update UI (deferred until a release host exists).
4. **Hosting** — a static host for `CallBrain-<v>.dmg` + `appcast.xml`; set `SUFeedURL` (`Info.plist`) +
   `REPLACE_HOST` (`appcast.xml`). Sign each DMG: `./bin/sign_update CallBrain-<v>.dmg` → paste the
   `sparkle:edSignature` + byte length into `appcast.xml`.
5. Run `TEAM_ID=559YM79ZCA SIGN_ID="Developer ID Application: … (559YM79ZCA)" ./tools/package.sh`,
   verify `spctl -a -vv .build/CallBrain.app`, publish the DMG + appcast.

## Notes
- Whisper/FluidAudio CoreML models download on first use (not bundled) → the `.app` stays tens of MB.
- Entitlements are minimal: JIT + library-validation-off (CoreML/MLX), user-selected-files (import),
  network-client (claude/codex CLI + Ollama). No sandbox (it shells out to the user's CLIs by design).
