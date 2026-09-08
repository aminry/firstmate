#!/usr/bin/env bash
# Manual end-to-end verification of the paseo stage-1 safety boundary, driven
# exactly the way a captain would hit it from a shell. Nothing here stubs
# firstmate: bin/fm-spawn.sh and bin/fm-teardown.sh are the real scripts.
#
# FM_GATE_REFUSE_BYPASS=1 is the repo's own documented test-harness escape hatch
# (bin/fm-gate-refuse-lib.sh), exported by tests/lib.sh, needed only because this
# transcript is captured from inside a no-mistakes gate worktree.
set -u
cd "${ROOT:?set ROOT to the firstmate checkout}"

S=$(mktemp -d "${TMPDIR:-/tmp}/paseo-e2e.XXXXXX")
trap 'rm -rf "$S"' EXIT

hdr() { printf '\n==================================================================\n%s\n==================================================================\n' "$1"; }
cmd() { printf '\n$ %s\n' "$1"; }

new_home() {  # <name> -> echoes home dir
  local d="$S/$1"
  mkdir -p "$d/state" "$d/data" "$d/config" "$d/projects" "$d/fakebin"
  # Record any multiplexer/worktree command teardown would run, and succeed, so
  # "no runtime command ran" below is an observation and not an absence of tools.
  local t
  for t in tmux treehouse paseo; do
    cat > "$d/fakebin/$t" <<SH
#!/usr/bin/env bash
printf '$t' >> "\${FM_RUNTIME_LOG:?}"; printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"; exit 0
SH
    chmod +x "$d/fakebin/$t"
  done
  : > "$d/runtime.log"
  printf '%s\n' "$d"
}

spawn() {  # <home> <extra env assignments as VAR=VAL...> -- <fm-spawn args>
  local home=$1; shift
  env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u PASEO_TERMINAL_ID -u PASEO_AGENT_ID \
    FM_GATE_REFUSE_BYPASS=1 FM_BACKEND= \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$@"
}

# ---------------------------------------------------------------------------
hdr "1. A captain whose firstmate runs as a Paseo agent tries to spawn a task"
H=$(new_home spawn-auto)
cmd "PASEO_AGENT_ID=agt_9f2c41d0 bin/fm-spawn.sh paseo-demo firstmate claude --mode no-mistakes --yolo off"
spawn "$H" PASEO_AGENT_ID=agt_9f2c41d0 bin/fm-spawn.sh paseo-demo firstmate claude \
  --mode no-mistakes --yolo off 2>&1
printf '[exit %s]\n' "$?"
printf '\n-- task records left behind in the fleet state dir: %s --\n' "$(ls -A "$H/state" | grep -c . )"

hdr "2. Same host, a Paseo TERMINAL rather than an agent session"
H=$(new_home spawn-term)
cmd "PASEO_TERMINAL_ID=11111111-2222-3333-4444-555555555555 bin/fm-spawn.sh paseo-demo firstmate claude --mode no-mistakes --yolo off"
spawn "$H" PASEO_TERMINAL_ID=11111111-2222-3333-4444-555555555555 bin/fm-spawn.sh \
  paseo-demo firstmate claude --mode no-mistakes --yolo off 2>&1
printf '[exit %s]\n' "$?"

hdr "3. Asking for paseo explicitly refuses at the same shared boundary"
H=$(new_home spawn-explicit)
cmd "bin/fm-spawn.sh sm-demo --secondmate --backend paseo"
spawn "$H" bin/fm-spawn.sh sm-demo --secondmate --backend paseo 2>&1
printf '[exit %s]\n' "$?"
printf '\n-- task records left behind: %s --\n' "$(ls -A "$H/state" | grep -c . )"

hdr "4. The opt-out the notice tells the captain to use"
H=$(new_home spawn-optout)
cmd "PASEO_AGENT_ID=agt_9f2c41d0 bin/fm-spawn.sh paseo-demo firstmate claude --mode no-mistakes --yolo off --backend tmux"
spawn "$H" PASEO_AGENT_ID=agt_9f2c41d0 bin/fm-spawn.sh paseo-demo firstmate claude \
  --mode no-mistakes --yolo off --backend tmux 2>&1 | head -6
printf '(the paseo notice and the paseo refusal are both gone; the run proceeds past\n the backend boundary and stops on this sandbox having no such project)\n'

printf '\n'
cmd "echo tmux > \$FM_CONFIG/backend   # the durable form of the same opt-out"
H=$(new_home spawn-pinned); printf 'tmux\n' > "$H/config/backend"
spawn "$H" PASEO_AGENT_ID=agt_9f2c41d0 bin/fm-spawn.sh paseo-demo firstmate claude \
  --mode no-mistakes --yolo off 2>&1 | head -4
printf '(silent: an explicitly pinned backend wins over auto-detection with no notice)\n'

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# paseo_teardown_case: a well-formed backend=paseo cleanup record - exact task
# binding, composite window= target, and both identity parts recorded - torn
# down through the real fm-teardown.sh. This is the Greptile P1.
paseo_teardown_case() {  # <label> <fm-backend.sh source: current | <git rev>>
  local label=$1 src=$2 tr h f b id=paseo-task
  tr=$(mktemp -d "$S/fmroot.XXXXXX")/root; mkdir -p "$tr"
  for f in "$PWD"/* "$PWD"/.[!.]*; do
    b=$(basename "$f"); [ "$b" = bin ] && continue
    ln -s "$f" "$tr/$b" 2>/dev/null || true
  done
  cp -R "$PWD/bin" "$tr/bin"
  [ "$src" = current ] || git show "$src:bin/fm-backend.sh" > "$tr/bin/fm-backend.sh"
  h=$(new_home "teardown-paseo-$label")
  mkdir -p "$h/worktree" "$h/project"; git init -q "$h/project"; : > "$h/worktree/sentinel"
  cat > "$h/state/$id.meta" <<META
window=wks_c7e413f9c986b0f8:11111111-2222-3333-4444-555555555555
endpoint_task_id=$id
worktree=$h/worktree
project=$h/project
kind=scout
backend=paseo
paseo_workspace_id=wks_c7e413f9c986b0f8
paseo_terminal_id=11111111-2222-3333-4444-555555555555
META
  printf '\n-- the durable task record, the only place the terminal identity lives --\n'
  sed -n '1,9p' "$h/state/$id.meta"
  cmd "bin/fm-teardown.sh $id --force"
  FM_HOME="$h" FM_ROOT_OVERRIDE="$tr" FM_GATE_REFUSE_BYPASS=1 \
    FM_RUNTIME_LOG="$h/runtime.log" PATH="$h/fakebin:$PATH" \
    "$tr/bin/fm-teardown.sh" "$id" --force 2>&1 | tail -3
  printf '\n-- durable state after the command (the Paseo terminal is still running:\n   nothing in firstmate can kill it, fm_backend_kill has no paseo arm) --\n'
  if [ -f "$h/state/$id.meta" ]; then
    printf 'task record on disk       : preserved\n'
    printf 'paseo terminal identity   : %s\n' "$(sed -n 's/^paseo_terminal_id=//p' "$h/state/$id.meta")"
  else
    printf 'task record on disk       : DELETED\n'
    printf 'paseo terminal identity   : GONE - the running terminal is now unreachable\n'
  fi
  printf 'worktree still present    : %s\n' "$([ -f "$h/worktree/sentinel" ] && echo yes || echo NO)"
  printf 'runtime commands invoked  : %s\n' "$([ -s "$h/runtime.log" ] && tr '\n' ';' < "$h/runtime.log" || echo none)"
}

hdr "5a. BEFORE (bin/fm-backend.sh at 119d0a3): teardown reports COMPLETE over a live Paseo terminal"
paseo_teardown_case before 119d0a3

hdr "5b. AFTER: the same record refuses and every part of the task survives"
paseo_teardown_case after current

hdr "6. A working backend still tears down (the refusal is not a blanket stop)"
H=$(new_home teardown-tmux)
mkdir -p "$H/worktree" "$H/project"; git init -q "$H/project"; : > "$H/worktree/sentinel"
ID=tmux-task
cat > "$H/state/$ID.meta" <<META
window=isolated:fm-$ID
endpoint_task_id=$ID
worktree=$H/worktree
project=$H/project
kind=scout
META
cmd "bin/fm-teardown.sh $ID --force   # same command, a tmux-backed record"
FM_HOME="$H" FM_ROOT_OVERRIDE="$PWD" FM_GATE_REFUSE_BYPASS=1 \
  FM_RUNTIME_LOG="$H/runtime.log" PATH="$H/fakebin:$PATH" \
  bin/fm-teardown.sh "$ID" --force 2>&1 | tail -5
printf '\n-- what teardown did --\n'
printf 'task record still on disk : %s\n' "$([ -f "$H/state/$ID.meta" ] && echo yes || echo 'no (cleaned up)')"
printf 'runtime commands invoked  : %s\n' "$([ -s "$H/runtime.log" ] && head -3 "$H/runtime.log" || echo none)"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Simulate the NEXT backend registration exactly as a developer would make it:
# add a name to FM_BACKEND_KNOWN in bin/fm-backend.sh, with no validation arm
# and no fm_backend_kill arm yet - the shape paseo itself had when a well-formed
# record was still accepted over a live terminal. Built as a throwaway FM root
# so the checkout is never touched.
adapterless_root() {  # <fm-backend.sh source: "current" | <git rev>> -> echoes root
  local src=$1 tr f b
  tr=$(mktemp -d "$S/fmroot.XXXXXX")/root; mkdir -p "$tr"
  for f in "$PWD"/* "$PWD"/.[!.]*; do
    b=$(basename "$f"); [ "$b" = bin ] && continue
    ln -s "$f" "$tr/$b" 2>/dev/null || true
  done
  cp -R "$PWD/bin" "$tr/bin"
  [ "$src" = current ] || git show "$src:bin/fm-backend.sh" > "$tr/bin/fm-backend.sh"
  perl -pi -e 's/^FM_BACKEND_KNOWN="tmux herdr zellij orca cmux paseo"$/FM_BACKEND_KNOWN="tmux herdr zellij orca cmux paseo notyetimplemented"/' \
    "$tr/bin/fm-backend.sh"
  printf '%s\n' "$tr"
}

adapterless_case() {  # <label> <fm-backend.sh source>
  local label=$1 tr h id=adapterless-task
  tr=$(adapterless_root "$2")
  h=$(new_home "adapterless-$label")
  mkdir -p "$h/worktree" "$h/project"; git init -q "$h/project"; : > "$h/worktree/sentinel"
  cat > "$h/state/$id.meta" <<META
window=isolated:fm-$id
endpoint_task_id=$id
worktree=$h/worktree
project=$h/project
kind=scout
backend=notyetimplemented
META
  cmd "bin/fm-teardown.sh $id --force        # FM_BACKEND_KNOWN += notyetimplemented"
  FM_HOME="$h" FM_ROOT_OVERRIDE="$tr" FM_GATE_REFUSE_BYPASS=1 \
    FM_RUNTIME_LOG="$h/runtime.log" PATH="$h/fakebin:$PATH" \
    "$tr/bin/fm-teardown.sh" "$id" --force 2>&1 | tail -3
  printf '\n-- durable state after the command --\n'
  printf 'task record on disk       : %s\n' "$([ -f "$h/state/$id.meta" ] && echo 'preserved' || echo 'DELETED - endpoint identity gone')"
  printf 'worktree return invoked   : %s\n' "$(grep -q 'return' "$h/runtime.log" 2>/dev/null && echo 'YES - worktree handed back' || echo 'no')"
  printf 'runtime commands invoked  : %s\n' "$([ -s "$h/runtime.log" ] && tr '\n' '; ' < "$h/runtime.log" || echo none)"
}

hdr "7a. BEFORE (bin/fm-backend.sh at 4e145be): a backend registered before its adapter FAILS OPEN"
adapterless_case before 4e145be

hdr "7b. AFTER (commit c5d0607): the same record fails CLOSED at the shared cleanup boundary"
adapterless_case after current

hdr "8. Registry surface a captain sees when they typo the name"
H=$(new_home spawn-typo)
cmd "bin/fm-spawn.sh demo --secondmate --backend paseo-typo"
spawn "$H" bin/fm-spawn.sh demo --secondmate --backend paseo-typo 2>&1
printf '[exit %s]\n' "$?"
printf '\n'

# ---------------------------------------------------------------------------
# The session-start surface. bin/fm-bootstrap.sh calls fm_backend_name on every
# session, so the notice is what a Paseo-hosted captain reads before they ever
# type a spawn - and the resolved backend drives which tools are reported
# missing. A/B with only the backend differing, and tmux genuinely off PATH.
bootstrap_home() {  # <name> -> echoes home
  local d="$S/$1" t
  mkdir -p "$d/home" "$d/fakebin"
  for t in node chrome-devtools-axi no-mistakes tasks-axi quota-axi gh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/fakebin/$t"
  done
  printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo 0.1.46; exit 0; }\nexit 0\n' > "$d/fakebin/lavish-axi"
  printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo 0.1.29; exit 0; }\nexit 0\n' > "$d/fakebin/gh-axi"
  printf '#!/usr/bin/env bash\nif [ "$1" = get ] && [ "$2" = --help ]; then echo "  --lease"; exit 0; fi\nexit 0\n' > "$d/fakebin/treehouse"
  chmod +x "$d/fakebin"/*
  printf '%s\n' "$d"
}

hdr "9. Session start on a Paseo host, and the backend tool delta"
BP=/usr/bin:/bin:/usr/sbin:/sbin   # excludes the prefix tmux is installed under
D=$(bootstrap_home bootstrap-paseo)
cmd "PASEO_AGENT_ID=agt_9f2c41d0 bin/fm-bootstrap.sh     # tmux NOT installed"
env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u PASEO_TERMINAL_ID PASEO_AGENT_ID=agt_9f2c41d0 \
  PATH="$D/fakebin:$BP" FM_HOME="$D/home" FM_ROOT_OVERRIDE="$PWD" FM_GATE_REFUSE_BYPASS=1 \
  bin/fm-bootstrap.sh 2>&1 | grep -E "NOTICE|MISSING: tmux" || true
printf '(no "MISSING: tmux": paseo is session-provider-only, so tmux is not in its tool delta)\n'

D=$(bootstrap_home bootstrap-tmux)
cmd "bin/fm-bootstrap.sh                                  # same host, no Paseo marker"
env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u PASEO_TERMINAL_ID -u PASEO_AGENT_ID \
  PATH="$D/fakebin:$BP" FM_HOME="$D/home" FM_ROOT_OVERRIDE="$PWD" FM_GATE_REFUSE_BYPASS=1 \
  bin/fm-bootstrap.sh 2>&1 | grep -E "NOTICE|MISSING: tmux" || true
printf '(the default tmux home IS told, and gets no paseo notice - only the backend differed)\n'
printf '\n'
