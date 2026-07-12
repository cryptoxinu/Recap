#!/bin/bash
# Recap — local install to /Applications + a Desktop shortcut (Phase 6).
#
# Builds a release Recap.app, ad-hoc signs it, copies it to /Applications, and drops a Desktop
# shortcut so it's one double-click to open. This is the DEV/local path — it is NOT notarized, so on
# first launch macOS will ask once for Keychain + folder access (click "Always Allow" / "Allow" once and
# it sticks, because the /Applications copy isn't re-signed after that). For a fully notarized,
# prompt-free build for distribution, use tools/package.sh with your Developer-ID credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Recap.app"
DESKTOP_LINK="$HOME/Desktop/Recap"

echo "▸ release build"
swift build -c release --package-path "$ROOT"

echo "▸ assemble app bundle → $APP"
# Quit any running copy so we can overwrite it.
pkill -f "Recap.app/Contents/MacOS/Recap" 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/CallBrainApp" "$APP/Contents/MacOS/Recap"
cp "$ROOT/.build/release/cbtranscribe" "$APP/Contents/MacOS/cbtranscribe"
cp "$ROOT/.build/release/cbpairhost" "$APP/Contents/MacOS/cbpairhost"   # Chrome native-messaging pairing host
cp "$ROOT/tools/Info.plist" "$APP/Contents/Info.plist"
# Stamp the build so "which code am I running?" is answerable in Finder ⌘I / About:
# version = date + git short SHA of the code this bundle was built from.
STAMP="$(date +%Y.%m.%d)-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $STAMP" "$APP/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $STAMP" "$APP/Contents/Info.plist" || true
echo "  build stamp: $STAMP"
cp "$ROOT/tools/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/CallBrainApp/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/" 2>/dev/null || true
# SPM resource bundles (e.g. the app-icon PNG) must travel inside the .app to be self-contained.
find "$ROOT/.build/release" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

echo "▸ codesign (Developer ID when available — stable TCC identity; ad-hoc fallback)"
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
codesign --force --deep --options runtime --entitlements "$ROOT/tools/Recap.entitlements" --sign "${SIGN_ID:--}" "$APP"
codesign --verify --strict "$APP" && echo "  signature OK"

echo "▸ Desktop shortcut → $DESKTOP_LINK"
rm -f "$DESKTOP_LINK"
ln -s "$APP" "$DESKTOP_LINK"

# Refresh Launch Services so the icon + name show immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true

echo "✓ Installed. Open it from /Applications, Spotlight (\"Recap\"), or the Desktop shortcut."
echo "  First launch will ask once for Keychain + folder access — click Allow and it won't ask again."
