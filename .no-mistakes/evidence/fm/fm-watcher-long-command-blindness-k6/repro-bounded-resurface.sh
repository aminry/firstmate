#!/usr/bin/env bash
# Reviewer demo part 2: the deferral is bounded, not a silence hole. Same
# active-pipeline pane, but it has been deferring for 500s and the bounded
# re-surface cadence (FM_PAUSE_RESURFACE_SECS) is 240s.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
WATCH="$ROOT/bin/fm-watch.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-pipeline-resurface-demo)
size_of() { LC_ALL=C wc -c < "$1" | tr -d "[:space:]"; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
set_mtime() { local e=$1 f=$2 s; if s=$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null); then touch -t "$s" "$f"; else touch -t "$(date -d "@$e" +%Y%m%d%H%M.%S)" "$f"; fi; }
seen_sig() { printf 'v2\t%s\t%s@%s' "$(status_observed_signature "$1")" "$(size_of "$1")" "$(_fm_open_decisions_file_ident "$1")"; }

dir=$(make_case demo-resurface); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; drain_out="$dir/drain.out"; capture="$dir/pane.txt"
window="paseo:fm-paseo-stage1-f4"; wt="$dir/wt"; mkdir -p "$wt/src"
printf 'Running tests... (pane unchanged for 22 minutes)' > "$capture"
printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/paseo.meta"
printf 'working: handed to validation\n' > "$state/paseo.status"
printf '%s' "$(seen_sig "$state/paseo.status")" > "$state/.seen-paseo_status"
key=$(printf '%s' "$window" | tr ':/.' '___')
pane_hash=$(hash_text "Running tests... (pane unchanged for 22 minutes)")
printf '%s' "$pane_hash" > "$state/.hash-$key"; printf '1\n' > "$state/.count-$key"
printf '%s' "$pane_hash" > "$state/.stale-$key"
back=$(( $(date +%s) - 500 ))
echo "$back" > "$state/.stale-since-$key"; set_mtime "$back" "$state/.stale-since-$key"
: > "$state/.progress-since-$key"; set_mtime "$back" "$state/.progress-since-$key"
printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/main.c"
export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (fixing) · pipeline-activity: recent'
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
  FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
pid=$!; i=0
while [ "$i" -lt 100 ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; i=$((i+1)); done
reap "$pid"
FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
echo "CASE 3 - same active-pipeline pane, deferring for 500s, cadence 240s"
echo "  what firstmate is told (watcher stdout):"
sed 's/^/      /' "$out"
echo "  durable wake queue after drain:"
sed 's/^/      /' "$drain_out"
echo "  wedge escalation counter: $(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo '(none)')"
