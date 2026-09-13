#!/usr/bin/env bash
# Evidence demo: config/wedge-defer-pipeline is a default-off, per-home opt-in.
#
# Drives the REAL bin/fm-watch.sh over one identical fixture (quiet pane,
# untouched worktree, crew reporting `pipeline-activity: recent`) in two homes
# that differ only in the presence of config/wedge-defer-pipeline, and prints
# what a supervisor would actually see: the watcher's wake output, the drained
# wake queue, the escalation counter, and the deferral state files.
#
# Fixture construction reuses the project's own test harness helpers
# (tests/wake-helpers.sh plus the helper half of tests/fm-watch-triage.test.sh,
# sourced with its bottom invocation list cut off) so the fixture is the same
# one the suite uses.
set -u

REPO=/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2EAKA9PSK9T9CM705S1JTMT
# shellcheck source=/dev/null
. "$REPO/tests/wake-helpers.sh"        # make_case, wait_for_exit, hash_text, fakes
# shellcheck source=/dev/null
. "$REPO/bin/fm-classify-lib.sh"       # status_observed_signature, size_of
TMP_ROOT=$(fm_test_tmproot fm-wedge-optin-evidence)

# Copied verbatim from tests/fm-watch-triage.test.sh so this transcript builds
# the same fixture the suite does.
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then touch -t "$stamp" "$f"
  else stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S); touch -t "$stamp" "$f"; fi
}
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1"); size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident" ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi ;;
  esac
}
size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"; rm -f "$beat"; first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat"); [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

rule() { printf '\n== %s ==\n' "$1"; }
show() { printf '  %s\n' "$1"; }

# One fixture builder, used twice. Quiet pane already classified stale 500s ago,
# threshold 240s, worktree untouched for 900s, crew-state reporting live
# pipeline activity. Only the config dir differs between the two runs.
build_fixture() {  # <case-name> <window>
  local dir=$1 window=$2 state key pane_hash sig back id
  dir=$(make_case "$1"); state="$dir/state"
  id=$(printf '%s' "${window#*:fm-}")
  mkdir -p "$dir/wt/src"
  printf 'idle validating output' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$dir/wt" > "$state/$id.meta"
  printf 'working: handed to validation\n' > "$state/$id.status"
  sig=$(seen_sig "$state/$id.status"); printf '%s' "$sig" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle validating output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  printf 'int main(void) { return 0; }\n' > "$dir/wt/src/main.c"
  set_mtime "$(( $(date +%s) - 900 ))" "$dir/wt/src/main.c"
  printf '%s\n' "$dir"
}

run_watcher() {  # <dir> <window> <config-dir>
  local dir=$1 window=$2 cfg=$3
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_CONFIG_OVERRIDE="$cfg" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$REPO/bin/fm-watch.sh" > "$dir/watch.out" &
  WATCH_PID=$!
}

report_state() {  # <dir> <window>
  local dir=$1 key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  show "state/.wedge-escalations-$key: $(cat "$dir/state/.wedge-escalations-$key" 2>/dev/null || echo '(absent)')"
  show "state/.progress-since-$key:    $([ -e "$dir/state/.progress-since-$key" ] && echo present || echo '(absent)')"
  show "state/.progress-resurfaced-$key: $([ -e "$dir/state/.progress-resurfaced-$key" ] && echo present || echo '(absent)')"
}

printf 'Firstmate wedge-deferral opt-in (config/wedge-defer-pipeline) - live watcher transcript\n'
printf 'repo: %s\n' "$(git -C "$REPO" rev-parse --short HEAD)"
printf 'fixture (identical in every scenario below): pane quiet and already classified stale 500s ago,\n'
printf 'wedge threshold 240s, crew worktree untouched for 900s.\n'

# ---------------------------------------------------------------------------
rule 'Scenario 1: crew IS inside a pipeline step - UNCONFIGURED home (flag absent)'
WINDOW=demo:fm-unconfigured
DIR=$(build_fixture demo-unconfigured "$WINDOW")
mkdir -p "$DIR/config"   # empty: no config/wedge-defer-pipeline
export FM_FAKE_CREW_STATE_unconfigured='state: working · source: run-step · validating (fixing) · pipeline-activity: recent'
show "crew-state verdict the watcher reads: $FM_FAKE_CREW_STATE_unconfigured"
show "config dir contents: $(ls -A "$DIR/config" | tr '\n' ' ' || true)(empty)"
run_watcher "$DIR" "$WINDOW" "$DIR/config"
if wait_for_exit "$WATCH_PID" 100; then
  show 'watcher exited on an actionable wake (the pre-existing behavior)'
else
  reap "$WATCH_PID"; show 'FAILED: watcher did not escalate'
fi
printf '  supervisor-visible wake output:\n'
sed 's/^/    | /' "$DIR/watch.out"
printf '  drained wake queue (bin/fm-wake-drain.sh):\n'
FM_STATE_OVERRIDE="$DIR/state" "$REPO/bin/fm-wake-drain.sh" 2>/dev/null | sed 's/^/    | /'
report_state "$DIR" "$WINDOW"
unset FM_FAKE_CREW_STATE_unconfigured

# ---------------------------------------------------------------------------
rule 'Scenario 2: same crew, same fixture - home OPTED IN (touch config/wedge-defer-pipeline)'
WINDOW=demo:fm-optedin
DIR=$(build_fixture demo-optedin "$WINDOW")
mkdir -p "$DIR/config"; : > "$DIR/config/wedge-defer-pipeline"
export FM_FAKE_CREW_STATE_optedin='state: working · source: run-step · validating (fixing) · pipeline-activity: recent'
show "crew-state verdict the watcher reads: $FM_FAKE_CREW_STATE_optedin"
show "config dir contents: $(ls -A "$DIR/config" | tr '\n' ' ')"
run_watcher "$DIR" "$WINDOW" "$DIR/config"
if wait_poll_cycle "$DIR/state" "$WATCH_PID"; then
  show 'watcher completed a full poll cycle and stayed up: the escalation was deferred'
else
  show 'FAILED: watcher escalated despite the opt-in'
fi
printf '  supervisor-visible wake output:\n'
if [ -s "$DIR/watch.out" ]; then sed 's/^/    | /' "$DIR/watch.out"; else printf '    | (nothing - no supervision turn consumed)\n'; fi
printf '  wake queue: %s\n' "$([ -s "$DIR/state/.wake-queue" ] && echo 'non-empty' || echo 'empty')"
report_state "$DIR" "$WINDOW"
reap "$WATCH_PID"
unset FM_FAKE_CREW_STATE_optedin

# ---------------------------------------------------------------------------
rule 'Scenario 3: opted-in home, pipeline withdraws its activity report'
WINDOW=demo:fm-withdrawn
DIR=$(build_fixture demo-withdrawn "$WINDOW")
mkdir -p "$DIR/config"; : > "$DIR/config/wedge-defer-pipeline"
export FM_FAKE_CREW_STATE_withdrawn='state: working · source: run-step · validating (fixing)'
show "crew-state verdict the watcher reads: $FM_FAKE_CREW_STATE_withdrawn"
run_watcher "$DIR" "$WINDOW" "$DIR/config"
if wait_for_exit "$WATCH_PID" 100; then
  show 'watcher escalated: a genuinely wedged crew is still reported'
else
  reap "$WATCH_PID"; show 'FAILED: a crew with no activity report was silenced'
fi
printf '  supervisor-visible wake output:\n'
sed 's/^/    | /' "$DIR/watch.out"
report_state "$DIR" "$WINDOW"
unset FM_FAKE_CREW_STATE_withdrawn

# ---------------------------------------------------------------------------
rule 'Scenario 4: unconfigured home, pre-existing worktree-write deferral (must be unchanged)'
WINDOW=demo:fm-writing
DIR=$(build_fixture demo-writing "$WINDOW")
mkdir -p "$DIR/config"   # empty again: the write deferral is outside the flag
printf 'int main(void) { return 1; }\n' > "$DIR/wt/src/main.c"   # a fresh write, now
export FM_FAKE_CREW_STATE_writing='state: working · source: run-step · building'
show 'crew worktree was just written; config dir is empty'
run_watcher "$DIR" "$WINDOW" "$DIR/config"
if wait_poll_cycle "$DIR/state" "$WATCH_PID"; then
  show 'watcher stayed up: the pre-existing write deferral still works with the opt-in absent'
else
  show 'FAILED: the write deferral regressed'
fi
printf '  supervisor-visible wake output:\n'
if [ -s "$DIR/watch.out" ]; then sed 's/^/    | /' "$DIR/watch.out"; else printf '    | (nothing)\n'; fi
report_state "$DIR" "$WINDOW"
reap "$WATCH_PID"
unset FM_FAKE_CREW_STATE_writing

printf '\n'

# ---------------------------------------------------------------------------
# The flag is checked BEFORE the probe, so an unconfigured home spends no
# pipeline read either. Counted by wrapping the crew-state binary the probe
# shells out to and comparing invocation counts over one poll cycle.
rule 'Scenario 5: an unconfigured home spends no extra pipeline read'
count_reads() {  # <case-name> <window> <flag on|off>
  local name=$1 window=$2 flag=$3 dir id
  dir=$(build_fixture "$name" "$window"); id=${window#*:fm-}
  mkdir -p "$dir/config"
  [ "$flag" = on ] && : > "$dir/config/wedge-defer-pipeline"
  mv "$dir/fakebin/fm-crew-state.sh" "$dir/fakebin/fm-crew-state-real.sh"
  cat > "$dir/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf 'x' >> "$dir/reads"
exec "$dir/fakebin/fm-crew-state-real.sh" "\$@"
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  : > "$dir/reads"
  export "FM_FAKE_CREW_STATE_$id=state: working · source: run-step · validating (fixing) · pipeline-activity: recent"
  run_watcher "$dir" "$window" "$dir/config"
  wait_poll_cycle "$dir/state" "$WATCH_PID" >/dev/null 2>&1 || true
  reap "$WATCH_PID"
  printf '%s' "$(wc -c < "$dir/reads" | tr -d ' ')"
  unset "FM_FAKE_CREW_STATE_$id"
}
show "crew-state reads during one stale poll, flag ABSENT:  $(count_reads demo-count-off demo:fm-countoff off)"
show "crew-state reads during one stale poll, flag PRESENT: $(count_reads demo-count-on demo:fm-counton on)"

rule 'the flag file itself is local and gitignored'
printf '    | $ git check-ignore -v config/wedge-defer-pipeline\n'
git -C "$REPO" check-ignore -v config/wedge-defer-pipeline | sed 's/^/    | /'
printf '\n'
