#!/usr/bin/env bash
# Live end-to-end driver for the declared-wait wedge deferral (kunchenguid/firstmate#3909, #2614).
#
# Stands up a real firstmate state home, a real crewmate window record and status
# file, and runs the REAL bin/fm-watch.sh watcher process against it. The only
# things faked are the terminal backend (tmux) and the crew-state probe, exactly
# the two external systems the watcher shells out to. Everything else - the wake
# queue, the triage log, the per-window markers, the wake wording - is production
# code writing production state.
#
# Usage: live-wedge-drive.sh <repo-root> <output-dir>
set -u

ROOT=${1:?repo root}
OUT=${2:?output dir}
WATCH="$ROOT/bin/fm-watch.sh"
umask 022
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-wedge.XXXXXX")
export FM_ROOT_OVERRIDE="$WORK/not-a-git-repo"; mkdir -p "$FM_ROOT_OVERRIDE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/alarm-sink"; chmod +x "$WORK/alarm-sink"
export FM_WEDGE_ALARM_EXEC="$WORK/alarm-sink"
WINDOW="fleet:fm-crew-validate"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
PANE_TEXT='validating: whole-assembly baseline'

FAILURES=0
note() { printf '%s\n' "$*"; }
check() {  # <description> <0|1 result>
  if [ "$2" -eq 0 ]; then printf '    PASS  %s\n' "$1"
  else printf '    FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); fi
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d' ' -f1; fi
}
set_mtime() {  # <epoch> <file>
  local stamp
  if stamp=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null); then touch -t "$stamp" "$2"
  else touch -t "$(date -d "@$1" +%Y%m%d%H%M.%S)" "$2"; fi
}
iso_utc_at() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# A firstmate home whose crewmate pane is already stably stale at its recorded
# hash - the exact population wedge_timer_check owns - with <status-line> as the
# worker's own last word, written <age> seconds ago.
make_home() {  # <name> <status-line> <status-age-secs>
  local name=$1 line=$2 age=$3 home state fakebin
  home="$WORK/$name"; state="$home/state"; fakebin="$home/fakebin"
  mkdir -p "$state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0 ;;
  capture-pane) cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
  display-message) case "$*" in *pane_current_command*) printf 'grok\n'; exit 0 ;; esac ;;
esac
exit 1
SH
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown}"
SH
  chmod +x "$fakebin/tmux" "$fakebin/fm-crew-state.sh"
  printf '%s' "$PANE_TEXT" > "$home/pane.txt"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$WINDOW" > "$state/validate.meta"
  printf '%s\n' "$line" > "$state/validate.status"
  set_mtime "$(( $(date +%s) - age ))" "$state/validate.status"
  # Prime the already-seen suppressor through the production signature owner, so
  # the pre-existing status line does not fire a first-sight signal wake.
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$state/validate.status" >/dev/null
  printf '%s' "$(hash_text "$PANE_TEXT")" > "$state/.hash-$KEY"
  printf '1\n' > "$state/.count-$KEY"
  printf '%s' "$(hash_text "$PANE_TEXT")" > "$state/.stale-$KEY"
  printf '%s\n' "$home"
}

# Run the real watcher against <home> for one idle window past the escalation
# threshold. mode=exit expects it to surface and exit (an actionable wake);
# mode=absorb expects it to survive three whole poll cycles at the threshold.
run_watcher() {  # <home> <mode> [resurface-secs]
  local home=$1 mode=$2 resurface=${3:-999}
  local state pid i=0 beat first now cycles
  state="$home/state"
  PATH="$home/fakebin:$PATH" \
    FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$home/pane.txt" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="$resurface" FM_STALE_ESCALATE_SECS=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" >> "$home/watch.out" 2>> "$home/watch.err" &
  pid=$!
  beat="$state/.last-watcher-beat"
  if [ "$mode" = exit ]; then
    while [ "$i" -lt 150 ]; do kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }; sleep 0.1; i=$((i+1)); done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1
  fi
  cycles=0
  while [ "$cycles" -lt 3 ]; do
    rm -f "$beat"; first=""; i=0
    while [ "$i" -lt 300 ]; do
      kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 1; }
      first=$(stat -f %m "$beat" 2>/dev/null || stat -c %Y "$beat" 2>/dev/null || true)
      [ -n "$first" ] && break; sleep 0.1; i=$((i+1))
    done
    while [ "$i" -lt 300 ]; do
      kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 1; }
      now=$(stat -f %m "$beat" 2>/dev/null || stat -c %Y "$beat" 2>/dev/null || true)
      [ -n "$now" ] && [ "$now" != "$first" ] && break
      sleep 0.1; i=$((i+1))
    done
    [ "$i" -lt 300 ] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; }
    cycles=$((cycles + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0
}

# Acknowledge the durable wake queue so the next watcher round starts clean.
ack() {  # <state>
  local state=$1 err seq gen
  err="$state/.ack.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}

stale_wakes() { awk -F '\t' -v w="$WINDOW" '$3=="stale" && $4==w {n++} END {print n+0}' "$1/.wake-queue" 2>/dev/null || echo 0; }

banner() { printf '\n========================================================================\n%s\n========================================================================\n' "$*"; }

printf 'live driver for the declared-wait wedge deferral\n'
printf 'watcher under test : %s\n' "$WATCH"
printf 'watcher commit     : %s\n' "$(cd "$ROOT" && git rev-parse --short HEAD)"
printf 'crewmate window    : %s\n' "$WINDOW"
printf 'wedge threshold    : FM_STALE_ESCALATE_SECS=1 (the 240s default only changes how long each round takes)\n'

# ---------------------------------------------------------------- scenario 1
banner 'S1  a crewmate that declared a bounded wait is not wedge-escalated (#3909)'
H=$(make_home s1-declared-wait 'paused: final validation at step 6/6 - clean whole-assembly baseline (~20 min)' 0)
note "crewmate's own last status line:"
note "    $(cat "$H/state/validate.status")"
note 'driving three consecutive idle windows past the escalation threshold...'
r=0; n=1
while [ "$n" -le 3 ]; do
  run_watcher "$H" absorb || r=1
  n=$((n + 1))
done
check 'watcher stayed supervising across three thresholds (never surfaced a wedge)' "$r"
[ "$(stale_wakes "$H/state")" -eq 0 ]; check 'no stale wake queued for the captain' $?
! grep -qF 'possible wedge' "$H/watch.out"; check 'nothing reported as a possible wedge' $?
[ ! -e "$H/state/.wedge-escalations-$KEY" ]; check 'no wedge escalation counted' $?
note 'what the watcher recorded instead (triage log):'
sed -n 's/^/    /p' "$H/state/.watch-triage.log" | grep -F 'wait explains the quiet' | tail -3
cp "$H/state/.watch-triage.log" "$OUT/s1-declared-wait.triage.log" 2>/dev/null || true

# ---------------------------------------------------------------- scenario 2
banner 'S2  the declared wait is rechecked on the long cadence, naming the external dependency'
H=$(make_home s2-declared-recheck 'paused: waiting on the upstream release cut' 2000)
note "crewmate's own last status line (declared 2000s ago):"
note "    $(cat "$H/state/validate.status")"
run_watcher "$H" exit 240; check 'watcher surfaced the recheck once the wait outlived the cadence' $?
note 'what the captain sees:'
sed -n 's/^/    /p' "$H/watch.out"
grep -qF 'declared wait, awaiting external' "$H/watch.out"; check 'recheck names the wait as declared and owed by an external dependency' $?
grep -qF 'confirm the wait still holds' "$H/watch.out"; check 'recheck names the action that resolves it' $?
grep -qF 'rechecked on a long cadence not a wedge' "$H/watch.out"; check 'recheck is worded as a recheck, not a wedge' $?
! grep -qF 'possible wedge' "$H/watch.out"; check 'no possible-wedge wording' $?
! grep -qF 'release the hold' "$H/watch.out"; check 'did not borrow the captain-held action' $?
w=$(sed -n 's/.*waiting \([0-9][0-9]*\)s.*/\1/p' "$H/watch.out" | head -1)
[ -n "$w" ] && [ "$w" -ge 1900 ]; check "published wait age (${w}s) is the age of the declaration itself" $?
cp "$H/watch.out" "$OUT/s2-declared-recheck.wake.txt"

# ---------------------------------------------------------------- scenario 3
banner 'S3  ADVERSARIAL: a lane with no declaration keeps the unchanged ladder and wording'
H=$(make_home s3-no-declaration 'working: validation under way' 0)
note "crewmate's own last status line (no declared wait):"
note "    $(cat "$H/state/validate.status")"
n=1; r=0
while [ "$n" -le 3 ]; do
  run_watcher "$H" exit || r=1
  ack "$H/state" || r=1
  grep -qF "possible wedge, escalation $n" "$H/watch.out" || r=1
  n=$((n + 1))
done
check 'escalated on every threshold, escalation 1 -> 2 -> 3, on the unchanged schedule' "$r"
grep -qF 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$H/watch.out"
check 'demand-deep-inspection wording intact at the third escalation' $?
note 'what the captain sees:'
sed -n 's/^/    /p' "$H/watch.out"
cp "$H/watch.out" "$OUT/s3-no-declaration.wake.txt"

# ---------------------------------------------------------------- scenario 4
banner 'S4  ADVERSARIAL: a declared wait whose own clearing time already passed escalates as before'
PAST=$(iso_utc_at "$(( $(date +%s) - 7200 ))")
H=$(make_home s4-elapsed-until "paused: waiting on the build queue until $PAST" 0)
note "crewmate's own last status line (clearing time two hours in the past):"
note "    $(cat "$H/state/validate.status")"
run_watcher "$H" exit; check 'watcher surfaced rather than deferring an expired declaration' $?
note 'what the captain sees:'
sed -n 's/^/    /p' "$H/watch.out"
grep -qF 'possible wedge, escalation 1' "$H/watch.out"; check 'unchanged wedge wording and escalation count' $?
cp "$H/watch.out" "$OUT/s4-elapsed-until.wake.txt"

# ---------------------------------------------------------------- scenario 5
banner 'S5  a captain-held transfer is rechecked as a hold ON THE CAPTAIN, not an external wait'
H=$(make_home s5-captain-held 'captain-held: which retention window wins' 2000)
note "crewmate's own last status line:"
note "    $(cat "$H/state/validate.status")"
run_watcher "$H" exit 240; check 'watcher surfaced the hold recheck' $?
note 'what the captain sees:'
sed -n 's/^/    /p' "$H/watch.out"
grep -qF 'awaiting the captain' "$H/watch.out"; check 'recheck names the captain as the human the wait is on' $?
grep -qF 'answer the held decision or release the hold' "$H/watch.out"; check 'recheck names the action that clears the hold' $?
! grep -qF 'awaiting external' "$H/watch.out"; check 'not published as a wait on an external dependency' $?
! grep -qF 'possible wedge' "$H/watch.out"; check 'not reported as a possible wedge' $?
cp "$H/watch.out" "$OUT/s5-captain-held.wake.txt"

# ---------------------------------------------------------------- scenario 6
banner 'S6  ADVERSARIAL: while the captain is away a hold is silent, and the recheck returns intact'
H=$(make_home s6-held-away 'captain-held: which retention window wins' 2000)
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$ROOT/bin/fm-afk-contract.sh" propose >/dev/null 2>&1
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null 2>&1
note 'away-posture record written; driving three idle windows past the threshold...'
r=0; n=1
while [ "$n" -le 3 ]; do run_watcher "$H" absorb 240 || r=1; n=$((n + 1)); done
check 'watcher stayed supervising, never woke the away captain' "$r"
[ "$(stale_wakes "$H/state")" -eq 0 ]; check 'no stale wake queued' $?
[ ! -s "$H/watch.out" ]; check 'nothing printed to the captain' $?
[ ! -e "$H/state/.waiting-resurfaced-$KEY" ]; check 'no recheck throttle armed, so the recheck is owed in full on return' $?
note 'what the watcher recorded instead (triage log):'
grep -F 'never rechecked while the away-posture record exists' "$H/state/.watch-triage.log" | sed -n 's/^/    /p' | tail -2
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1
note 'away-posture record archived (captain is back); driving one more idle window...'
: > "$H/watch.out"
run_watcher "$H" exit 240; check 'the hold was rechecked immediately on return, not after another cadence' $?
note 'what the returning captain sees:'
sed -n 's/^/    /p' "$H/watch.out"
grep -qF 'awaiting the captain' "$H/watch.out"; check 'the recheck owed on return still names the captain' $?
cp "$H/watch.out" "$OUT/s6-held-away-return.wake.txt"
cp "$H/state/.watch-triage.log" "$OUT/s6-held-away.triage.log" 2>/dev/null || true


# ---------------------------------------------------------------- scenario 7
banner 'S7  ADVERSARIAL: the declaration still wins when the pane display churns every capture'
H=$(make_home s7-churning-pane 'paused: waiting on the nightly index rebuild' 0)
# A ticking clock / token counter: every capture renders different text, so the
# pane hash changes on every poll. This is the bound the change states openly -
# the recheck throttle is hash-scoped, so such a lane is rechecked once per idle
# window rather than on the long cadence. What must NOT survive is the wedge
# ladder: no escalation, no demand-deep-inspection.
cat > "$H/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0 ;;
  capture-pane)
    c=$(cat "$FM_FAKE_TMUX_CAPTURE.tick" 2>/dev/null || echo 0)
    printf '%s\n' "$((c + 1))" > "$FM_FAKE_TMUX_CAPTURE.tick"
    printf 'validating: whole-assembly baseline  [%s tokens]\n' "$((c * 137))"
    exit 0 ;;
  display-message) case "$*" in *pane_current_command*) printf 'grok\n'; exit 0 ;; esac ;;
esac
exit 1
SH
chmod +x "$H/fakebin/tmux"
note "crewmate's own last status line:"
note "    $(cat "$H/state/validate.status")"
note 'driving six idle windows against a pane whose text changes on every capture...'
n=1
while [ "$n" -le 6 ]; do
  run_watcher "$H" exit 240 >/dev/null 2>&1 || true
  ack "$H/state" >/dev/null 2>&1 || true
  n=$((n + 1))
done
! grep -qF 'possible wedge' "$H/watch.out"; check 'a churning declared-wait lane is never reported as a possible wedge' $?
! grep -qF 'demand-deep-inspection' "$H/watch.out"; check 'no demand-deep-inspection marker' $?
[ ! -e "$H/state/.wedge-escalations-$KEY" ]; check 'no wedge escalation counted' $?
note 'what the captain sees (the stated bound: rechecked once per idle window, never escalated):'
sort -u "$H/watch.out" | sed -n 's/^/    /p' | head -6
cp "$H/watch.out" "$OUT/s7-churning-pane.wake.txt"

# ---------------------------------------------------------------- scenario 8
banner 'S8  ADVERSARIAL: withdrawing the declaration restores the unchanged escalation'
H=$(make_home s8-lifted-declaration 'paused: waiting on the upstream release cut' 0)
note "crewmate's own last status line:"
note "    $(cat "$H/state/validate.status")"
run_watcher "$H" absorb; check 'while the wait stands the lane is deferred, not escalated' $?
! grep -qF 'possible wedge' "$H/watch.out"; check 'nothing reported as a possible wedge while the wait stands' $?
note 'the crewmate withdraws the wait and reports working again:'
printf 'working: the release landed, resuming validation\n' >> "$H/state/validate.status"
note "    $(tail -1 "$H/state/validate.status")"
FM_STATE_OVERRIDE="$H/state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$H/state" "$H/state/validate.status" >/dev/null
: > "$H/watch.out"
run_watcher "$H" exit; check 'the very next idle window escalates again' $?
note 'what the captain sees:'
sed -n 's/^/    /p' "$H/watch.out"
grep -qF 'possible wedge, escalation 1' "$H/watch.out"; check 'unchanged wedge wording, escalation count starting from 1' $?
cp "$H/watch.out" "$OUT/s8-lifted-declaration.wake.txt"

banner "RESULT: $FAILURES check(s) failed"
rm -rf "$WORK"
[ "$FAILURES" -eq 0 ]
