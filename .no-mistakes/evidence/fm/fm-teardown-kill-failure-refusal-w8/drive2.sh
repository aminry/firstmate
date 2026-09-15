#!/usr/bin/env bash
set -u
export FM_GATE_REFUSE_BYPASS=1
WT=/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2HP1H8ZGN90K5AEEN2QP4PY
SCRATCH=/tmp/fm-e2e-01M2HP/run2
REAL_TMUX=$(command -v tmux)
NOTMUX=/tmp/fm-e2e-01M2HP/run/pathsans
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

mk_case() { local d="$SCRATCH/$1"; mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/project"; git init -q "$d/project"; printf '%s\n' "$d"; }
meta() { printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' "$3" "$2" "$1/nonexistent-worktree" "$1/nonexistent-project" > "$1/home/state/$2.meta"; }
hdr() { printf '\n================ %s ================\n' "$*"; }
# shim: real tmux pinned to the isolated socket; BLOCK_KILL makes kill-window alone fail
mk_shim() { local d=$1 sock=$2; mkdir -p "$d/shimbin"; cat > "$d/shimbin/tmux" <<SH
#!/usr/bin/env bash
if [ -n "\${BLOCK_KILL:-}" ] && [ "\${1:-}" = kill-window ]; then echo "can't find window" >&2; exit 1; fi
cd '$d'
exec '$REAL_TMUX' -S '$sock' "\$@"
SH
chmod +x "$d/shimbin/tmux"; printf '%s\n' "$d/shimbin"; }
windows() { ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "=$3" -F '  #{window_name}' 2>&1 ); }
record() { ls -A "$1/home/state" 2>/dev/null | tr '\n' ' '; echo; }

######################################################################
hdr "SCENARIO C - recorded window already exited: ordinary cleanup must stay silent"
D=$(mk_case C); S=s.sock; SESS=crew; ID=gone-task
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-session -d -s "$SESS" -n control )
SHIM=$(mk_shim "$D" "$S")
meta "$D" "$ID" "$SESS:fm-$ID"
echo "before windows:"; windows "$D" "$S" "$SESS"
echo "\$ bin/fm-teardown.sh $ID"
env -u TMUX -u TMUX_PANE FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$SHIM:$NOTMUX" "$WT/bin/fm-teardown.sh" "$ID" 2>&1 | grep -v '^●\|WATCHER\|^WARNING'
echo "exit=${PIPESTATUS[0]}"
echo "state dir after: $(record "$D")"
( cd "$D" && "$REAL_TMUX" -S "$S" kill-server 2>/dev/null )

######################################################################
hdr "SCENARIO D - close fails, re-read shows the window STILL PRESENT (adversarial: close accepted-then-failed)"
D=$(mk_case D); ID=survivor-task; SESS=crew
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-session -d -s "$SESS" -n control )
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-window -d -t "=$SESS:" -n "fm-$ID" )
SHIM=$(mk_shim "$D" "$S")
meta "$D" "$ID" "$SESS:fm-$ID"
echo "\$ bin/fm-teardown.sh $ID     (kill-window blocked, window really alive)"
env -u TMUX -u TMUX_PANE BLOCK_KILL=1 FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$SHIM:$NOTMUX" "$WT/bin/fm-teardown.sh" "$ID" 2>&1 | grep -v '^●\|WATCHER\|^WARNING'
echo "exit=${PIPESTATUS[0]}"
echo "state dir after: $(record "$D")"
echo "windows after:"; windows "$D" "$S" "$SESS"

hdr "SCENARIO E - SAME failure, operator passes --force (generic tmux site)"
echo "\$ bin/fm-teardown.sh $ID --force"
env -u TMUX -u TMUX_PANE BLOCK_KILL=1 FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$SHIM:$NOTMUX" "$WT/bin/fm-teardown.sh" "$ID" --force 2>&1 | grep -v '^●\|WATCHER\|^WARNING'
echo "exit=${PIPESTATUS[0]}"
echo "state dir after: $(record "$D")"
echo "windows after:"; windows "$D" "$S" "$SESS"

######################################################################
hdr "SCENARIO F - adversarial exactness: recorded window gone, PREFIX NEIGHBOUR alive, kill blocked"
D2=$(mk_case F); ID2=fm-prefix-demo
( cd "$D2" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-session -d -s prefixsess -n control )
( cd "$D2" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-window -d -t "=prefixsess:" -n "fm-neighbour-extra" )
SHIM2=$(mk_shim "$D2" "$S")
meta "$D2" "$ID2" "prefixsess:fm-neighbour"
echo "live windows (recorded target fm-neighbour does NOT exist):"; windows "$D2" "$S" prefixsess
echo "\$ bin/fm-teardown.sh $ID2     (kill-window blocked)"
env -u TMUX -u TMUX_PANE BLOCK_KILL=1 FM_HOME="$D2/home" FM_ROOT_OVERRIDE="$WT" PATH="$SHIM2:$NOTMUX" "$WT/bin/fm-teardown.sh" "$ID2" 2>&1 | grep -v '^●\|WATCHER\|^WARNING'
echo "exit=${PIPESTATUS[0]}"
echo "state dir after: $(record "$D2")"
echo "windows after (neighbour must be untouched):"; windows "$D2" "$S" prefixsess
( cd "$D2" && "$REAL_TMUX" -S "$S" kill-server 2>/dev/null )
