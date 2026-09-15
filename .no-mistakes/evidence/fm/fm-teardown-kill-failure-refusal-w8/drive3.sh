#!/usr/bin/env bash
set -u
export FM_GATE_REFUSE_BYPASS=1
WT=/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2HP1H8ZGN90K5AEEN2QP4PY
SCRATCH=/tmp/fm-e2e-01M2HP/run3
REAL_TMUX=$(command -v tmux)
NOTMUX=/tmp/fm-e2e-01M2HP/run/pathsans
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
mk_case() { local d="$SCRATCH/$1"; mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/project"; git init -q "$d/project"; printf '%s\n' "$d"; }
hdr() { printf '\n================ %s ================\n' "$*"; }
mk_shim() { local d=$1 sock=$2; mkdir -p "$d/shimbin"; cat > "$d/shimbin/tmux" <<SH
#!/usr/bin/env bash
if [ -n "\${BLOCK_KILL:-}" ] && [ "\${1:-}" = kill-window ]; then echo "can't find window" >&2; exit 1; fi
cd '$d'
exec '$REAL_TMUX' -S '$sock' "\$@"
SH
chmod +x "$d/shimbin/tmux"; printf '%s\n' "$d/shimbin"; }
windows() { ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "=$3" -F '  #{window_name}' 2>&1 ); }
record() { ls -A "$1" 2>/dev/null | tr '\n' ' '; echo; }
S=s.sock

hdr "SCENARIO F - adversarial exactness: recorded window gone, PREFIX NEIGHBOUR alive, kill blocked"
D=$(mk_case F); ID=neighbour
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-session -d -s prefixsess -n control )
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-window -d -t "=prefixsess:" -n "fm-${ID}-extra" )
SHIM=$(mk_shim "$D" "$S")
printf 'window=prefixsess:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' "$ID" "$ID" "$D/nonexistent-worktree" "$D/nonexistent-project" > "$D/home/state/$ID.meta"
echo "live windows (recorded target fm-$ID does NOT exist; only its prefix neighbour does):"; windows "$D" "$S" prefixsess
echo "\$ bin/fm-teardown.sh $ID     (kill-window blocked)"
env -u TMUX -u TMUX_PANE BLOCK_KILL=1 FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$SHIM:$NOTMUX" "$WT/bin/fm-teardown.sh" "$ID" 2>&1 | grep -v '^●\|WATCHER\|^WARNING'
echo "exit=${PIPESTATUS[0]}"
echo "state dir after: $(record "$D/home/state")"
echo "windows after (neighbour must be untouched):"; windows "$D" "$S" prefixsess
( cd "$D" && "$REAL_TMUX" -S "$S" kill-server 2>/dev/null )

hdr "SCENARIO G - Orca task record, 'orca' CLI absent, operator uses --force"
D=$(mk_case G); ID=orca-strand
printf 'window=fm-%s\nendpoint_task_id=%s\nterminal=term-7\nworktree=%s\nproject=%s\nbackend=orca\norca_worktree_id=worktree-9\nkind=ship\nmode=no-mistakes\n' \
  "$ID" "$ID" "$D/nonexistent-worktree" "$D/nonexistent-project" > "$D/home/state/$ID.meta"
command -v orca >/dev/null && echo "NOTE: orca exists on this host" || echo "(host has no orca CLI at all)"
echo "\$ bin/fm-teardown.sh $ID --force"
env -u TMUX -u TMUX_PANE FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$NOTMUX" "$WT/bin/fm-teardown.sh" "$ID" --force 2>&1 | grep -v '^●\|WATCHER\|^WARNING'
echo "exit=${PIPESTATUS[0]}"
echo "state dir after: $(record "$D/home/state")"

hdr "SCENARIO H - forced secondmate cleanup, child endpoint close fails"
D=$(mk_case H); PARENT=mate-task; CHILD=child-task; MATE="$D/mate"
mkdir -p "$MATE/state" "$MATE/data" "$MATE/config"
printf '%s' "$PARENT" > "$MATE/.fm-secondmate-home"
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-session -d -s mates -n control )
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$S" new-window -d -t "=mates:" -n "fm-$CHILD" )
SHIM=$(mk_shim "$D" "$S")
printf 'window=mates:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nhome=%s\nkind=secondmate\nmode=secondmate\nharness=echo\nyolo=off\nprojects=alpha\n' \
  "$PARENT" "$PARENT" "$MATE" "$MATE" "$MATE" > "$D/home/state/$PARENT.meta"
printf 'window=mates:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nharness=echo\n' \
  "$CHILD" "$CHILD" "$D/nonexistent-worktree" "$D/nonexistent-project" > "$MATE/state/$CHILD.meta"
echo "\$ bin/fm-teardown.sh $PARENT --force     (child kill-window blocked, child window alive)"
env -u TMUX -u TMUX_PANE BLOCK_KILL=1 FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$SHIM:$NOTMUX" "$WT/bin/fm-teardown.sh" "$PARENT" --force 2>&1 | grep -v '^●\|WATCHER\|^WARNING'
echo "exit=${PIPESTATUS[0]}"
echo "parent state dir after: $(record "$D/home/state")"
echo "child  state dir after: $(record "$MATE/state")"
echo "windows after:"; windows "$D" "$S" mates
( cd "$D" && "$REAL_TMUX" -S "$S" kill-server 2>/dev/null )
