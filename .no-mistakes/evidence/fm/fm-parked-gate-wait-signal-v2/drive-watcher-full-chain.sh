#!/usr/bin/env bash
# End-to-end: a real bin/fm-watch.sh over a hermetic home, with the crew's current
# state supplied by the REAL bin/fm-crew-state.sh reading the REAL captured
# no-mistakes v1.70.1 gate payload through a fake `no-mistakes` CLI. Only the
# terminal backend and the no-mistakes transport are stand-ins.
set -u
ROOT=/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2XYZMPA90XVVRG38TJ1974E
. "$ROOT/tests/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
WATCH="$ROOT/bin/fm-watch.sh"
CAPTURE="$ROOT/tests/captures/no-mistakes-v1.70.1/parked.toon"
RUNID=01M20NDQH0G96AQYH1EHWGKT5F

set_mtime() { local e=$1 f=$2 s; if s=$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null); then touch -t "$s" "$f"; else s=$(date -d "@$e" +%Y%m%d%H%M.%S); touch -t "$s" "$f"; fi; }
size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }
seen_sig() { local r s i; r=$(status_observed_signature "$1"); s=$(size_of "$1"); i=$(_fm_open_decisions_file_ident "$1"); printf 'v2\t%s\t%s@%s' "$r" "$s" "$i"; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
TMP_ROOT=$(fm_test_tmproot pgw-full-chain)

lane() {  # <name> <status-log> <armed> <away> <rounds>
  local name=$1 log=$2 armed=$3 away=$4 rounds=$5
  local dir state window key statusf out pid n wt head short
  dir=$(make_case "$name"); state="$dir/state"
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  statusf="$state/wedge.status"; out="$dir/watch.out"
  wt="$dir/wt"; mkdir -p "$wt"
  git -C "$wt" init -q; git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b fm/competing
  head=$(git -C "$wt" rev-parse HEAD); short=$(git -C "$wt" rev-parse --short=8 HEAD)
  # A fake `no-mistakes` serving the captured payload, so the REAL crew-state reader runs.
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift
    if [ "$#" = 0 ]; then printf '%s\n' "${FM_FAKE_AXI_HOME:-}"; exit 0; fi
    case "${1:-}" in
      status) shift; printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
    esac ;;
  daemon) printf 'daemon running (pid 4242)\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/no-mistakes"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$window" "$wt" > "$state/wedge.meta"
  printf '%s\n' "$log" > "$statusf"
  set_mtime "$(( $(date +%s) - 2000 ))" "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-wedge_status"
  printf 'waiting at the gate' > "$dir/pane.txt"
  printf '%s' "$(hash_text 'waiting at the gate')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$(hash_text 'waiting at the gate')" > "$state/.stale-$key"
  mkdir -p "$dir/config"
  [ "$armed" = 1 ] && : > "$dir/config/wedge-defer-parked-gate"
  if [ "$away" = 1 ]; then
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" propose >/dev/null 2>&1 || echo "PROPOSE FAILED"
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null 2>&1 || echo "CONFIRM FAILED"
  fi
  if [ "$away" = 1 ]; then
    if [ -f "$state/.afk-contract" ] || ls "$state"/.afk-contract* >/dev/null 2>&1; then echo "### away-posture record present: YES ($(ls "$state"/.afk-contract* | tr '\n' ' '))"; else echo "### away-posture record present: NO (scenario would prove nothing)"; fi
  fi
  echo "### lane $name  armed=$armed away=$away"
  echo "### status log (the task's decision fold):"; sed 's/^/    /' "$statusf"
  echo "### the gate's own findings table, from the captured producer payload:"
  grep -n 'findings\[1\]{' "$CAPTURE" | cut -c1-140 | sed 's/^/    /'
  local payload
  payload=$(awk -v h="$head" '/^  head:/{print "  head: " h; next} /^  head_sha:/{print "  head_sha: " h; next} {print}' "$CAPTURE")
  export FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"$RUNID\",fm/competing,running,$short,\"\""
  export FM_FAKE_AXI_STATUS=$(printf '%s\n' "$payload" | sed 's|^  branch:.*|  branch: fm/competing|')
  echo "### crew-state verdict the watcher reads (REAL bin/fm-crew-state.sh):"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" wedge | sed 's/^/    /'
  n=1
  while [ "$n" -le "$rounds" ]; do
    PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
      FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_HOME="$dir" \
      FM_WATCH_HANDLING_SUCCESSOR=1 FM_STATE_OVERRIDE="$state" \
      FM_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=999 FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
    pid=$!; wait_for_exit "$pid" 150 || reap "$pid"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$state/.d.err" || {
      s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$state/.d.err")
      g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$state/.d.err")
      [ -n "$s" ] && FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$s" --recovery-generation "$g" >/dev/null 2>&1
    }
    n=$((n + 1))
  done
  echo "### watcher stdout - what the supervisor is told:"
  sed 's/^/    /' "$out"
  echo "### wedge escalation counter: $(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo '(none)')"
  echo "### triage log:"; sed 's/^/    /' "$state/.watch-triage.log" 2>/dev/null | tail -4
  echo
}

ESCALATED="needs-decision [key=nm-$RUNID-test]: ask-user findings=test-1 file=/tmp/nm-findings.txt
working: still parked at that gate"

echo "================ A. ARMED home, captured human-owed gate, decision open under nm-<run>-test"
lane full-chain-armed "$ESCALATED" 1 0 1
echo "================ B. ARMED home, same lane, AWAY-POSTURE record present"
lane full-chain-away "$ESCALATED" 1 1 1
echo "================ C. UNARMED home, byte-identical fixture (3 rounds)"
lane full-chain-unarmed "$ESCALATED" 0 0 3
