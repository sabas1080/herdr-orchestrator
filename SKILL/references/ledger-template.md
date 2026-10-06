# Ledger schema 4, state machine and validators

The ledger `.herdr-orch/<run>/ledger.yaml` is written only by `orch.sh`; never edit it by hand. `task add` briefly keeps a `ledger.yaml.bak` to roll back a rejected task and removes it afterwards. Spanish field names (`dependencias`, `scope_escritura`, `estado`, `notas`) are kept on purpose. Unknown keys are rejected.

## Schema

```yaml
schema_version: 4
run:
  run_id: "20261006-1530-docs"
  herdr:
    server_version: "0.8.2"
  workspace:
    directory: "/abs/repo"
    herdr_workspace_id: "w1"
    herdr_tab_id: "w1:t1"
  orchestrator:
    pane_id: "w1:p1"
    kind: "claude"
tasks:
  - task_id: "W1"
    agent_name: "w01-vermithrax-k3f9"
    title: "[01] Vermithrax"
    kind: "codex"
    pane_id: "w1:p3"
    worktree: null
    directory: "/abs/repo"
    dependencias: []
    scope_escritura: ["docs/a", "/abs/repo/.herdr-orch/20261006-1530-docs/W1"]
    criterion: "docs/a/README.md documents every public function in a/"
    output_path: "/abs/repo/.herdr-orch/20261006-1530-docs/W1/report.md"
    evidence_refs: ["/abs/repo/.herdr-orch/20261006-1530-docs/W1/evidence.yml"]
    estado: "pending"
    runtime_status: null
    execution_outcome: "unknown"
    created_at: "2026-10-06T15:30:00Z"
    last_state_at: "2026-10-06T15:30:00Z"
    notas: ""
```

## Field rules

- `run.herdr.server_version`: from `herdr status --json` (`.server.version`).
- `run.workspace.directory`: absolute; must equal the validator's `pwd -P`. Run the validators from the workspace root.
- `run_id`: `[a-z0-9][a-z0-9._-]*`; default `YYYYMMDD-HHMM-run`.
- `task_id`: unique, `[A-Za-z0-9][A-Za-z0-9._-]*`.
- `agent_name`: `[a-z][a-z0-9_-]{0,31}`; exists in `workers.tsv`; not unique across tasks (a worker serves several tasks over time, one at a time).
- `title`: the worker's pane label `[NN] Name`. `kind`: herdr agent kind of that worker. `pane_id`: copied from `workers.tsv`.
- `worktree`: `null` or an absolute path. `directory` equals `run.workspace.directory` when `worktree` is `null`, otherwise equals `worktree`.
- `output_path`: absolute, under `RUN_DIR/<task_id>/`. `evidence_refs`: non-empty list of absolute paths under `RUN_DIR/<task_id>/`.
- `runtime_status`: `null` or the herdr `agent_status` last observed (`idle`, `working`, `blocked`, `done`, `unknown`).
- `execution_outcome`: `unknown`, `succeeded`, `failed`, `interrupted` or `cancelled`.
- Timestamps are UTC `YYYY-MM-DDTHH:MM:SSZ`; `created_at` never changes; `last_state_at` is updated on each transition.
- `notas`: free text; each new note is appended to the previous ones separated by `; `.

## Path model

Everything a run produces lives under `RUN_DIR = <orchestrator pwd -P>/.herdr-orch/<run_id>/` (added to `.git/info/exclude` inside a git repo):

```text
RUN_DIR/
  ledger.yaml          tasks, schema 4 (written only by orch.sh)
  workers.tsv          worker pool: ord agent_name title kind workspace_id pane_id directory worktree
  .lock/               mkdir-based write lock (if stale: rmdir it by hand only when no orch.sh runs)
  <task_id>/prompt.md  composed task prompt
  <task_id>/report.md  worker's report (at most 500 words)
  <task_id>/evidence.yml
```

- `output_path` and `evidence_refs` are absolute paths under `RUN_DIR/<task_id>/` for every task, worktree tasks included. Reports and evidence stay in the orchestrator's tree, survive worktree removal and are reachable by the closure gate.
- Each task's `scope_escritura` always contains the absolute `RUN_DIR/<task_id>` entry plus its work scopes.
- Relative scope entries resolve against the task's `directory`. Absolute entries are accepted only under `run.workspace.directory` or under the task's own `directory`.
- Every scope is canonicalised to an absolute path before comparison. Two tasks conflict only if their canonical scopes overlap by path components, so tasks in different worktrees never conflict.

## State machine

Active states: `launching`, `running`, `awaiting-approval`, `outcome-unknown`. Terminal states: `verified`, `blocked`, `failed`, `partial`, `interrupted`, `cancelled`. `pending` and `completed` are resting states.

| From | To | Written by | Notes |
| --- | --- | --- | --- |
| `pending` | `launching` | `dispatch` | before sending |
| `launching` | `running` / `completed` / `awaiting-approval` / `outcome-unknown` | `dispatch` | mapping from the send result and the observed status |
| `launching` | `pending` | `reconcile` | only when the prompt provably never arrived (delivery rule below) |
| `running` | `running` / `completed` / `awaiting-approval` / `outcome-unknown` / `interrupted` | `wait`, `reconcile` | |
| `awaiting-approval` | `awaiting-approval` / `running` / `completed` / `outcome-unknown` / `interrupted` | `wait`, `reconcile` | |
| `outcome-unknown` | `outcome-unknown` / `running` / `completed` / `awaiting-approval` / `interrupted` / `pending` | `reconcile` | `pending` only under the delivery rule |
| `completed` | `verified` | `verify` | evidence gate |
| any non-terminal | `cancelled` / `failed` / `partial` / `blocked` / `interrupted` | `task set` | `--notas` required |
| terminal | none | none | no transitions; reassignment creates a new task |

`execution_outcome` becomes `succeeded` when the task reaches `completed`, `interrupted`/`cancelled`/`failed` with the matching terminal state, and `unknown` for `pending`, `launching`, `running`, `awaiting-approval`, `outcome-unknown`. `verify` changes only `estado` and `last_state_at`. `partial` and `blocked` (via `task set`) leave `execution_outcome` unchanged. `completed` requires `execution_outcome: succeeded`.

### Dispatch notes and the reconcile delivery rule

`dispatch` appends one marker to `notas`: `prompt sent` (the send succeeded, or the stalled error after a send), `prompt not sent: agent at approval dialog` (herdr refused before sending) or `send uncertain: <code>` (any other send error).

`reconcile` (accepts `launching`, `outcome-unknown`, `running`, `awaiting-approval`) observes the agent:

- gone: `interrupted`; `working`: `running`; `blocked`: `awaiting-approval` (exit 5).
- `idle`/`done` with the report present: `completed`.
- `idle`/`done`, no report: reads the pane. Task marker `[herdr-orch <run>/<task>]` seen: `completed` ("prompt seen, no report yet"). Otherwise it returns to `pending` ("reconciled: prompt not delivered", `runtime_status` cleared) only when the current attempt's notes show `prompt not sent`, or show neither `prompt sent` nor `prompt not sent` and no `runtime_status` was ever observed. In every other case it moves to `completed` with "delivered earlier; no report", and `verify` then fails until the worker writes its evidence.
- Only the notes after the last "reconciled: prompt not delivered" count as the current attempt.
- Any other status, a failed pane read, or a transition the table forbids: exit `3`, state unchanged.

## Validator checks (`validate_dag.sh`)

1. Schema shape, `schema_version: 4`, required keys present, no unknown keys, scalar formats.
2. `task_id` unique; `agent_name` format valid.
3. At most one task in an active state per `agent_name`.
4. `dependencias` reference existing tasks; the graph is acyclic; a task in an active or post-active state (`launching` onward) has all dependencies `verified`.
5. Scopes: canonical scopes of two tasks must not overlap unless one transitively depends on the other. Terminal non-verified tasks (`blocked`, `failed`, `partial`, `interrupted`, `cancelled`) release their scope: they are excluded from the overlap check and must have non-empty `notas`. Ask the user to stop the worker first if it may still be writing.
6. `output_path` and every `evidence_refs` entry are absolute, under `RUN_DIR/<task_id>/` and inside some `scope_escritura` entry of the task.
7. `directory` is consistent with `worktree` and `run.workspace.directory`.
8. `run.workspace.directory` equals `pwd -P`.
9. `completed` implies `execution_outcome: succeeded`; terminal non-verified states require non-empty `notas`.

`validate_dag.sh LEDGER` exits `0` pass, `1` failure, `2` usage/environment, and prints `[FAIL]` lines and a `TOTAL` line.

## Verified-task gate

A task becomes `verified` only if `output_path` exists and every `evidence_refs` file exists and holds exactly the three keys `criterion` (equal to the task's criterion), `result: "pass"` and a non-empty `observed` (`scripts/check_evidence.sh`).

## Closure (`validate_ledger_closed.sh`)

`validate_ledger_closed.sh LEDGER [--require-evidence] [--allow-degraded]` runs the DAG validator, then requires every task `verified` (with `execution_outcome: succeeded`, an observed `runtime_status` and evidence refs) and, with `--require-evidence`, the report and evidence files to exist and satisfy the gate. With `--allow-degraded`, `failed`, `blocked`, `partial`, `cancelled` and `interrupted` tasks pass when `notas` is non-empty; `pending`, `completed` and active states are always rejected, as is a ledger with no tasks. Exit `0` pass, `1` validation failure, `2` usage/environment. `orch.sh close` runs it from `run.workspace.directory`.

## Accepted YAML subset

- Root is a map; two-space indentation per level (run blocks at 2 and 4 spaces, task list elements at 2, task fields at 4).
- Strings are double-quoted and use only the escapes `\\` and `\"`.
- `null` is the only null; integers are positive; lists are flow lists of quoted strings (`["a", "b"]`, `[]`).
- `#` starts a comment when preceded by whitespace.
- UTF-8; a BOM is tolerated; LF or CRLF line endings.
