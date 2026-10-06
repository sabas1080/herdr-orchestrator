# Playbook: an 8-step herdr run

Run every command from the orchestrator's workspace root. `orch.sh` below is `sh SKILL/scripts/orch.sh` (`SKILL` = the skill directory). Exit codes: `0` ok, `1` failure, `2` usage/environment, `3` outcome unknown or timeout, `4` stuck (advisory), `5` awaiting approval.

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

One `--worker KIND[:Title]` per worker (titles may contain spaces; quote them). Optional: `--worktree` only if the user asked; `--agent-arg ARG` (repeatable) passes native arguments to every worker after `--`, e.g. `--agent-arg --permission-mode --agent-arg auto`, only when the user wants unattended Claude workers. See [agents-and-safety.md](agents-and-safety.md).

Output per worker: `started  [01] Vermithrax -> w01-vermithrax-xxxx (claude, w1:p2)` (or `reused …`), then `run <id> ready: <dir>`. Exit `0` ready; `1` with `INCOMPLETE: N worker(s) failed` and one `FAILED` line per failure (typically a dialog waiting in a pane: ask the user to answer it, then rerun `init-run --run-id ID` with the same `--worker` and `--agent-arg` flags); `2` usage, unknown kind or a worker count/title mismatch on rerun. A name collision with a live agent outside the run fails (exit 1) before anything is created.

New folders and new worktrees trigger Claude's folder-trust dialog. The user answers it once; you never do (H8).

## Step 4 Task add

```sh
orch.sh task add --id W1 --worker 1 --scope docs/a --criterion "docs/a/README.md documents every public function of a/"
orch.sh task add --id W3 --worker 1 --scope docs/a/api --deps W1 --criterion "…"
```

`--worker` is an ordinal (`1`, `01`) or an agent name from `orch.sh pool`. `--scope` and `--deps` take comma-separated lists. The ledger is validated on every add. Exit `0`: `task W1 added -> <agent>`. Exit `1`: the validator rejected the task (`[FAIL]` lines; the ledger is left unchanged): add `--deps` or split the scopes. Exit `2`: bad usage, unknown worker or duplicate id.

`orch.sh pool` shows workers, herdr status and each worker's open task (`ORD NAME KIND STATUS PANE TASK ESTADO`); `STATUS=gone` means the agent no longer exists.

## Step 5 Dispatch

Write the task file (see [prompt-templates.md](prompt-templates.md)), then:

```sh
orch.sh dispatch --task W1 --prompt-file /tmp/w1.md            # or add --wait [--timeout MS]
```

Preconditions: task `pending`, dependencies `verified`, worker `idle` or `done`, no other active task on that worker. Outcomes:

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
```

Needs the task `running` or `awaiting-approval`. Slices of 60 s, no raw output.

| Exit | Meaning | Next |
| --- | --- | --- |
| `0` | `wait: W1 completed (idle|done)` | `verify` |
| `1` | agent gone (task `interrupted`), or herdr failed 3 consecutive slices (`herdr error (<code>); estado unchanged`) | gone: ask the user before recreating; herdr error: `preflight`, then retry `wait` |
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

Runs the closure validator with `--require-evidence` and prints `[FAIL]` lines plus the final `TOTAL: N passed, M failed`; sends a notification (`done` or `request`). Exit `0` pass, `1` validation failure, `2` environment. Use `--allow-degraded` only when some task legitimately ended `failed`, `partial`, `blocked`, `cancelled` or `interrupted` with a reason in `notas`; the run is then reported as degraded.

Then deliver the output contract ([prompt-templates.md](prompt-templates.md) section 3). Teardown only on request:

```sh
orch.sh teardown                       # dry run: lists what would be closed
orch.sh teardown --confirm             # closes this run's worker panes
orch.sh teardown --confirm --remove-worktrees   # worktree runs: removes each worktree instead of closing its pane
```

Teardown warns about tasks still active, follows panes that moved (and updates the registry), skips the orchestrator's own pane, treats an already closed pane as done, never passes `--force`, and exits `1` if any pane or worktree could not be closed or removed (a dirty worktree is kept and reported; its pane stays open).

## Closing checklist

- Every task is terminal: `verified`, or a degraded terminal state with a reason in `notas`. None is `pending`, `completed`, `running`, `awaiting-approval` or `outcome-unknown`.
- `close` printed a `TOTAL` line with `0 failed`, or the run is reported degraded with the `notas` of each non-verified task.
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
