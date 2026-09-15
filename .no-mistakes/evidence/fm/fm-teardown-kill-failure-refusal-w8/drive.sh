#!/usr/bin/env bash
# Manual operator-style drive of fm-teardown's endpoint-close refusal.
set -u
export FM_GATE_REFUSE_BYPASS=1
WT=/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2HP1H8ZGN90K5AEEN2QP4PY
BASE=/tmp/fm-e2e-01M2HP/base
SCRATCH=/tmp/fm-e2e-01M2HP/run
REAL_TMUX=$(command -v tmux)
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

# a curated PATH that resolves everything EXCEPT tmux (genuine "tmux not on PATH")
NOTMUX="$SCRATCH/pathsans"
mkdir -p "$NOTMUX"
IFS=: read -ra DIRS <<< "$PATH"
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  for e in "$d"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    n=${e##*/}
    [ "$n" = tmux ] && continue
    [ -e "$NOTMUX/$n" ] && continue
    ln -s "$e" "$NOTMUX/$n" 2>/dev/null
  done
done
command -v tmux >/dev/null && PATH="$NOTMUX" command -v tmux >/dev/null && { echo "FATAL: tmux still resolvable"; exit 1; }
PATH="$NOTMUX" command -v git >/dev/null || { echo "FATAL: curated PATH lost git"; exit 1; }

mk_case() {  # <name>
  local d="$SCRATCH/$1"
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/project"
  git init -q "$d/project"
  printf '%s\n' "$d"
}
win_exists() {  # <dir> <socket> <session> <window>
  ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "=$3" -F '#{window_name}' 2>/dev/null ) | grep -Fqx "$4"
}
meta() {  # <dir> <id> <window>
  printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' \
    "$3" "$2" "$1/nonexistent-worktree" "$1/nonexistent-project" > "$1/home/state/$2.meta"
}

mk_tmux_shim() {  # <dir> <socket>  -> prints a bin dir whose tmux is real tmux pinned to <dir>/<socket>
  local d=$1 sock=$2
  mkdir -p "$d/shimbin"
  cat > "$d/shimbin/tmux" <<SH
#!/usr/bin/env bash
cd '$d'
exec '$REAL_TMUX' -S '$sock' "\$@"
SH
  chmod +x "$d/shimbin/tmux"
  printf '%s\n' "$d/shimbin"
}

hdr() { printf '\n================ %s ================\n' "$*"; }

######################################################################
hdr "SCENARIO A - live tmux window, teardown run with no tmux on PATH (TARGET build)"
D=$(mk_case A); SOCK=s.sock; SESS='crew'; ID=strand-demo
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" new-session -d -s "$SESS" -n control )
( cd "$D" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" new-window -d -t "=$SESS:" -n "fm-$ID" )
meta "$D" "$ID" "$SESS:fm-$ID"
echo "--- before: windows in session ---"; ( cd "$D" && "$REAL_TMUX" -S "$SOCK" list-windows -t "=$SESS" -F '  #{window_name}' )
echo "--- before: task record ---"; ls "$D/home/state"
echo "\$ bin/fm-teardown.sh $ID     (PATH without tmux)"
env -u TMUX -u TMUX_PANE FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$NOTMUX" \
  "$WT/bin/fm-teardown.sh" "$ID"; echo "exit=$?"
echo "--- after: task record ---"; ls "$D/home/state"
echo "--- after: windows in session ---"; ( cd "$D" && "$REAL_TMUX" -S "$SOCK" list-windows -t "=$SESS" -F '  #{window_name}' )

hdr "SCENARIO A' - SAME fixture, SAME situation, BASE build (the bug being fixed)"
DB=$(mk_case Abase); IDB=strand-demo
( cd "$DB" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" new-session -d -s base-crew -n control )
( cd "$DB" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" new-window -d -t "=base-crew:" -n "fm-$IDB" )
meta "$DB" "$IDB" "base-crew:fm-$IDB"
echo "\$ bin/fm-teardown.sh $IDB     (base commit da5e658, PATH without tmux)"
env -u TMUX -u TMUX_PANE FM_HOME="$DB/home" FM_ROOT_OVERRIDE="$BASE" PATH="$NOTMUX" \
  "$BASE/bin/fm-teardown.sh" "$IDB"; echo "exit=$?"
echo "--- after: task record (base) ---"; ls -A "$DB/home/state" || true
echo "--- after: windows in session (base) ---"; ( cd "$DB" && "$REAL_TMUX" -S "$SOCK" list-windows -t "=base-crew" -F '  #{window_name}' )

######################################################################
hdr "SCENARIO B - same task, tmux back on PATH: the retained record lets the rerun finish"
SHIM=$(mk_tmux_shim "$D" "$SOCK")
echo "\$ bin/fm-teardown.sh $ID"
env -u TMUX -u TMUX_PANE FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$SHIM:$NOTMUX" \
  "$WT/bin/fm-teardown.sh" "$ID"; echo "exit=$?"
echo "--- after: task record ---"; ls -A "$D/home/state" || true
echo "--- after: windows in session ---"; ( cd "$D" && "$REAL_TMUX" -S "$SOCK" list-windows -t "=$SESS" -F '  #{window_name}' )
( cd "$D" && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null )
( cd "$DB" && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null )
