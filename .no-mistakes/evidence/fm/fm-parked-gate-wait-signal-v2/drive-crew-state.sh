#!/usr/bin/env bash
# Product driver: runs the REAL bin/fm-crew-state.sh CLI against a hermetic home
# whose `no-mistakes axi status` serves a given run payload, and prints the
# crew-state verdict line the watcher consumes.
set -u
ROOT=${DRV_ROOT:-/Users/amin/.no-mistakes/worktrees/041bc5e421de/01M2XYZMPA90XVVRG38TJ1974E}
SC=${SC:?}
name=$1; payload_file=$2
d="$SC/$name"
mkdir -p "$d/state" "$d/fakebin" "$d/wt"
if [ ! -d "$d/wt/.git" ]; then
  git -C "$d/wt" init -q; git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b fm/competing
fi
cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift
    if [ "$#" = 0 ]; then printf '%s\n' "${FM_FAKE_AXI_HOME:-}"; exit 0; fi
    case "${1:-}" in
      status) shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"; else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
    esac ;;
  daemon) printf 'daemon running (pid 4242)\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$d/fakebin/no-mistakes"
printf 'window=fm:fm-lane\nworktree=%s\nkind=ship\n' "$d/wt" > "$d/state/lane.meta"
head=$(git -C "$d/wt" rev-parse HEAD)
short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
payload=$(awk -v head="$head" '
  /^  head:/ { print "  head: " head; next }
  /^  head_sha:/ { print "  head_sha: " head; next }
  /^  id:/ { print "  id: \"01NEW\""; next }
  /^  branch:/ { print "  branch: fm/competing"; next }
  { print }' "$payload_file")
export FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01NEW\",fm/competing,running,$short,\"\""
export FM_FAKE_AXI_STATUS="$payload"
export FM_FAKE_AXI_STATUS_RUN="$payload"
PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$ROOT/bin/fm-crew-state.sh" lane
