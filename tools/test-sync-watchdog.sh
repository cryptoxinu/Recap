#!/bin/bash
# Tests for callbrain-sync-watchdog.sh.
#
# The watchdog's whole job is to SPEAK UP when the corpus stops reaching Hermes. The bug it exists to
# prevent (2026-07-29) was 982 consecutive silent failures, so the cases that matter most are the
# negative ones: it must fire on each distinct breakage, must NOT fire on a single transient blip, and
# must tell the founder when things recover. Every external dependency (tailscale, ssh, notifier) is
# injected, so these run offline and deterministically.
set -uo pipefail

WATCHDOG="${1:-$HOME/bin/callbrain-sync-watchdog.sh}"
[ -x "$WATCHDOG" ] || { echo "FATAL: watchdog not executable at $WATCHDOG"; exit 1; }

PASS=0; FAIL=0
TESTROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TESTROOT"' EXIT   # per testing.md: clean up even on failure/interrupt

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# ---- fixture: a fresh sandbox per case -------------------------------------------------
# Builds fake tailscale/ssh/notify commands whose behavior is dictated by the two args, so each
# test states its scenario declaratively.
#   $1 = tailscale scenario: online | offline | loggedout
#   $2 = ssh scenario:       ok | unreachable | lag:<seconds-behind> | count:<n>
setup() {
  BOX="$TESTROOT/box$RANDOM$RANDOM"; mkdir -p "$BOX/bin" "$BOX/corpus/calls"
  : > "$BOX/corpus/index.jsonl"
  for i in 1 2 3; do : > "$BOX/corpus/calls/c$i.json"; done

  case "$1" in
    online)    printf '{"BackendState":"Running","Self":{"Online":true},"Health":[]}\n' > "$BOX/ts.json";;
    offline)   printf '{"BackendState":"Running","Self":{"Online":false},"Health":[]}\n' > "$BOX/ts.json";;
    loggedout) printf '{"BackendState":"Running","Self":{"Online":false},"Health":["You are logged out."]}\n' > "$BOX/ts.json";;
  esac
  printf '#!/bin/bash\ncat %q\n' "$BOX/ts.json" > "$BOX/bin/ts"; chmod +x "$BOX/bin/ts"

  local now; now=$(date +%s)
  case "$2" in
    unreachable) printf '#!/bin/bash\nexit 255\n' > "$BOX/bin/ssh";;
    lag:*)       printf '#!/bin/bash\necho "3 %s"\n' "$((now - ${2#lag:}))" > "$BOX/bin/ssh";;
    count:*)     printf '#!/bin/bash\necho "%s %s"\n' "${2#count:}" "$now" > "$BOX/bin/ssh";;
    ok|*)        printf '#!/bin/bash\necho "3 %s"\n' "$now" > "$BOX/bin/ssh";;
  esac
  chmod +x "$BOX/bin/ssh"

  printf '#!/bin/bash\necho "$*" >> %q\n' "$BOX/notified" > "$BOX/bin/notify"; chmod +x "$BOX/bin/notify"
  : > "$BOX/notified"
  mkdir -p "$BOX/desktop"

  export CBW_STATE="$BOX/state" CBW_TAILSCALE="$BOX/bin/ts" CBW_SSH="$BOX/bin/ssh" \
         CBW_NOTIFY="$BOX/bin/notify" CBW_CORPUS="$BOX/corpus" CBW_LOG="$BOX/log" \
         CBW_DESKTOP="$BOX/desktop" \
         CBW_HOST="fake.tailnet0.ts.net" CBW_DEST="callbrain-corpus" \
         CBW_MAX_LAG=1800 CBW_FAIL_THRESHOLD=2 CBW_RENOTIFY=21600
}
notifs() { grep -c . "$BOX/notified" 2>/dev/null | tr -d ' '; }
# The Desktop marker is the PRIMARY alert channel: macOS silently drops osascript notifications
# unless Script Editor is a registered notification client (it is not, on this Mac), so an alert
# that only calls osascript is invisible. A file on the Desktop cannot be suppressed by Focus,
# Notification Center, or a missing permission.
markers() { find "$BOX/desktop" -maxdepth 1 -name "*NOT SYNCING*" 2>/dev/null | wc -l | tr -d ' '; }

echo "== healthy =="
setup online ok
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "silent while healthy (3 runs, 0 alerts)" "$(notifs)" "0"

echo "== tailscale logged out =="
setup loggedout ok
"$WATCHDOG" >/dev/null 2>&1
check "one failure is below threshold -> stays quiet" "$(notifs)" "0"
"$WATCHDOG" >/dev/null 2>&1
check "second consecutive failure -> alerts" "$(notifs)" "1"
if grep -qi "tailscale" "$BOX/notified"; then ok "alert names Tailscale as the cause"; else bad "alert should name Tailscale (got: $(cat "$BOX/notified"))"; fi

echo "== hermes unreachable =="
setup online unreachable
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "alerts when the Hermes Mac can't be reached" "$(notifs)" "1"
if grep -qi "reach" "$BOX/notified"; then ok "alert says it can't reach Hermes"; else bad "alert should mention reachability (got: $(cat "$BOX/notified"))"; fi

echo "== calls falling behind =="
setup online lag:7200          # Hermes index is 2h older than local
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "alerts when Hermes is stale beyond CBW_MAX_LAG" "$(notifs)" "1"
if grep -qi "behind\|stale\|reaching" "$BOX/notified"; then ok "alert explains calls aren't arriving"; else bad "alert should explain staleness (got: $(cat "$BOX/notified"))"; fi

setup online lag:600           # 10 min behind, well inside a normal sync cycle
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "normal sync lag is NOT an alert" "$(notifs)" "0"

echo "== missing calls on hermes =="
setup online count:1           # local has 3 call files, Hermes only 1
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "alerts when Hermes is missing call files" "$(notifs)" "1"

echo "== recovery =="
setup loggedout ok
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "broken -> 1 alert" "$(notifs)" "1"
printf '{"BackendState":"Running","Self":{"Online":true},"Health":[]}\n' > "$BOX/ts.json"
"$WATCHDOG" >/dev/null 2>&1
check "recovery is announced" "$(notifs)" "2"
if grep -qi "back\|recovered\|working" "$BOX/notified"; then ok "recovery alert is worded as good news"; else bad "recovery wording (got: $(cat "$BOX/notified"))"; fi
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "stays quiet after recovering" "$(notifs)" "2"

echo "== no alert spam while still broken =="
setup loggedout ok
for _ in 1 2 3 4 5 6 7 8; do "$WATCHDOG" >/dev/null 2>&1; done
check "8 broken runs -> still only 1 alert (renotify debounce)" "$(notifs)" "1"

echo "== Desktop marker (the channel that cannot be suppressed) =="
setup online ok
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "no marker while healthy" "$(markers)" "0"

setup loggedout ok
"$WATCHDOG" >/dev/null 2>&1
check "no marker below threshold (single blip)" "$(markers)" "0"
"$WATCHDOG" >/dev/null 2>&1
check "marker appears on the 2nd consecutive failure" "$(markers)" "1"
MFILE=$(find "$BOX/desktop" -maxdepth 1 -name "*NOT SYNCING*" | head -1)
if grep -qi "tailscale" "$MFILE" 2>/dev/null; then ok "marker states the cause"; else bad "marker should state the cause (got: $(cat "$MFILE" 2>/dev/null | head -3))"; fi
if grep -qi "recap\|call" "$MFILE" 2>/dev/null; then ok "marker is written in plain language"; else bad "marker wording"; fi

printf '{"BackendState":"Running","Self":{"Online":true},"Health":[]}\n' > "$BOX/ts.json"
"$WATCHDOG" >/dev/null 2>&1
check "marker is REMOVED on recovery (self-clearing)" "$(markers)" "0"

echo "== marker survives repeated broken runs without duplicating =="
setup loggedout ok
for _ in 1 2 3 4 5 6; do "$WATCHDOG" >/dev/null 2>&1; done
check "exactly one marker after 6 broken runs" "$(markers)" "1"

echo "== alerting does not depend on the notifier working =="
setup loggedout ok
CBW_NOTIFY=/usr/bin/false "$WATCHDOG" >/dev/null 2>&1
CBW_NOTIFY=/usr/bin/false "$WATCHDOG" >/dev/null 2>&1
check "marker still written when the notifier FAILS" "$(markers)" "1"

# The marker must NOT inherit the notification's 6-hour debounce. If the founder deletes it while the
# outage is ongoing, the very next check has to put it back -- otherwise the Mac looks healthy for up
# to 6 hours while calls are still not arriving.
echo "== marker returns if deleted while still broken =="
setup loggedout ok
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
check "marker present" "$(markers)" "1"
rm -f "$BOX/desktop"/*NOT\ SYNCING* 2>/dev/null
check "marker deleted by hand" "$(markers)" "0"
"$WATCHDOG" >/dev/null 2>&1
check "marker RETURNS on the next check (not debounced)" "$(markers)" "1"

echo "== marker is actionable, not just a label =="
setup loggedout ok
"$WATCHDOG" >/dev/null 2>&1; "$WATCHDOG" >/dev/null 2>&1
MF=$(find "$BOX/desktop" -maxdepth 1 -name "*NOT SYNCING*" | head -1)
if grep -qi "not reaching\|aren't reaching\|not being copied" "$MF" 2>/dev/null; then ok "marker states the IMPACT"; else bad "marker must state the impact"; fi
if grep -qi "menu bar\|log in\|tailscale icon" "$MF" 2>/dev/null; then ok "marker states WHAT TO DO"; else bad "marker must tell the founder what to do"; fi
if grep -qi "nothing.*lost\|still being recorded" "$MF" 2>/dev/null; then ok "marker reassures nothing is lost"; else bad "marker must say nothing is lost"; fi
if grep -qi "automatic\|on its own\|never need to delete" "$MF" 2>/dev/null; then ok "marker says it self-clears"; else bad "marker must say it clears itself"; fi

echo "== never blocks launchd =="
setup online unreachable
"$WATCHDOG" >/dev/null 2>&1
check "exits 0 even when the probe fails" "$?" "0"

echo "== bad pref can't redirect the probe =="
setup online ok
CBW_HOST="evil.example.com" "$WATCHDOG" >/dev/null 2>&1
if grep -qi "ts.net\|refus" "$BOX/log" 2>/dev/null; then ok "non-Tailscale host is refused"; else bad "should refuse a non-.ts.net host (log: $(cat "$BOX/log" 2>/dev/null))"; fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
