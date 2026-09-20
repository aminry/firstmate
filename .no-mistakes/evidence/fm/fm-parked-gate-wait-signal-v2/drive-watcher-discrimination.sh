#!/usr/bin/env bash
# Product driver: stands up a hermetic firstmate home with a lane already stably
# stale at its recorded pane hash (the population wedge_timer_check owns), runs
# the REAL bin/fm-watch.sh, and prints the supervisor-facing wake text it emits.
set -u
ROOT=/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2XYZMPA90XVVRG38TJ1974E
. "$ROOT/tests/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
WATCH="$ROOT/bin/fm-watch.sh"

set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then touch -t "$stamp" "$f"
  else stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S); touch -t "$stamp" "$f"; fi
}
seen_sig() {
  local reported size ident
  reported=$(status_observed_signature "$1"); size=$(size_of "$1")
  ident=$(_fm_open_decisions_file_ident "$1")
  printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
}
size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
TMP_ROOT=$(fm_test_tmproot pgw-watch-drive)

lane() {  # <name> <verdict> <status-log> <armed:0|1> <rounds>
  local name=$1 verdict=$2 log=$3 armed=$4 rounds=$5
  local dir state window key statusf out pid n
  dir=$(make_case "$name"); state="$dir/state"
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  statusf="$state/wedge.status"; out="$dir/watch.out"
  printf 'waiting at the gate' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/wedge.meta"
  printf '%s\n' "$log" > "$statusf"
  set_mtime "$(( $(date +%s) - 2000 ))" "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-wedge_status"
  printf '%s' "$(hash_text 'waiting at the gate')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$(hash_text 'waiting at the gate')" > "$state/.stale-$key"
  mkdir -p "$dir/config"
  [ "$armed" = 1 ] && : > "$dir/config/wedge-defer-parked-gate"
  n=1
  while [ "$n" -le "$rounds" ]; do
    PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
      FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_TMUX_CURRENT_COMMAND=grok \
      FM_FAKE_CREW_STATE="$verdict" FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=999 FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; }
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$state/.d.err" || {
      s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$state/.d.err")
      g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$state/.d.err")
      [ -n "$s" ] && FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$s" --recovery-generation "$g" >/dev/null 2>&1
    }
    n=$((n + 1))
  done
  printf '%s\n' "$out"
}

HUMAN='state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · ask-user: authority decision · run: 01RUNGATE'
CREWMATE='state: parked · source: run-step · parked at fix_review (ask-user: authority decision follow-up): 2 finding(s) · run: 01RUNGATE'
ESCALATED='needs-decision [key=nm-01RUNGATE-review]: the gate raised an authority question
working: still parked at that gate'
UNRELATED='needs-decision [key=earlier-question]: which changelog section fits
working: still parked at that gate'

echo "############ 1. ARMED home, gate owed a HUMAN, decision open under key nm-01RUNGATE-review"
sed -n '1,40p' "$(lane armed-human "$HUMAN" "$ESCALATED" 1 1)"
echo
echo "############ 2. ARMED home, same gate but owed the CREWMATE's own answer (3 rounds)"
sed -n '1,60p' "$(lane armed-crewmate "$CREWMATE" "$ESCALATED" 1 3)"
echo
echo "############ 3. UNARMED home (config/wedge-defer-parked-gate absent), human-owed gate (3 rounds)"
sed -n '1,60p' "$(lane unarmed-human "$HUMAN" "$ESCALATED" 0 3)"
echo
echo "############ 4. ARMED home, human-owed gate, only an UNRELATED open decision (3 rounds)"
sed -n '1,60p' "$(lane armed-unrelated "$HUMAN" "$UNRELATED" 1 3)"
