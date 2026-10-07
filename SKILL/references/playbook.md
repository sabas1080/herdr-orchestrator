# Playbook: an 8-step herdr run

Run every command from the orchestrator's workspace root. `orch.sh` below is `sh SKILL/scripts/orch.sh` (`SKILL` = the skill directory). Exit codes: `0` ok, `1` failure, `2` usage/environment, `3` outcome unknown or timeout, `4` stuck (advisory), `5` awaiting approval, `6` not settled yet (`task status` only).

## Step 1 Split

Break the user's request into deliverables. Each one needs a verifiable criterion (one sentence a worker can check) and a write scope (paths). Scopes of tasks that can run at the same time must not overlap; otherwise serialize them with `--deps`.

Optional sizing aid, which works even outside herdr and is advisory only:

```sh
orch.sh suggest-count /tmp/request.md   # suggest-count=2 words=… bullets=… idle_workers=…
```

Exit: `0`; `2` when the file is missing.

## Step 2 Preflight

```sh
orch.sh preflight
```

Prints `key=value` lines (versions, `compatible`, `kinds`, `template=ok|missing`, workspace/tab/pane ids, `workspace_dir`, `git=yes|no`) and ends with `gate=ready`. Exit `0` when ready; `2` when not inside herdr (`HERDR_ENV` not 1), `herdr`/`jq` missing, client and server not compatible (`gate=blocked …`) or the task-header template is missing. Any exit 2: degraded mode A, deliver the plan only.

## Step 3 Init-run

```sh
orch.sh init-run --run-id 20261006-docs --worker claude --worker codex:"Doc Writer"
```

One `--worker KIND[:Title]` per worker (titles may contain spaces; quote them). Optional: `--worktree` only if the user asked; `--agent-arg ARG` (repeatable) passes native arguments to every worker after `--`, one flag or value per `--agent-arg`, only when the user wants unattended Claude workers. See [agents-and-safety.md](agents-and-safety.md). `orch.sh` is kind-agnostic, so there is no shorthand for any one agent's flags; the usual unattended-Claude recipe is:

```sh
orch.sh init-run --run-id R --worker claude --worker claude \
  --agent-arg --model --agent-arg sonnet --agent-arg --permission-mode --agent-arg auto
```

Output per worker: `started  [01] Vermithrax -> w01-vermithrax-xxxx (claude, w1:p2)` (or `reused …`), then `run <id> ready: <dir>`. Exit `0` ready; `1` with `INCOMPLETE: N worker(s) failed` and one `FAILED` line per failure (typically a dialog waiting in a pane: ask the user to answer it, then rerun `init-run --run-id ID` with the same `--worker` and `--agent-arg` flags); `2` usage, unknown kind or a worker count/title mismatch on rerun. A name collision with a live agent outside the run fails (exit 1) before anything is created.

New folders and new worktrees trigger Claude's folder-trust dialog. The user answers it once; you never do (H8).

## Step 4 Task add

```sh
orch.sh task add --id W1 --worker 1 --scope docs/a --criterion "docs/a/README.md documents every public function of a/" --prompt-file /tmp/w1.md
orch.sh task add --id W3 --worker 1 --scope docs/a/api --deps W1 --criterion "…"
```

`--worker` is an ordinal (`1`, `01`) or an agent name from `orch.sh pool`. `--scope` and `--deps` take comma-separated lists. `--prompt-file F` copies the task body to `.herdr-orch/<run>/<task>/task.md`, so `dispatch` needs no file later (also after `reconcile` returns the task to `pending`, or after a reassignment). The ledger is validated on every add. Exit `0`: `task W1 added -> <agent>`. Exit `1`: the validator rejected the task (`[FAIL]` lines; the ledger is left unchanged, no task directory is left behind): add `--deps` or split the scopes. Exit `2`: bad usage, unknown worker, unreadable `--prompt-file` or duplicate id.

```sh
orch.sh task reassign --task W3 --worker 2      # task W3 -> w02-…
orch.sh task status --task W1                   # status: W1 running (w01-…); exit 6
```

`task reassign` moves a `pending` task to another worker: `agent_name`, `title`, `kind`, `pane_id`, `directory` and `worktree` are rewritten together, `notas` gets `reassigned from <agent>`, and the DAG is re-validated (relative scopes resolve against the new worker's directory; a rejection leaves the ledger unchanged, exit `1`). A task that was already dispatched cannot be reassigned (exit `2`): cancel it and add a new one (Degraded D). `task status` prints the ledger `estado` without calling herdr; exit codes as `wait` (`0` completed/verified, `1` terminal non-verified, `3` outcome-unknown, `5` awaiting-approval) plus `6` while `pending`, `launching` or `running`.

`orch.sh pool` shows workers, herdr status and each worker's open task (`ORD NAME KIND STATUS PANE TASK ESTADO`): the active task first, else a `completed` one waiting for `verify`, else the first `pending` in the queue. `STATUS=gone` means the agent no longer exists; after `teardown` every worker shows `gone`, because rows are kept in `workers.tsv` for audit.

## Step 5 Dispatch

Write the task file (see [prompt-templates.md](prompt-templates.md)), then:

```sh
orch.sh dispatch --task W1                                     # body stored by task add --prompt-file
orch.sh dispatch --task W1 --prompt-file /tmp/w1.md            # explicit body; or add --wait [--timeout MS]
```

Without `--prompt-file`, `dispatch` uses `.herdr-orch/<run>/<task>/task.md`; exit `2` when neither exists. Preconditions: task `pending`, dependencies `verified`, worker `idle` or `done`, no other active task on that worker. Outcomes:

| Result | Output | Exit |
| --- | --- | --- |
| Agent working | `dispatch: W1 running on <agent>` | `0` |
| Agent already settled | `dispatch: W1 completed (idle); next: …` | `0` |
| Agent blocked after the send | `dispatch: W1 awaiting approval in pane …; ask the user` | `5` |
| herdr refused before sending (approval dialog) | `dispatch: W1 not sent; … run: orch.sh reconcile --task W1` | `5` |
| herdr `timeout` on the send (activity seen, not settled) | `dispatch: W1 running on <agent>` | `0` |
| Any other settled status | `dispatch: W1 outcome-unknown (status …); run: orch.sh reconcile …` | `3` |
| Send error or stalled | `dispatch: W1 outcome-unknown (<code>); do not resend; run: orch.sh reconcile …` | `3` |

Dispatch records `prompt sent`, `prompt not sent` or `send uncertain: <code>` in the task's `notas`; `reconcile` uses it. A task stuck in `launching` (a dispatch that did not finish) is not re-dispatched: run `reconcile`. With `--wait`, a running task continues as `wait` and returns its exit code.

## Step 6 Wait

```sh
orch.sh wait --task W1 [--timeout MS] [--stuck-secs N]
orch.sh wait --any [--timeout MS]
```

`--task` needs the task `running` or `awaiting-approval`. Slices of 60 s, no raw output. `--any` polls one `agent list` every 3 s over every `running` task and settles the first one (in ledger order) whose worker is no longer `working`, printing the same lines and exit codes as below for that task; a timeout exits `3` without changing any `estado`, and with no running task it exits `5` listing the tasks awaiting approval, or `2` when there is nothing to wait for. The stuck advisory (exit `4`) exists only with `--task`. Several tasks can therefore be multiplexed from one shell: `wait --any`, `verify` the task it names, repeat.

| Exit | Meaning | Next |
| --- | --- | --- |
| `0` | `wait: W1 completed (idle|done)` | `verify` |
| `1` | agent gone (task `interrupted`), or herdr failed 3 consecutive slices (`herdr error (<code>); estado unchanged`) | gone: ask the user before recreating; herdr error: `preflight`, then retry `wait`; `status unknown (no herdr integration for this kind?); estado unchanged`: do not retry `wait`, switch the worker kind or install the herdr integration (Degraded B), `task set` if needed |
| `3` | timeout, task `outcome-unknown` | `reconcile --task W1` |
| `4` | stuck: no output change for N s (default 1800) while `working`; `estado` unchanged | keep waiting, or Degraded D (ask the user to interrupt that worker in its pane first) |
| `5` | worker `blocked`, task `awaiting-approval`, notification sound `request` | tell the user which pane needs approval, then `wait` again |

`reconcile --task W1` re-reads the worker and moves the task from `launching`, `outcome-unknown`, `running` or `awaiting-approval` according to what actually happened: `running`, `awaiting-approval` (exit 5), `completed`, `interrupted`, or back to `pending` only when the prompt provably never arrived (see the delivery rule in [ledger-template.md](ledger-template.md)). Exit `3` leaves the task unchanged (pane read failed, odd status, or a transition not allowed).

## Step 7 Verify

```sh
orch.sh verify --task W1
```

Needs `completed`. Reads only the report and evidence paths; you read `report.md` (at most 500 words). Exit `0`: `[OK] W1 verified; report: <path>`. Exit `1`: `[FAIL] …` lines, task stays `completed`: send the worker a continuation asking for the missing report or evidence ([prompt-templates.md](prompt-templates.md)), then `verify` again. Never write the evidence yourself.

## Step 8 Close

```sh
orch.sh close [--allow-degraded]
```

Runs the closure validator with `--require-evidence` and prints `[FAIL]` lines plus the final `TOTAL: N passed, M failed` (the `[OK]` lines go to stderr only when the close fails); sends a notification (`done` or `request`). Exit `0` pass, `1` validation failure, `2` environment. Use `--allow-degraded` only when some task legitimately ended `failed`, `partial`, `blocked`, `cancelled` or `interrupted` with a reason in `notas`; the run is then reported as degraded.

```sh
orch.sh summary
```

Prints `run=`, `workspace=`, `server_version=`, then one tab-separated row per task (`TASK WORKER KIND ESTADO SUMMARY EVIDENCE`; `SUMMARY` is the first non-heading paragraph of `report.md` with its wrapped lines joined, `-` when absent) and `tasks=N verified=A degraded=B open=C`. Nothing is read from the panes. Then deliver the output contract ([prompt-templates.md](prompt-templates.md) section 3). Teardown only on request:

```sh
orch.sh teardown                       # dry run: lists what would be closed
orch.sh teardown --confirm             # closes this run's worker panes
orch.sh teardown --confirm --remove-worktrees   # worktree runs: removes each worktree instead of closing its pane
```

Teardown warns about tasks still active, follows panes that moved (and updates the registry), skips the orchestrator's own pane, treats an already closed pane as done, never passes `--force`, and exits `1` if any pane or worktree could not be closed or removed (a dirty worktree is kept and reported; its pane stays open). It never deletes `workers.tsv` rows: `pool` keeps listing the workers as `gone`, which is the audit trail of the run.

## Closing checklist

- Every task is terminal: `verified`, or a degraded terminal state with a reason in `notas`. None is `pending`, `completed`, `running`, `awaiting-approval` or `outcome-unknown`.
- `close` printed a `TOTAL` line with `0 failed`, or the run is reported degraded with the `notas` of each non-verified task.
- `summary` rows copied into the output contract, with the summary column checked against each `report.md`.
- With `--worktree`: list every branch `orch/<run>/NN-slug` for the user; the orchestrator never merges.
- `teardown --confirm` only if the user asked for the panes to be closed.

## Example run

Two workers, two disjoint documentation tasks:

```text
$ orch.sh preflight
…
gate=ready
$ orch.sh init-run --run-id 20261006-docs --worker claude --worker codex:Glacielle
started  [01] Vermithrax -> w01-vermithrax-xxxx (claude, w1:p2)
started  [02] Glacielle -> w02-glacielle-xxxx (codex, w1:p3)
run 20261006-docs ready: /abs/repo/.herdr-orch/20261006-docs
$ orch.sh task add --id W1 --worker 1 --scope docs/a --criterion "docs/a/README.md documents every public function of a/"
task W1 added -> w01-vermithrax-xxxx
$ orch.sh task add --id W2 --worker 2 --scope docs/b --criterion "docs/b/README.md documents every public function of b/"
task W2 added -> w02-glacielle-xxxx
$ orch.sh dispatch --task W1 --prompt-file /tmp/w1.md
dispatch: W1 running on w01-vermithrax-xxxx
$ orch.sh dispatch --task W2 --prompt-file /tmp/w2.md
dispatch: W2 running on w02-glacielle-xxxx
$ orch.sh wait --task W1
wait: W1 completed (idle); next: orch.sh verify --task W1
$ orch.sh verify --task W1
[OK] W1 verified; report: /abs/repo/.herdr-orch/20261006-docs/W1/report.md
(same for W2)
$ orch.sh close
TOTAL: 4 passed, 0 failed
```

Agent-name suffixes (`xxxx`) are derived from the run id. A live acceptance run on herdr 0.8.2 produced exactly this shape.
