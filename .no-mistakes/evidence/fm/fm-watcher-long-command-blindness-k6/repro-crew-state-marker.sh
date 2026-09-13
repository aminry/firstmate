#!/usr/bin/env bash
# Reviewer repro: the real bin/fm-crew-state.sh verdict line, driven by the real
# `axi status` TOON reader over the suite's fake axi.
#
# To run: copy this file into <tree>/tests/, then build the fixture prelude from
# the suite's own helper region (everything before its first test function):
#     sed -n '1,518p' tests/fm-crew-state.test.sh > tests/fm-crewstate-prelude.inc.sh
# then: bash tests/fm-crewstate-marker-demo.sh
set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-crewstate-prelude.inc.sh"

show() {  # <title> <id> <case-dir>
  printf '%s\n' "$1"
  printf '  bin/fm-crew-state.sh %s ->\n      %s\n\n' "$2" "$(run_crew_state "$3" "$2")"
}

echo "=== real bin/fm-crew-state.sh output, driven by real \`axi status\` TOON ==="
echo

reset_fakes
d=$(new_case demo-recent); make_repo_on_branch "$d/wt" fm/feat-pa >/dev/null 2>&1
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/feat-pa.meta" "window=fm:fm-feat-pa" "worktree=$d/wt" "kind=ship"
FM_FAKE_AXI_STATUS="$(run_fixing_active_recent fm/feat-pa)"
show "A. this crew's own run, step producing output 8s ago (active_steps last_activity=8s)" feat-pa "$d"

FM_FAKE_AXI_STATUS="$(run_fixing_active_quiet fm/feat-pa)"
show "B. the SAME run gone quiet (last_activity=\"quiet 31m2s\") - step may really be dead" feat-pa "$d"

reset_fakes
d=$(new_case demo-coarse); make_repo_on_branch "$d/wt" fm/feat-coarse >/dev/null 2>&1
short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/feat-coarse.meta" "window=fm:fm-feat-coarse" "worktree=$d/wt" "kind=ship"
FM_FAKE_AXI_STATUS="$(run_fixing_active_recent fm/other-crew)"
FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarse ${short}  2026-07-02 22:05
EOF
)"
show "C. ANOTHER crew (fm/other-crew) is the freshest run and is active; this crew's own row comes from the coarse ledger" feat-coarse "$d"
