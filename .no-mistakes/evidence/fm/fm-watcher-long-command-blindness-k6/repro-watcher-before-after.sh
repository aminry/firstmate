#!/usr/bin/env bash
# Reviewer demo (not part of the suite): what firstmate is actually told about a
# quiet pane whose no-mistakes validation pipeline is demonstrably still
# producing output inside the pipeline's OWN checkout - the paseo-stage1-f4
# shape from the user intent. Copy into <tree>/tests/ and run from <tree>.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-pipeline-wedge-demo)

size_of() { LC_ALL=C wc -c < "$1" | tr -d "[:space:]"; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then touch -t "$stamp" "$f"
  else stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S); touch -t "$stamp" "$f"; fi
}

seen_sig() {
  local reported size ident
  reported=$(status_observed_signature "$1")
  size=$(size_of "$1")
  ident=$(_fm_open_decisions_file_ident "$1")
  printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
}

# ONE fixture, two pipeline verdicts. Everything else is byte-identical:
#   * the pane has rendered the same frame for 500s (a suite printing nothing)
#   * the crew's own worktree is untouched for 900s (validation runs in the
#     pipeline's separate checkout, so the crew tree never moves)
#   * the run record says `working / run-step` in BOTH cases
run_scenario() {  # <slug> <crew-state-verdict>
  local slug=$1 verdict=$2 dir state fakebin out drain_out capture window key pane_hash pid wt back alive=0
  dir=$(make_case "demo-$slug"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture="$dir/pane.txt"
  window="paseo:fm-paseo-stage1-f4"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'Running tests... (pane unchanged for 22 minutes)' > "$capture"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/paseo.meta"
  printf 'working: handed to validation\n' > "$state/paseo.status"
  printf '%s' "$(seen_sig "$state/paseo.status")" > "$state/.seen-paseo_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Running tests... (pane unchanged for 22 minutes)")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/main.c"

  export FM_FAKE_CREW_STATE="$verdict"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  local i=0
  while [ "$i" -lt 100 ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && alive=1
  reap "$pid"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true

  echo "  crew state the watcher read:"
  echo "      $verdict"
  if [ "$alive" = 1 ]; then
    echo "  watcher:  still absorbing - firstmate was NOT woken"
  else
    echo "  watcher:  EXITED on an actionable wake - a supervision turn is spent"
  fi
  echo "  what firstmate is told (watcher stdout):"
  if [ -s "$out" ]; then sed 's/^/      /' "$out"; else echo "      (nothing)"; fi
  echo "  durable wake queue after drain:"
  if [ -s "$drain_out" ]; then sed 's/^/      /' "$drain_out"; else echo "      (empty)"; fi
  echo "  wedge escalation counter: $(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo '(none)')"
  echo
  unset FM_FAKE_CREW_STATE
}

echo "=========================================================================="
echo "TREE: $ROOT"
echo "=========================================================================="
echo
echo "CASE 1 - the pipeline reports one of its OWN steps still producing output"
echo "         (healthy worker; every escalation here was noise)"
run_scenario active 'state: working · source: run-step · validating (fixing) · pipeline-activity: recent'
echo "CASE 2 - identical pane, pipeline reports NO active step (genuinely wedged)"
run_scenario quiet 'state: working · source: run-step · validating (fixing)'
