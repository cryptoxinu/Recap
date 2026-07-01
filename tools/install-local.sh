#!/bin/bash
# CallBrain — local install to /Applications + a Desktop shortcut (Phase 6).
#
# Builds a release CallBrain.app, ad-hoc signs it, copies it to /Applications, and drops a Desktop
# shortcut so it's one double-click to open. This is the DEV/local path — it is NOT notarized, so on
# first launch macOS will ask once for Keychain + folder access (click "Always Allow" / "Allow" once and
# it sticks, because the /Applications copy isn't re-signed after that). For a fully notarized,
# prompt-free build for distribution, use tools/package.sh with your Developer-ID credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/CallBrain.app"
DESKTOP_LINK="$HOME/Desktop/CallBrain"

echo "▸ release build"
swift build -c release --package-path "$ROOT"

echo "▸ assemble app bundle → $APP"
# Quit any running copy so we can overwrite it.
pkill -f "CallBrain.app/Contents/MacOS/CallBrain" 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/CallBrainApp" "$APP/Contents/MacOS/CallBrain"
cp "$ROOT/tools/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/tools/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/CallBrainApp/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/" 2>/dev/null || true
# SPM resource bundles (e.g. the app-icon PNG) must travel inside the .app to be self-contained.
find "$ROOT/.build/release" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

echo "▸ ad-hoc sign (stable-enough for a locally-installed copy that isn't re-signed after this)"
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP" && echo "  signature OK"

echo "▸ Desktop shortcut → $DESKTOP_LINK"
rm -f "$DESKTOP_LINK"
ln -s "$APP" "$DESKTOP_LINK"

# Refresh Launch Services so the icon + name show immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true

echo "✓ Installed. Open it from /Applications, Spotlight (\"CallBrain\"), or the Desktop shortcut."
echo "  First launch will ask once for Keychain + folder access — click Allow and it won't ask again."
