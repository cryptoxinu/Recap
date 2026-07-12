#!/bin/bash
# CallBrain call-corpus sync — REFERENCE COPY.
#
# The CallBrain app writes this script automatically (with an absolute SRC path) to
# ~/bin/callbrain-corpus-sync.sh when you turn on "Export every call to a folder" in Settings, and loads
# the companion LaunchAgent (com.callbrain.corpus-sync.plist). This copy is kept in the repo for review
# and manual install.
#
# It pushes the local corpus folder to a dedicated, CallBrain-owned folder on the server Mac over Tailscale
# — one-directional, so `--delete` only ever prunes files CallBrain removed and can never touch the bot's
# own index/db (keep those OUTSIDE ${DEST_DIR}).
#
# ONE-TIME server setup (on the server Mac, e.g. your-server):
#   1) sudo tailscale set --ssh          # enable Tailscale SSH
#   2) allow SSH from this Mac's user in the Tailscale admin ACL
#   3) mkdir -p ~/callbrain-corpus       # the dest folder the bot reads (openrsync won't create it)
#   4) from this Mac, verify:  ssh your-server.ts.net true
#      then dry-run:  rsync -a --delete --partial -n -e ssh \
#                        "$HOME/Library/Application Support/CallBrain/corpus/" your-server.ts.net:callbrain-corpus/
set -euo pipefail
SRC="$HOME/Library/Application Support/CallBrain/corpus/"
DEST_HOST="your-server.ts.net"
DEST_DIR="callbrain-corpus"
# Guard: never sync from a folder that isn't a provisioned CallBrain corpus (stops an empty / half-
# provisioned source from letting --delete wipe the server).
[ -f "${SRC}.callbrain-corpus" ] || { echo "no corpus marker at ${SRC}; skipping"; exit 0; }
# Use REAL GNU rsync (Homebrew), not macOS openrsync (which silently writes nothing over ssh between two
# Macs). --rsync-path forces the server to GNU rsync too; --mkpath auto-creates the dest folder.
RSYNC=""
for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do [ -x "$c" ] && RSYNC="$c" && break; done
[ -n "$RSYNC" ] || { echo "GNU rsync not installed -- run: brew install rsync"; exit 1; }
exec "$RSYNC" -a --delete --mkpath \
  --rsync-path=/opt/homebrew/bin/rsync \
  -e "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new" \
  "$SRC" "${DEST_HOST}:${DEST_DIR}/"
