#!/bin/bash
# CallBrain — Developer-ID sign + notarize + DMG (Phase 8 packaging).
#
# Produces a signed, notarized, stapled CallBrain.app + a .dmg for direct download (NOT the App Store —
# per the founder's hard rule). Run on the founder's Mac after filling in the credentials below.
#
# ── FOUNDER MUST PROVIDE (real credentials — cannot be scripted blind) ─────────────────────────────
#   TEAM_ID        Apple Developer Team ID (10 chars), e.g. 559YM79ZCA   ← founder has Team 559YM79ZCA
#   SIGN_ID        "Developer ID Application: <Name> (TEAM_ID)"  (from `security find-identity -v -p codesigning`)
#   NOTARY_PROFILE A notarytool keychain profile created once via:
#                    xcrun notarytool store-credentials "callbrain-notary" \
#                      --apple-id "<apple-id-email>" --team-id "$TEAM_ID" --password "<app-specific-password>"
# ───────────────────────────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${TEAM_ID:-REPLACE_TEAM_ID}"
SIGN_ID="${SIGN_ID:-Developer ID Application: REPLACE_NAME ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-callbrain-notary}"
APP="$ROOT/.build/CallBrain.app"
DMG="$ROOT/.build/CallBrain.dmg"
ENT="$ROOT/tools/CallBrain.entitlements"

echo "▸ release build"
swift build -c release --package-path "$ROOT"

echo "▸ assemble .app bundle"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/CallBrainApp" "$APP/Contents/MacOS/CallBrain"
cp "$ROOT/tools/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/CallBrainApp/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/" 2>/dev/null || true

echo "▸ codesign (Hardened Runtime, leaf-first: any embedded dylibs/frameworks before the app)"
find "$APP/Contents" -type f \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null \
  | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_ID" "{}" || true
codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▸ DMG"
rm -f "$DMG"
hdiutil create -volname "CallBrain" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "▸ notarize + staple (requires the notary profile above)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

echo "✓ done → $DMG  (Gatekeeper: spctl -a -vv \"$APP\")"
