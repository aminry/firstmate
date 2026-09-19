#!/usr/bin/env bash
# Transient end-to-end driver (not committed): drives the REAL watcher against
# the REAL bin/fm-crew-state.sh, which reads a documented-format
# `no-mistakes axi status` gate payload. Only `no-mistakes` itself is faked.
set -u

here=$(cd "$(dirname "$0")" && pwd)
first=$(grep -n "^test_[a-z_0-9]*$" "$here/fm-watch-triage.test.sh" | head -1 | cut -d: -f1)
head -n $((first - 1)) "$here/fm-watch-triage.test.sh" > "$here/.tmp-e2e-defs.sh"
# shellcheck source=/dev/null
. "$here/.tmp-e2e-defs.sh"
rm -f "$here/.tmp-e2e-defs.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"

say() { printf '\n=== %s ===\n' "$*"; }

# A realistic gate payload, shaped like the one `no-mistakes axi status` prints
# (docs: run object + gate + note + findings table + help list).
payload_human() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUNGATE"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 41m12s
  head: "$2"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,internal/pipeline/executor.go,,auto-fix,Error from os.Remove is ignored
    r2,error,cmd/no-mistakes/main.go,,ask-user,New --force flag bypasses the confirm prompt
gate: review
note: Review auto-fix is disabled by default, so blocking and ask-user review findings park for your decision.
help[3]:
  Run \`no-mistakes axi respond --action approve\` to accept this step and continue
  Run \`no-mistakes axi respond --action fix --findings <ids>\` to have the pipeline fix the selected findings
  Run \`no-mistakes axi respond --action skip\` to skip this step
EOF
}

# The same gate shape, but every action column is auto-fix: this one is owed the
# CREWMATE's own answer. The free-text description and the help list both carry
# the literal token `ask-user`.
payload_crewmate() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUNGATE"
  branch: $1
  status: fix_review
  awaiting_agent: parked 41m12s
  head: "$2"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,internal/pipeline/executor.go,,auto-fix,the action column is one of no-op, auto-fix, ask-user, so pick one
    r2,warning,cmd/no-mistakes/main.go,,auto-fix,Error from os.Remove is ignored
gate: review
help[2]:
  Run \`no-mistakes axi respond --action fix --findings <ids>\` to have the pipeline fix the selected findings
  Stop and escalate an ask-user finding to the user before responding
EOF
}

# The same gate with the findings columns REORDERED: the action column moves, so
# a parse that assumed a fixed position would read the wrong field.
payload_reordered() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUNGATE"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 41m12s
  head: "$2"
  pr: ""
  findings[2]{severity,action,id,file,line,description}:
    warning,auto-fix,r1,internal/pipeline/executor.go,,Error from os.Remove is ignored
    error,ask-user,r2,cmd/no-mistakes/main.go,,New --force flag bypasses the confirm prompt
gate: review
EOF
}

# A header that puts the free-text description BEFORE action, with a description
# that carries a literal `, ask-user,`. Walking commas to the action index is not
# sound here, so the derivation must refuse rather than mint the marker.
payload_freetext_first() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUNGATE"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 41m12s
  head: "$2"
  pr: ""
  findings[1]{id,severity,file,line,description,action}:
    r1,warning,a.go,12,one of auto-fix, ask-user,auto-fix
gate: review
EOF
}

# Build a crew-state fixture and a wrapper the watcher can call as
# FM_CREW_STATE_BIN: the wrapper runs the REAL fm-crew-state.sh against it.
make_live_crew_state() {  # <dir> <branch> <payload-fn> -> writes <dir>/crew-state-wrapper
  local dir=$1 branch=$2 fn=$3 wt="$1/wt" cstate="$1/cstate" fb="$1/nmbin" head
  mkdir -p "$wt" "$cstate" "$fb"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b "$branch"
  head=$(git -C "$wt" rev-parse HEAD)
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    if [ "${2:-}" = status ]; then cat "$FM_FAKE_AXI_STATUS_FILE"; else cat "$FM_FAKE_AXI_HOME_FILE"; fi ;;
  daemon) printf 'daemon running (pid 4242)\n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes"
  "$fn" "$branch" "$head" > "$dir/axi-status.txt"
  # The home overview, shaped like the real `no-mistakes axi` output.
  {
    printf 'repo: %s\ncurrent_branch: %s\ndaemon: running\n' "$wt" "$branch"
    printf 'count: 1 of 1 total\n'
    printf 'runs[1]{id,branch,status,head,pr}:\n'
    printf '  "01RUNGATE",%s,running,%s,""\n' "$branch" "${head:0:8}"
  } > "$dir/axi-home.txt"
  fm_write_meta "$cstate/gatecrew.meta" "window=fm:fm-gatecrew" "worktree=$wt" "kind=ship"
  printf 'working: validation under way\n' > "$cstate/gatecrew.status"
  cat > "$dir/crew-state-wrapper" <<SH
#!/usr/bin/env bash
set -u
export PATH="$fb:\$PATH"
export NM_HOME="$dir/nm-home-unused"
export FM_FAKE_AXI_STATUS_FILE="$dir/axi-status.txt"
export FM_FAKE_AXI_HOME_FILE="$dir/axi-home.txt"
export FM_STATE_OVERRIDE="$cstate"
exec "$CREW_STATE" gatecrew
SH
  chmod +x "$dir/crew-state-wrapper"
}

rc=0
note_fail() { printf 'FAIL: %s\n' "$*"; rc=1; }
expect() {  # <file> <text>
  grep -F "$2" "$1" >/dev/null || note_fail "missing from watcher output: $2"
}
refute() {  # <file> <text>
  grep -F "$2" "$1" >/dev/null && note_fail "unexpected in watcher output: $2"
  return 0
}

escalated='needs-decision [key=nm-01RUNGATE-review]: the gate raised an authority question
working: still parked at that gate'
unrelated='needs-decision [key=earlier-question]: which changelog section fits
working: still parked at that gate'
answered='needs-decision [key=nm-01RUNGATE-review]: the gate raised an authority question
resolved [key=nm-01RUNGATE-review]: approved, relay it
working: still parked at that gate'

window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

drive() {  # <case> <status-log> <payload-fn> <branch> <mode> -> echoes case dir
  local name=$1 log=$2 fn=$3 branch=$4 mode=$5 dir state
  dir=$(wedge_threshold_fixture "$name" "$log" 2000)
  make_live_crew_state "$dir" "$branch" "$fn"
  state="$dir/state"
  cp "$dir/crew-state-wrapper" "$dir/fakebin/fm-crew-state.sh"
  wedge_threshold_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" \
    "$window" 'unused-fake-verdict' "$mode" || note_fail "$name: watcher round did not complete"
  printf '%s\n' "$dir"
}

# Optional: point WATCH/CREW_STATE at a checkout of another commit's bin/,
# so the same scenario can be driven against the pre-fix watcher.
if [ -n "${E2E_BIN_OVERRIDE:-}" ]; then
  WATCH="$E2E_BIN_OVERRIDE/fm-watch.sh"
  CREW_STATE="$E2E_BIN_OVERRIDE/fm-crew-state.sh"
  printf 'driving bin/ from: %s\n' "$E2E_BIN_OVERRIDE"
fi

say 'crew-state verdict the REAL script derives from the human-owed gate payload'
d=$(drive live-human-owed "$escalated" payload_human fm/gate-human exit)
"$d/crew-state-wrapper"
say 'what the watcher did with that lane (real bin/fm-watch.sh output)'
cat "$d/watch.out"
expect "$d/watch.out" 'verified wait at a parked gate'
expect "$d/watch.out" "awaiting firstmate's ask-user decision"
expect "$d/watch.out" "decide the gate's ask-user finding and relay the decision to the crewmate"
refute "$d/watch.out" 'possible wedge'
refute "$d/watch.out" 'awaiting the captain'
[ -e "$d/state/.wedge-escalations-$key" ] && note_fail 'human-owed gate counted a wedge escalation'
ack_stopped_cycle "$d/state" || note_fail 'could not ack the parked-gate recheck'

say 'the reported bug: repeated thresholds on the same correctly-parked lane'
n=1
while [ "$n" -le 4 ]; do
  wedge_threshold_round "$d/state" "$d/fakebin" "$d/watch.out" "$d/pane.txt" \
    "$window" 'unused-fake-verdict' absorb || note_fail "repeat round $n did not complete"
  n=$((n + 1))
done
printf 'wedge escalations counted for this lane: %s\n' "$(cat "$d/state/.wedge-escalations-$key" 2>/dev/null || echo 0)"
printf 'wedge wake payloads queued: %s\n' "$(wedge_stale_wakes "$d/state" "$window")"
grep -c 'possible wedge' "$d/watch.out" | sed 's/^/possible-wedge lines in watcher output: /'
[ -e "$d/state/.wedge-escalations-$key" ] && note_fail 'a correctly-parked lane kept counting wedge escalations'

say 'crew-state verdict for the CREWMATE-owed gate (ask-user only as free text)'
d=$(drive live-crewmate-owed "$escalated" payload_crewmate fm/gate-crewmate exit)
"$d/crew-state-wrapper"
say 'watcher output for the crewmate-owed lane'
cat "$d/watch.out"
expect "$d/watch.out" 'possible wedge, escalation 1'
refute "$d/watch.out" 'verified wait at a parked gate'

say 'human-owed gate, but the only open decision names another key'
d=$(drive live-unrelated-key "$unrelated" payload_human fm/gate-human exit)
say 'watcher output (ladder must be kept)'
cat "$d/watch.out"
expect "$d/watch.out" 'possible wedge, escalation 1'
refute "$d/watch.out" 'verified wait at a parked gate'

say 'human-owed gate whose decision was already ANSWERED (fold closed)'
d=$(drive live-answered "$answered" payload_human fm/gate-human exit)
say 'watcher output (ladder must be kept)'
cat "$d/watch.out"
expect "$d/watch.out" 'possible wedge, escalation 1'
refute "$d/watch.out" 'verified wait at a parked gate'

say 'human-owed gate under the AWAY-posture record (firstmate still owes it)'
dir=$(wedge_threshold_fixture live-away "$escalated" 2000)
make_live_crew_state "$dir" fm/gate-human payload_human
cp "$dir/crew-state-wrapper" "$dir/fakebin/fm-crew-state.sh"
write_away_record "$dir/state"
wedge_threshold_round "$dir/state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" \
  "$window" 'unused-fake-verdict' exit || note_fail 'away round did not complete'
cat "$dir/watch.out"
expect "$dir/watch.out" "awaiting firstmate's ask-user decision"
refute "$dir/watch.out" 'possible wedge'
grep -F 'never rechecked while the away-posture record exists' "$dir/state/.watch-triage.log" >/dev/null \
  && note_fail 'a firstmate-owed gate took the captain-away silence'
say 'triage log for the away-posture lane'
cat "$dir/state/.watch-triage.log"

say 'adversarial: the findings table with its columns REORDERED'
d=$(drive live-reordered "$escalated" payload_reordered fm/gate-human exit)
"$d/crew-state-wrapper"
cat "$d/watch.out"
expect "$d/watch.out" "awaiting firstmate's ask-user decision"
refute "$d/watch.out" 'possible wedge'

say 'adversarial: free text before the action column, description carrying ", ask-user,"'
d=$(drive live-freetext-first "$escalated" payload_freetext_first fm/gate-human exit)
"$d/crew-state-wrapper"
cat "$d/watch.out"
expect "$d/watch.out" 'possible wedge, escalation 1'
refute "$d/watch.out" 'verified wait at a parked gate'

if [ "$rc" -eq 0 ]; then printf '\nALL LIVE SCENARIOS PASSED\n'; else printf '\nLIVE SCENARIOS FAILED\n'; fi
exit "$rc"
