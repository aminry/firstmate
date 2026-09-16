#!/usr/bin/env bash
# Live check for the daemon-side half of the change: when a crewmate withdraws
# the declaration that bought it the long recheck cadence, away-mode
# reconciliation must drop the watcher's wait-recheck throttle along with the
# rest of that lane's pause bookkeeping. A throttle left behind would silently
# suppress the FIRST recheck of the lane's next, unrelated wait episode.
#
# Drives the real bin/fm-supervise-daemon.sh reconciliation entry point against a
# real state home. The daemon is sourceable by contract (its executed-only block
# is guarded by BASH_SOURCE), which is how its own suite reaches this seam.
#
# Usage: live-daemon-throttle-drive.sh <repo-root>
set -u
ROOT=${1:?repo root}
umask 022
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-daemon.XXXXXX")
STATE="$WORK/state"; mkdir -p "$STATE"
WINDOW="fleet:fm-crew-validate"
WKEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')

printf 'daemon under test : %s\n' "$ROOT/bin/fm-supervise-daemon.sh"
printf 'crewmate window   : %s\n\n' "$WINDOW"

printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$WINDOW" > "$STATE/validate.meta"
printf 'paused: waiting on the upstream release cut\n' > "$STATE/validate.status"
: > "$STATE/.paused-$WKEY"
date +%s > "$STATE/.paused-rechecked-$WKEY"
date +%s > "$STATE/.waiting-resurfaced-$WKEY"
printf 'state before the crewmate withdraws its wait:\n'
ls -1a "$STATE" | grep -E '^\.(paused|waiting)-' | sed 's/^/    /'

printf '\nthe crewmate withdraws the wait: "working: the release landed, resuming validation"\n'
printf 'away-mode daemon reconciles the lane against that new status line...\n\n'
# shellcheck source=/dev/null
FM_WEDGE_ALARM_EXEC=discard . "$ROOT/bin/fm-supervise-daemon.sh"
reconcile_pause_tracking "$WINDOW" "$STATE" 'working: the release landed, resuming validation'

printf 'state after reconciliation:\n'
left=$(ls -1a "$STATE" | grep -E '^\.(paused|waiting)-' || true)
if [ -n "$left" ]; then printf '%s\n' "$left" | sed 's/^/    /'; else printf '    (no pause or wait bookkeeping left for this lane)\n'; fi

printf '\n'
if [ -e "$STATE/.waiting-resurfaced-$WKEY" ]; then
  printf '    FAIL  the wait-recheck throttle survived the withdrawn declaration;\n'
  printf '          the next unrelated wait episode on this lane would lose its first recheck\n'
  rm -rf "$WORK"; exit 1
fi
printf '    PASS  the wait-recheck throttle was cleared with the rest of the lane pause state,\n'
printf '          so the next wait episode on this lane is rechecked from its first window\n'
rm -rf "$WORK"
