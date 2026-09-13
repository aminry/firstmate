#!/usr/bin/env bash
# Manual end-to-end demonstration of PR 3884's shipped contract:
#   paseo is a KNOWN backend name that is EXPLICIT-ONLY, never spawn-capable,
#   and whose cleanup records refuse at the shared teardown boundary.
# Drives the real bin/fm-spawn.sh and bin/fm-teardown.sh exactly as a captain
# would, plus a before/after of fm_backend_detect across the fix commit.
set -u
ROOT=${1:?repo root}
OLD_LIB=${2:?pre-change fm-backend.sh}
D=$(mktemp -d /tmp/paseo-e2e.XXXXXX)
export FM_GATE_REFUSE_BYPASS=1
mkdir -p "$D/state" "$D/data" "$D/config" "$D/projects" "$D/fakebin"
printf '#!/bin/sh\necho Linux\n' > "$D/fakebin/uname"; chmod +x "$D/fakebin/uname"

hdr() { printf '\n===============================================================\n%s\n===============================================================\n' "$1"; }
cmd() { printf '\n$ %s\n' "$1"; }

hdr "1. AUTO-DETECTION REMOVED  (same ambient environment, before vs after)"
echo "Paseo exports PASEO_AGENT_ID into every descendant process, so an inherited"
echo "marker must not be read as the captain's consent to use the paseo backend."
cmd "PASEO_AGENT_ID=agent-uuid fm_backend_detect      # BEFORE (commit 9aa6940)"
env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier -u PASEO_TERMINAL_ID \
  PATH="$D/fakebin:$PATH" PASEO_AGENT_ID=agent-uuid \
  bash -c '. "$1"; out=$(fm_backend_detect); echo "detected=<${out}> exit=$?"' _ "$OLD_LIB"
cmd "PASEO_AGENT_ID=agent-uuid fm_backend_detect      # AFTER  (this change)"
env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier -u PASEO_TERMINAL_ID \
  PATH="$D/fakebin:$PATH" PASEO_AGENT_ID=agent-uuid \
  bash -c '. "$1"; out=$(fm_backend_detect); echo "detected=<${out}> exit=$?"' _ "$ROOT/bin/fm-backend.sh"

hdr "2. AMBIENT MARKERS NEVER ROUTE A REAL SPAWN THROUGH PASEO"
echo "Same fm-spawn command, PASEO_AGENT_ID + PASEO_TERMINAL_ID inherited, no"
echo "explicit backend anywhere. The backend boundary is crossed without paseo"
echo "being selected - the run stops later, on an unrelated missing-home check."
cmd "PASEO_AGENT_ID=... PASEO_TERMINAL_ID=... fm-spawn.sh sm-demo --secondmate"
env -u TMUX PASEO_AGENT_ID=agent-uuid PASEO_TERMINAL_ID=term-uuid \
  FM_STATE_OVERRIDE="$D/state" FM_DATA_OVERRIDE="$D/data" \
  FM_CONFIG_OVERRIDE="$D/config" FM_PROJECTS_OVERRIDE="$D/projects" \
  "$ROOT/bin/fm-spawn.sh" sm-demo --secondmate 2>&1
echo "exit=$?"

hdr "3. EXPLICIT SELECTION IS THE ONLY WAY IN - AND EVERY SPAWN REFUSES"
for form in flag env config; do
  case $form in
    flag)   label="--backend paseo" ;;
    env)    label="FM_BACKEND=paseo" ;;
    config) label="config/backend file containing 'paseo'" ;;
  esac
  cmd "fm-spawn.sh sm-demo --secondmate        # selected via $label"
  case $form in
    flag)
      env -u TMUX FM_STATE_OVERRIDE="$D/state" FM_DATA_OVERRIDE="$D/data" \
        FM_CONFIG_OVERRIDE="$D/config" FM_PROJECTS_OVERRIDE="$D/projects" \
        "$ROOT/bin/fm-spawn.sh" sm-demo --secondmate --backend paseo 2>&1 ;;
    env)
      env -u TMUX FM_BACKEND=paseo FM_STATE_OVERRIDE="$D/state" FM_DATA_OVERRIDE="$D/data" \
        FM_CONFIG_OVERRIDE="$D/config" FM_PROJECTS_OVERRIDE="$D/projects" \
        "$ROOT/bin/fm-spawn.sh" sm-demo --secondmate 2>&1 ;;
    config)
      printf 'paseo\n' > "$D/config/backend"
      env -u TMUX FM_STATE_OVERRIDE="$D/state" FM_DATA_OVERRIDE="$D/data" \
        FM_CONFIG_OVERRIDE="$D/config" FM_PROJECTS_OVERRIDE="$D/projects" \
        "$ROOT/bin/fm-spawn.sh" sm-demo --secondmate 2>&1
      rc=$?
      rm -f "$D/config/backend"
      (exit $rc) ;;
  esac
  echo "exit=$?"
done
cmd "fm-spawn.sh <project> claude --mode no-mistakes --yolo off --backend paseo   # ship spawn"
mkdir -p "$D/projects/demo"
env -u TMUX FM_STATE_OVERRIDE="$D/state" FM_DATA_OVERRIDE="$D/data" \
  FM_CONFIG_OVERRIDE="$D/config" FM_PROJECTS_OVERRIDE="$D/projects" \
  "$ROOT/bin/fm-spawn.sh" ship-demo "$D/projects/demo" claude \
  --mode no-mistakes --yolo off --backend paseo 2>&1
echo "exit=$?"
cmd "ls state/            # no task record was written by any refused spawn"
ls -A "$D/state" || true
echo "(empty)"

hdr "4. A backend=paseo CLEANUP RECORD REFUSES INSTEAD OF ORPHANING THE TERMINAL"
H="$D/home"; mkdir -p "$H/state" "$H/data" "$H/config" "$D/worktree" "$D/project"
git init -q "$D/project"
: > "$D/worktree/sentinel"
cat > "$H/state/paseo-task.meta" <<META
window=wks_c7e413f9c986b0f8:11111111-2222-3333-4444-555555555555
endpoint_task_id=paseo-task
worktree=$D/worktree
project=$D/project
backend=paseo
kind=scout
paseo_workspace_id=wks_c7e413f9c986b0f8
paseo_terminal_id=11111111-2222-3333-4444-555555555555
META
cmd "cat state/paseo-task.meta"
cat "$H/state/paseo-task.meta"
cmd "fm-teardown.sh paseo-task --force"
FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" PATH="$D/fakebin:$PATH" \
  "$ROOT/bin/fm-teardown.sh" paseo-task --force 2>&1
echo "exit=$?"
cmd "ls state/ worktree/   # durable task identity and worktree survive the refusal"
ls -A "$H/state"
ls -A "$D/worktree"
rm -rf "$D"
