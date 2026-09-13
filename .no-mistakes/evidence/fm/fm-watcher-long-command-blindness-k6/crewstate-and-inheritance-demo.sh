#!/usr/bin/env bash
# Evidence demo, part 2: the other half of the opt-in gate and its inheritance.
#
#  (a) bin/fm-crew-state.sh - the `pipeline-activity: recent` marker on a working
#      run-step line is published only in a home that opted in. Same run record,
#      same crew, two homes differing only in config/wedge-defer-pipeline.
#  (b) bin/fm-config-inherit-lib.sh - the flag rides the DEFAULT inheritable set
#      into a secondmate home, so one captain choice covers the fleet.
set -u

REPO=/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2EAKA9PSK9T9CM705S1JTMT
# shellcheck source=/dev/null
. "$REPO/tests/lib.sh"                 # fm_test_tmproot, fm_write_meta, fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-crewstate-optin-evidence)
fm_git_identity fmtest fmtest@example.invalid

rule() { printf '\n== %s ==\n' "$1"; }
show() { printf '  %s\n' "$1"; }

# --- (a) crew-state marker --------------------------------------------------
CASE="$TMP_ROOT/case"; mkdir -p "$CASE/state" "$CASE/fakebin" "$CASE/config"
git -C . >/dev/null 2>&1 || true
mkdir -p "$CASE/wt"
git -C "$CASE/wt" init -q
git -C "$CASE/wt" commit -q --allow-empty -m init
git -C "$CASE/wt" checkout -q -b fm/feat-demo
HEAD_SHA=$(git -C "$CASE/wt" rev-parse HEAD)

# A fake `no-mistakes` serving one real-shaped run record: a fixing run whose
# review step reported output 8 seconds ago (the pipeline's own liveness verdict).
cat > "$CASE/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  axi)
    shift
    [ "\${1:-}" = status ] && cat <<'TOON'
run:
  id: "01RUN"
  branch: fm/feat-demo
  status: fixing
  head: "$HEAD_SHA"
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,12m3s,8s,44121,"auto-fix 1/3"
TOON
    ;;
  daemon) printf 'daemon running (pid 4242)\n'; exit 0 ;;
esac
exit 0
SH
cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$CASE/fakebin/no-mistakes" "$CASE/fakebin/tmux"
fm_write_meta "$CASE/state/feat-demo.meta" "window=fm:fm-feat-demo" "worktree=$CASE/wt" "kind=ship"

crew_state() {
  PATH="$CASE/fakebin:$PATH" FM_STATE_OVERRIDE="$CASE/state" FM_CONFIG_OVERRIDE="$CASE/config" \
    "$REPO/bin/fm-crew-state.sh" feat-demo
}

printf 'Firstmate wedge-deferral opt-in - crew-state marker and secondmate inheritance\n'
printf 'repo: %s\n' "$(git -C "$REPO" rev-parse --short HEAD)"
printf 'run record served to both homes: fixing run on fm/feat-demo, review step last produced output 8s ago\n'

rule 'bin/fm-crew-state.sh feat-demo - UNCONFIGURED home (flag absent)'
show "config dir contents: $(ls -A "$CASE/config" | tr '\n' ' ')(empty)"
printf '    | %s\n' "$(crew_state)"

rule 'bin/fm-crew-state.sh feat-demo - same run, home OPTED IN'
: > "$CASE/config/wedge-defer-pipeline"
show "config dir contents: $(ls -A "$CASE/config" | tr '\n' ' ')"
printf '    | %s\n' "$(crew_state)"

# --- (b) inheritance into a secondmate home ---------------------------------
rule 'secondmate inheritance via the DEFAULT inheritable set'
# shellcheck source=/dev/null
. "$REPO/bin/fm-config-inherit-lib.sh"
PRIMARY="$TMP_ROOT/primary-config"; SECONDMATE="$TMP_ROOT/secondmate-config"
mkdir -p "$PRIMARY" "$SECONDMATE"
: > "$PRIMARY/wedge-defer-pipeline"
show "primary home config/:    $(ls -A "$PRIMARY" | tr '\n' ' ')"
show "secondmate config/ before: $(ls -A "$SECONDMATE" | tr '\n' ' ')(empty)"
show 'running propagate_inheritable_config with the shipped FM_INHERITABLE_CONFIG default'
propagate_inheritable_config "$PRIMARY" "$SECONDMATE" || show 'propagate returned non-zero'
show "secondmate config/ after:  $(ls -A "$SECONDMATE" | tr '\n' ' ')"
if [ -e "$SECONDMATE/wedge-defer-pipeline" ]; then
  show 'the captain choice reached the secondmate home: its own watcher defers too'
else
  show 'FAILED: the flag was not inherited'
fi

# The contrapositive: a primary that never set the flag must not create it downstream.
PRIMARY2="$TMP_ROOT/primary-config-off"; SECONDMATE2="$TMP_ROOT/secondmate-config-off"
mkdir -p "$PRIMARY2" "$SECONDMATE2"
propagate_inheritable_config "$PRIMARY2" "$SECONDMATE2" || true
show "unconfigured primary -> secondmate config/: $(ls -A "$SECONDMATE2" | tr '\n' ' ')(empty)"
printf '\n'
