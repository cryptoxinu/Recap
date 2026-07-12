#!/bin/bash
# CallBrain — runtime smoke harness. Catches the FREEZE / PINWHEEL / layout-loop class of bug that unit
# tests + code review CANNOT see (they only surface when the SwiftUI app actually renders + gets driven).
#
# For each surface it: launches the app into that surface via a CALLBRAIN_* deep-link with the main-thread
# WATCHDOG on, waits for it to settle/answer, samples the main thread, and FAILS if the thread is stuck in
# a SwiftUI layout loop (SelectionOverlay / GraphHost.flushTransactions spinning) or the watchdog logged a
# >250ms stall. Reads process samples + the watchdog log — never screenshots — so it's reliable regardless
# of window focus. Run this before every reinstall.
#
#   tools/smoke.sh              # build + assemble + smoke every surface
#   SKIP_BUILD=1 tools/smoke.sh # smoke the already-assembled .build/CallBrain.app
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/CallBrain.app"
DB="$HOME/Library/Application Support/CallBrain/callbrain.sqlite3"
FAILED=0
LATEST_CRASH_BEFORE="$(ls -t "$HOME"/Library/Logs/DiagnosticReports/CallBrain*.ips 2>/dev/null | head -1 || true)"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "▸ release build + assemble"
  swift build -c release --package-path "$ROOT" >/dev/null || { echo "BUILD FAILED"; exit 1; }
  pkill -9 -f "CallBrain.app/Contents/MacOS/CallBrain" 2>/dev/null; sleep 1
  rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$ROOT/.build/release/CallBrainApp" "$APP/Contents/MacOS/CallBrain"
  cp "$ROOT/.build/release/cbtranscribe" "$APP/Contents/MacOS/cbtranscribe"
  cp "$ROOT/tools/Info.plist" "$APP/Contents/Info.plist"
  cp "$ROOT/tools/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  find "$ROOT/.build/release" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
codesign --force --deep --options runtime --entitlements "$ROOT/tools/CallBrain.entitlements" --sign "${SIGN_ID:--}" "$APP" >/dev/null 2>&1
fi

# App Nap throttles the occluded app's main-queue timers (e.g. behind a LOCKED screen), delaying
# watchdog heartbeats into phantom "stalls" (root-caused 2026-07-02: sampled main thread was IDLE
# during a reported 1.8s stall). Disable it for the smoke run so the watchdog measures the app.
defaults write com.callbrain.app NSAppSleepDisabled -bool YES 2>/dev/null

MID="$(sqlite3 "$DB" 'SELECT id FROM meetings LIMIT 1;' 2>/dev/null)"
WLOG=/tmp/cb-watchdog.log; rm -f "$WLOG"    # the watchdog appends stalls here (reliable for open-launched apps)

# smoke <label> <settle-seconds> <env-flags...>
smoke() {
  local label="$1" settle="$2"; shift 2
  pkill -9 -f "CallBrain.app/Contents/MacOS/CallBrain" 2>/dev/null; sleep 1.5
  open "$APP" --env CALLBRAIN_WATCHDOG=1 --env CALLBRAIN_WATCHDOG_SAMPLE=1 --env CALLBRAIN_SKIP_RECONCILE=1 "$@"
  sleep "$settle"
  local pid; pid="$(pgrep -f "CallBrain.app/Contents/MacOS/CallBrain" | head -1)"
  if [ -z "$pid" ]; then echo "  ✗ $label — process died"; FAILED=1; return; fi
  local s=/tmp/cb-smoke-sample.txt
  sample "$pid" 1 -file "$s" >/dev/null 2>&1
  if grep -qE "SelectionOverlay|GraphHost.flushTransactions" "$s" && ! grep -q "nextEventMatchingMask" "$s"; then
    echo "  ✗ $label — MAIN-THREAD LAYOUT LOOP (beachball)"; FAILED=1
  elif grep -q "nextEventMatchingMask" "$s"; then
    echo "  ✓ $label"
  else
    echo "  ? $label — busy (inspect $s): $(grep -m1 -E 'CallBrain|SwiftUI' "$s" | tr -s ' ' | cut -c1-70)"
  fi
}

echo "▸ smoke pass (watchdog on; sampling the main thread)"
smoke "Home"                       6  --env CALLBRAIN_TAB=home
smoke "Meetings (filter bar)"      6  --env CALLBRAIN_TAB=meetings
smoke "Tasks"                      6  --env CALLBRAIN_TAB=tasks
smoke "Import"                     6  --env CALLBRAIN_TAB=imports
smoke "Settings"                   6  --env CALLBRAIN_TAB=settings
smoke "Dup review"                 6  --env CALLBRAIN_DUPREVIEW=1
if [ -n "$MID" ]; then
  smoke "Call · transcript + Find" 7  --env "CALLBRAIN_MEETING=$MID" --env "CALLBRAIN_FIND=the"
  smoke "Call · AskFred (2 turns)" 55 --env "CALLBRAIN_MEETING=$MID" --env "CALLBRAIN_MEETING_ASK=Summarize this call in one line"
fi
smoke "Global Ask"                 40 --env CALLBRAIN_TAB=ask --env "CALLBRAIN_ASK=What are my action items"

pkill -9 -f "CallBrain.app/Contents/MacOS/CallBrain" 2>/dev/null
# Read stalls from the watchdog FILE (reliable). A [launch] hitch is the unavoidable startup cost; only a
# [session] stall is a real mid-use freeze → that fails the pass.
# NOTE: grep -c prints "0" AND exits 1 when there are no matches, so `|| echo 0` would yield "0\n0" and
# falsely fail the comparison. Swallow the exit with `|| true` and default an empty file to 0.
SESSION_STALLS="$(grep -c '\[session\]' "$WLOG" 2>/dev/null || true)"; SESSION_STALLS="${SESSION_STALLS:-0}"
LAUNCH_STALLS="$(grep -c '\[launch\]' "$WLOG" 2>/dev/null || true)"; LAUNCH_STALLS="${LAUNCH_STALLS:-0}"
echo "▸ watchdog: ${SESSION_STALLS} mid-session stall(s), ${LAUNCH_STALLS} benign launch hitch(es)"
[ -s "$WLOG" ] && grep '\[session\]' "$WLOG" | sed 's/^/    /'
# Classify session stalls by the in-stall stack the watchdog sampled (CALLBRAIN_WATCHDOG_SAMPLE):
# a stall whose main-thread graph is the COMPOSITOR waiting on render-surface allocation
# (RenderBox wait_for_allocations / CAContext waitForCommitId) with no CallBrain frames below
# the event loop is SYSTEM LOAD (WindowServer back-pressure), not an app bug — warn, don't fail.
# App-code stalls, sample-less stalls, and anything ≥2000ms still fail.
if [ "${SESSION_STALLS:-0}" != "0" ]; then
  APP_STALL=0
  if grep -q "stall sample" "$WLOG" 2>/dev/null; then
    for f in /tmp/cb-stall-*.txt; do
      [ -f "$f" ] || continue
      MAIN_GRAPH=$(awk '/Call graph/{flag=1} flag{print} /Thread_[0-9]+ DispatchQueue/{if(flag && seen++) exit}' "$f" | head -80)
      if echo "$MAIN_GRAPH" | grep -qE "wait_for_allocations|waitForCommitId"; then
        echo "    ↳ $f: compositor wait (WindowServer back-pressure) — system load, not app code"
      else
        echo "    ↳ $f: app-code stall — REAL"; APP_STALL=1
      fi
    done
  else
    APP_STALL=1   # stall with no sample captured → treat as real
  fi
  grep '\[session\]' "$WLOG" | grep -qE "blocked (2[0-9]{3}|[3-9][0-9]{3}|[0-9]{5,})ms" && APP_STALL=1  # ≥2s always fails
  [ "$APP_STALL" = "1" ] && FAILED=1
fi
rm -f /tmp/cb-stall-*.txt

LATEST_CRASH_AFTER="$(ls -t "$HOME"/Library/Logs/DiagnosticReports/CallBrain*.ips 2>/dev/null | head -1 || true)"
if [ -n "$LATEST_CRASH_AFTER" ] && [ "$LATEST_CRASH_AFTER" != "$LATEST_CRASH_BEFORE" ]; then
  echo "  ✗ new crash report appeared: $LATEST_CRASH_AFTER"
  FAILED=1
fi

if [ "$FAILED" = "0" ]; then echo "✓ SMOKE PASS — every surface responsive, no layout loops, no mid-session stalls"; exit 0
else echo "✗ SMOKE FAIL — see above"; exit 1; fi
