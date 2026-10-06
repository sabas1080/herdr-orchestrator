# Failure matrix (herdr)

`orch.sh` maps herdr's JSON error codes; it never parses free text. Read the verdict line, pick the action, and avoid the "Do not" column.

| Failure | Signal | Action | Do not |
| --- | --- | --- | --- |
| Agent not ready | `agent_not_ready` on start (e.g. folder-trust dialog in a fresh worktree) | `INCOMPLETE`; user answers in that pane; rerun `init-run` | Send keys to the dialog |
| Folder-trust dialog at start | `init-run` prints `FAILED … agent start … (agent_not_ready) — answer any dialog in pane …` then `INCOMPLETE`, exit 1. E2E attempt 1: Claude in a new, untrusted repo showed the trust dialog | Ask the user to answer it once in that pane (or run in an already trusted folder); rerun `init-run` with the same `--run-id` and flags | Answer it yourself (H8); pass `--trust-repository` |
| Approval prompt from a worker | `dispatch`/`wait` exit 5 (`awaiting approval in pane …`), status `blocked`. E2E attempt 2: workers started with `--permission-mode acceptEdits` wrote files, then asked approval for a Bash command | Tell the user which pane; after they answer, `wait` (or `reconcile` when `dispatch` said "not sent"). To avoid repeats, restart the run with a worker permission mode the user chooses (`--agent-arg`, see [agents-and-safety.md](agents-and-safety.md)) | Send keys to approve; pick `bypassPermissions` yourself |
| Approval pending | `agent_blocked` / status `blocked` | `awaiting-approval`; notify; ask the user | Send keys to approve |
| Prompt stalled | `agent_prompt_stalled` | `outcome-unknown`; `reconcile` | Resend |
| Timeout | exit 3 | `outcome-unknown`; `reconcile` | Release scope; resend |
| Stuck | exit 4 (advisory) | Decide: keep waiting or Degraded D | Kill the pane without approval |
| Name collision | live agent with the same name outside this run | Fail closed; choose another title or run id | Rename the foreign agent |
| Pane moved | recorded `pane_id` gone, agent name live | `init-run` reuse and `teardown` refresh `workers.tsv` by agent name; the ledger's `pane_id` is informational and may be stale (dispatch/wait messages may show the old id) | Use the old pane ID |
| Pane closed externally | `agent_not_found` / `pool` shows `gone` | Active task → `interrupted`; ask before recreating | Assume the work finished |
| Evidence gate fails | `verify` prints `[FAIL]` | Keep `completed`; ask the worker via `herdr agent prompt <agent_name> "…" --wait`, then `orch.sh verify --task ID`, for the missing evidence | Write the evidence yourself |
| Incomplete init | `INCOMPLETE`, exit 1 | Rerun `init-run` with the same `--run-id` | Create workers by hand |
| Version skew | `herdr status --json` `.server.compatible == false` | Stop; report | Upgrade or restart the server |
| Lock contention | lock not acquired within timeout | Retry later; report | Delete the lock while another `orch.sh` runs |

Other behaviours worth knowing:

- `wait` exits 1 with `herdr error (<code>); estado unchanged` after 3 consecutive failing slices: run `preflight`, then retry `wait`.
- `wait` exits 1 with `status unknown (no herdr integration for this kind?); estado unchanged`: do not retry `wait`; switch the worker kind or install the herdr integration (see Degraded B), and `task set` the task if needed. The stuck advisory (exit 4) only fires while the worker is `working`.
- `dispatch` refuses a task left in `launching` (a previous dispatch did not finish): `reconcile` it.
- `teardown` exits 1 when a pane could not be closed or a worktree not removed (dirty worktree: kept, pane left open); it warns about tasks still active and skips the orchestrator pane. A pane that moved is followed by agent name; an already closed pane counts as done.

## Verify effects before retrying

1. Read `orch.sh pool`: worker status and each worker's open task.
2. Run `orch.sh reconcile --task ID`; it decides from the worker's real state and the dispatch notes.
3. Inspect the task's report and evidence paths, and the task's scope with `git status` (the files a worker may already have changed).
4. Only then re-dispatch a task that `reconcile` returned to `pending`.
5. Never resend a prompt to a `running` task.
