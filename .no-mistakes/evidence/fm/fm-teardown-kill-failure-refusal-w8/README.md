# Endpoint-close refusal - live operator evidence

All transcripts in `teardown-endpoint-close-operator-transcript.log` come from running the real
`bin/fm-teardown.sh` CLI against real tmux 3.7c servers on isolated sockets, in isolated `FM_HOME`s.
`drive*.sh` are the driver scripts that produced them.

| Scenario | What was driven | Result |
| --- | --- | --- |
| A | Live `fm-strand-demo` tmux window; teardown run under a PATH with no `tmux` | exit 1, refuses, record retained, window still alive |
| A' | Identical fixture on base commit `da5e658` | exit 0, `teardown ... complete`, record deleted, window still alive - the stranded endpoint |
| B | Same task re-run with tmux reachable | exit 0, real window closed, record removed |
| C | Recorded window already exited | exit 0, silent, record removed - ordinary cleanup unchanged |
| D | `kill-window` fails, re-read shows the window still present | exit 1, `is still present after its close`, record retained |
| E | Same failure with `--force` | exit 0, states what `--force` authorizes, record removed, failure still reported |
| F | Recorded window gone, prefix neighbour `fm-neighbour-extra` alive, kill fails | exit 0, silent, neighbour untouched - no prefix match |
| G | `backend=orca` record, no `orca` CLI, `--force` | exit 1, refuses, no continue announcement, record retained |
| H | Forced secondmate cleanup, child close fails | exit 1, both records retained, child window alive |
| I | zellij and cmux tasks with neither CLI installed | exit 0 both - unchanged backends do not start refusing |
| J | `fm_backend_kill` driven directly per backend | zellij/cmux/herdr already-gone -> silent 0; tmux with unreadable inventory -> 1 |

`teardown-endpoint-safety.log` and `orca-backend.log` are the repository's own suites for this area.
