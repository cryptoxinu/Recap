#!/bin/bash
# CallBrain -> Hermes corpus sync watchdog.
#
# WHY THIS EXISTS (2026-07-29): the client Mac fell out of Tailscale and the corpus push failed 982
# consecutive times WITHOUT A WORD. `launchctl list` still reported exit 0 (it reflects the last
# attempt, not the streak) and the sync's own .out.log is failure-only, so a large log looks like
# activity. The founder found out by noticing a call missing from Hermes. That is the failure this
# agent exists to make impossible.
#
# WHY IT IS A SEPARATE AGENT, NOT A PATCH TO THE SYNC SCRIPT:
# CorpusSyncInstaller.install() rewrites ~/bin/callbrain-corpus-sync.sh unconditionally on every
# CallBrain launch, so any alarm added there is silently wiped (the same trap that reverted the
# 2026-07-28 host fix). Nothing in the app manages THIS file.
#
# WHY IT CHECKS THE OUTCOME, NOT AN EXIT CODE:
# It asks "are the calls actually on Hermes, and recent?" — so it catches every cause at once
# (Tailscale down, auth lapsed, ssh broken, rsync wrong, export stalled, disk full), including causes
# nobody has thought of yet. An exit-code watcher only catches the ones the sync script knows about.
#
# Runs from com.callbrain.sync-watchdog. Always exits 0 — a watchdog must never itself become the
# thing that fails. Every dependency is injectable (CBW_*) so tools/test-sync-watchdog.sh runs offline.
set -uo pipefail   # deliberately NOT -e: probe failures are the subject matter, not a reason to die

STATE="${CBW_STATE:-$HOME/Library/Application Support/CallBrain/.sync-watchdog.state}"
LOG="${CBW_LOG:-$HOME/Library/Logs/callbrain-sync-watchdog.log}"
TS="${CBW_TAILSCALE:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
SSH="${CBW_SSH:-/usr/bin/ssh}"
MAX_LAG="${CBW_MAX_LAG:-1800}"           # 30 min: sync fires every 5 min, so this is ~6 missed cycles
FAIL_THRESHOLD="${CBW_FAIL_THRESHOLD:-2}" # alert only on the 2nd consecutive bad check (no blip noise)
RENOTIFY="${CBW_RENOTIFY:-21600}"         # while still broken, re-nag at most every 6h

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")" 2>/dev/null

# Keep the log bounded — a watchdog must never contribute to a disk-full (see testing.md).
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -c 131072 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# ---- config, resolved from the SAME prefs the app uses so the two can never diverge --------------
pref() { defaults read com.callbrain.app "$1" 2>/dev/null; }
HOST="${CBW_HOST:-$(pref callbrain.corpus.syncHost)}"
DEST="${CBW_DEST:-$(pref callbrain.corpus.syncDest)}"
CORPUS="${CBW_CORPUS:-$(pref callbrain.corpus.folder)}"
[ -n "$DEST" ]   || DEST="callbrain-corpus"
[ -n "$CORPUS" ] || CORPUS="$HOME/Library/Application Support/CallBrain/corpus"

# Mirror CorpusSyncInstaller.isSafeHost / isSafeDest. A tampered or half-written pref must not send a
# probe (or a hostname) somewhere off the tailnet.
case "$HOST" in
  "") log "no sync host configured (callbrain.corpus.syncHost unset) — nothing to watch"; exit 0;;
  *.ts.net) ;;
  *) log "refusing non-Tailscale host '$HOST' (must end in .ts.net) — check callbrain.corpus.syncHost"; exit 0;;
esac
case "$DEST" in
  /*|~*|.*|-*|*..*|*' '*|*';'*|*'$'*|*'`'*) log "refusing unsafe dest '$DEST'"; exit 0;;
esac

# ---- state (parsed, never sourced — a tampered state file must not execute) ----------------------
fails=0; last_notify=0; alerting=0
if [ -f "$STATE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      fails)       [[ "$v" =~ ^[0-9]+$ ]] && fails="$v";;
      last_notify) [[ "$v" =~ ^[0-9]+$ ]] && last_notify="$v";;
      alerting)    [[ "$v" =~ ^[01]$   ]] && alerting="$v";;
    esac
  done < "$STATE"
fi

# ---- alert channels -------------------------------------------------------------------------------
# TWO channels, because a notification alone is not reliable ENOUGH — not because it is broken.
#   1. macOS notification (osascript). Verified working. Note it posts as "Script Editor", and it does
#      NOT need an entry in com.apple.ncprefs to be delivered — an earlier reading of that plist wrongly
#      concluded these were being dropped. What is true: a banner is transient, is easy to miss while
#      away from the Mac, is hidden by Focus, and disappears once dismissed.
#   2. A file on the Desktop — PERSISTENT. It is still there hours later, survives dismissal and Focus,
#      states what to do in plain language, and self-clears on recovery.
# The point of the pair is that missing #1 costs nothing, because #2 is still sitting there.
DESKTOP="${CBW_DESKTOP:-$HOME/Desktop}"
MARKER="$DESKTOP/⚠️ RECAP - CALLS NOT SYNCING.txt"

notify() {  # $1 title, $2 message — transient channel; the Desktop marker is the durable one
  if [ -n "${CBW_NOTIFY:-}" ]; then "$CBW_NOTIFY" "$1" "$2"; return 0; fi
  local t="${1//\\/\\\\}"; t="${t//\"/\\\"}"
  local m="${2//\\/\\\\}"; m="${m//\"/\\\"}"
  /usr/bin/osascript -e "display notification \"$m\" with title \"$t\" sound name \"Basso\"" >/dev/null 2>&1
  return 0
}

# Written on EVERY unhealthy run once past the threshold (not just the first), so deleting it while the
# problem persists brings it straight back. Same filename each time, so it can never pile up.
write_marker() {  # $1 reason
  [ -d "$DESKTOP" ] || return 0
  cat > "$MARKER" 2>/dev/null <<EOF
Your Recap calls are NOT reaching the Hermes Mac.

What's wrong:
  $1

Since: $(date '+%A %d %B %Y, %-I:%M %p')

Nothing has been lost — calls are still being recorded and saved on this Mac.
They just aren't being copied over to Hermes, so anything you ask Hermes will
be missing the newest calls until this is fixed.

Most common cause: this Mac has dropped off Tailscale.
  Check the Tailscale icon in the menu bar. If it says you're logged out,
  click "Log in" and this file will disappear on its own within ~15 minutes.

This file is created and removed automatically. You never need to delete it.
EOF
}
clear_marker() { rm -f "$MARKER" 2>/dev/null; return 0; }

# ---- probes --------------------------------------------------------------------------------------
reason=""

# 1) Tailscale. Fail-OPEN on an unparseable answer: the ssh probe below is the authoritative test, and
#    a JSON hiccup must not manufacture a false alarm.
if [ -x "$TS" ] || [ -n "${CBW_TAILSCALE:-}" ]; then
  ts_state=$("$TS" status --json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("unknown|"); raise SystemExit
online = (d.get("Self") or {}).get("Online")
health = [h for h in (d.get("Health") or []) if h]
print(("up" if online is True else "down") + "|" + (health[0][:90] if health else ""))
' 2>/dev/null)
  case "$ts_state" in
    down\|*)
      detail="${ts_state#down|}"
      reason="Tailscale is disconnected on this Mac${detail:+ — $detail}"
      ;;
  esac
fi

# 2) Reachability + what Hermes actually holds. One round trip returns "<call-file-count> <index-mtime>".
if [ -z "$reason" ]; then
  probe=$("$SSH" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$HOST" \
          "printf '%s %s\n' \"\$(ls ~/$DEST/calls 2>/dev/null | wc -l | tr -d ' ')\" \"\$(stat -f%m ~/$DEST/index.jsonl 2>/dev/null || echo 0)\"" 2>/dev/null)
  if [ -z "$probe" ]; then
    reason="Can't reach the Hermes Mac ($HOST) — calls aren't being delivered"
  else
    remote_count=$(printf '%s' "$probe" | awk '{print $1+0}')
    remote_mtime=$(printf '%s' "$probe" | awk '{print $2+0}')
    local_count=$(ls "$CORPUS/calls" 2>/dev/null | wc -l | tr -d ' '); local_count=${local_count:-0}
    local_mtime=$(stat -f%m "$CORPUS/index.jsonl" 2>/dev/null || echo 0)

    if [ "$remote_count" -lt "$local_count" ]; then
      reason="$((local_count - remote_count)) call file(s) haven't reached Hermes yet (local $local_count, Hermes $remote_count)"
    elif [ "$local_mtime" -gt 0 ] && [ "$remote_mtime" -gt 0 ] \
         && [ "$((local_mtime - remote_mtime))" -gt "$MAX_LAG" ]; then
      reason="Hermes is $(( (local_mtime - remote_mtime) / 60 )) min behind — new calls aren't reaching it"
    fi
  fi
fi

# ---- decide ---------------------------------------------------------------------------------------
now=$(date +%s)
if [ -z "$reason" ]; then
  clear_marker                                    # unconditional: never leave a stale alarm on the Desktop
  if [ "$alerting" = "1" ]; then
    notify "Recap — sync is back" "Your calls are reaching Hermes again. Nothing was lost."
    log "RECOVERED after $fails failed check(s)"
  fi
  fails=0; alerting=0; last_notify=0
else
  fails=$((fails + 1))
  log "UNHEALTHY (#$fails): $reason"
  if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
    # Marker first, and every time: it is the channel that PERSISTS, and it must not depend
    # on the notifier succeeding or on the renotify debounce.
    write_marker "$reason"
    alerting=1
    if [ "$((now - last_notify))" -ge "$RENOTIFY" ]; then   # debounce the NAG, not the marker
      notify "Recap — calls aren't syncing" "$reason"
      last_notify="$now"
      log "NOTIFIED: $reason"
    fi
  fi
fi

printf 'fails=%s\nlast_notify=%s\nalerting=%s\n' "$fails" "$last_notify" "$alerting" > "$STATE"
exit 0
