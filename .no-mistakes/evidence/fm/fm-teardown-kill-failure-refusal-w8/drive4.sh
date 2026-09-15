#!/usr/bin/env bash
set -u
export FM_GATE_REFUSE_BYPASS=1
WT=/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2HP1H8ZGN90K5AEEN2QP4PY
SCRATCH=/tmp/fm-e2e-01M2HP/run4
NOTMUX=/tmp/fm-e2e-01M2HP/run/pathsans
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
mk_case() { local d="$SCRATCH/$1"; mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/project"; git init -q "$d/project"; printf '%s\n' "$d"; }
hdr() { printf '\n================ %s ================\n' "$*"; }
rec() { ls -A "$1" 2>/dev/null | tr '\n' ' '; echo; }

hdr "SCENARIO I - unchanged backends must not start refusing: zellij + cmux tasks on a host with neither CLI installed"
for spec in "zellij|lab:7|zellij_session=lab
zellij_tab_id=3
zellij_pane_id=7" "cmux|workspace-1:surface-2|cmux_workspace_id=workspace-1
cmux_surface_id=surface-2"; do
  b=${spec%%|*}; rest=${spec#*|}; win=${rest%%|*}; extra=${rest#*|}
  D=$(mk_case "$b"); ID=$b-task
  { printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nbackend=%s\nkind=ship\nmode=no-mistakes\n' \
      "$win" "$ID" "$D/nonexistent-worktree" "$D/nonexistent-project" "$b"; printf '%s\n' "$extra"; } > "$D/home/state/$ID.meta"
  echo "\$ bin/fm-teardown.sh $ID     (backend=$b, '$b' CLI not installed on this host)"
  env -u TMUX -u TMUX_PANE FM_HOME="$D/home" FM_ROOT_OVERRIDE="$WT" PATH="$NOTMUX" "$WT/bin/fm-teardown.sh" "$ID" 2>&1 \
    | grep -v '^●\|WATCHER\|^WARNING\|^Backlog:'
  echo "exit=${PIPESTATUS[0]}"
  echo "state dir after: $(rec "$D/home/state")"
  echo
done

hdr "SCENARIO J - fm_backend_kill contract, driven directly: already-gone endpoints on every arm stay a silent 0"
for b in zellij cmux herdr; do
  case $b in
    zellij) t="lab:7";; cmux) t="workspace-1:surface-2";; herdr) t="lab:w1:p2";;
  esac
  out=$(env -u TMUX -u TMUX_PANE PATH="$NOTMUX" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_kill "$2" "$3"' _ "$WT" "$b" "$t" 2>&1); rc=$?
  printf 'fm_backend_kill %-7s %-24s -> exit=%s stderr/stdout=%s\n' "$b" "$t" "$rc" "${out:-<silent>}"
done
out=$(env -u TMUX -u TMUX_PANE PATH="$NOTMUX" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_kill tmux "gone-session:fm-nope"' _ "$WT" 2>&1); rc=$?
printf 'fm_backend_kill %-7s %-24s -> exit=%s stderr/stdout=%s\n' tmux "gone-session:fm-nope (no tmux on PATH)" "$rc" "${out:-<silent>}"
