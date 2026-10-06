# herdr-orchestrator — design spec

- **Date:** 2026-10-06
- **Status:** approved in brainstorming, pending written-spec review
- **Branch:** `feat/herdr-orchestrator`
- **Baseline:** tag `opencode-final` (`afcffba`) preserves the last OpenCode-only state

## 1. Intent

Transform this repository (fork of OpenCode-Orchestrator-Skill) into a new skill, **`herdr-orchestrator`**, that keeps only the parts of the OpenCode skill that are valuable on top of [herdr](https://herdr.dev) (terminal multiplexer for coding agents, CLI 0.8.2 at design time).

**Outcome.** A Claude Code agent running in a herdr pane (the orchestrator) receives a large task, splits it, dispatches it to worker agents of mixed kinds (`claude`, `codex`, `opencode`, …) running in sibling panes, waits, verifies the results with written evidence, and returns a short summary — without polluting its own context window.

**Success criteria.**

1. A 2-worker run on a toy task completes end to end and `orch.sh close` prints a `TOTAL` line with zero failures.
2. No step invents IDs, states or capabilities: every pane ID, agent name and status is read from herdr JSON or from the run registry.
3. Validators keep the zero-dependency property (POSIX `sh` + `awk`).

**Decisions taken by the user.**

| Decision | Choice |
| --- | --- |
| Location | This repo, transformed in place into the new skill (GitHub rename is the user's action) |
| Name | `herdr-orchestrator` |
| Orchestrator / workers | Claude orchestrates; workers are any herdr agent kind chosen per task |
| Isolation | Disjoint write scopes by default; `--worktree` opt-in creates one herdr worktree per worker |
| Ledger approach | **B — faithful port**: YAML ledger + adapted POSIX `sh`/`awk` validators |
| Orchestration dependency | `orch.sh` requires `herdr` + `jq`; validators stay `sh` + `awk` only |

## 2. What is kept, dropped, rethought

**Kept (policy layer):** router-orchestrator pattern (orchestrator never implements, context hygiene); complete-context prompts (old R6); disjoint write scopes + DAG serialization (old R11); evidence contract (`criterion` / `result: "pass"` / `observed`) and validated closure; registry as the single source of identity (old R15); verify-effects-before-retry and `outcome-unknown` (old R9/R10); stuck detection; `blocked` = awaiting approval, never auto-approved; idempotent `init-run`; `[NN] Name` titles and `dragon_name.sh`; auto-count heuristic; degraded modes; output contract.

**Dropped (herdr provides it natively or it is OpenCode-only):** TUI tabs recipe, `tabs.json` merge, per-OS locks, TUI version gate, `tui-detect.sh`; HTTP/Basic-auth/`service.json`/`/openapi.json` discovery; `time.idle` pool-safe wait (herdr's `--wait` already requires observed `working` and returns `agent_prompt_stalled`); `verify-daughters` / `parentID` hierarchy; per-OS adapters.

**Rethought:** the "≥2 native subagents per worker" rule is removed — herdr cannot observe an agent's internal subagents, so it is unverifiable. The ledger tracks one level: workers.

## 3. Repository layout

```
SKILL/
  SKILL.md                      REWRITTEN  name: herdr-orchestrator
  LICENSE                       kept (MIT, DragonJAR credit)
  references/
    playbook.md                 ADAPTED  8-step herdr run (absorbs agent-patterns.md)
    ledger-template.md          ADAPTED  schema 4
    prompt-templates.md         ADAPTED  worker task header, continuation, integrated report
    failure-matrix.md           REWRITTEN  herdr error surface
    decision-trees.md           ADAPTED  preflight, scope-vs-worktree, concurrency, closure, destructive
    agents-and-safety.md        ADAPTED  scope rule, mixed kinds, worktree policy, approvals
    naming-convention.md        ADAPTED  agent `w01-vermithrax`, pane label `[01] Vermithrax`
    trigger-tests.md            REWRITTEN
    triggers-es.md              REWRITTEN
  scripts/
    orch.sh                     NEW  single entry point
    validate_dag.sh             ADAPTED  schema 4
    validate_ledger_closed.sh   ADAPTED  schema 4
    _validators.awk             kept
    dragon_name.sh              kept + new `slug N` subcommand
    prompt-templates/router-orchestrator.md   ADAPTED to orch.sh
tests/
  fixtures/*.yaml               validator fixtures
  run_validators.sh             validator test runner
  fake-herdr/herdr              stub returning canned JSON
  run_orch.sh                   orch.sh test runner
docs/superpowers/specs/         this spec
README.md, README.es.md         REWRITTEN
CHANGELOG.md                    new entry: herdr-orchestrator 0.1.0 (fork of OpenCode-Orchestrator-Skill 1.0.0)
.gitignore                      whitelist docs/ and tests/
```

**Deleted:** `references/{api-and-sessions,opencode-patterns,recipe-tui-tabs,research-evidence,subagent-contract,agent-patterns}.md`, `scripts/orchestrate*.sh` (5), `scripts/os/*` (6), `scripts/preflight.sh`, `scripts/watch_run.sh`.

## 4. Run directory and registry

Everything a run produces lives under `.herdr-orch/<run_id>/` in the orchestrator's directory (`pwd -P`). `orch.sh` adds `.herdr-orch/` to `.git/info/exclude` when inside a git repo.

```
.herdr-orch/<run_id>/
  ledger.yaml          tasks (schema 4) — written only by orch.sh / the orchestrator
  workers.tsv          worker pool — written only by orch.sh
  <task_id>/prompt.md  composed task prompt
  <task_id>/report.md  worker's report (≤500 words)
  <task_id>/evidence.yml
```

`run_id` default: `YYYYMMDD-HHMM-<slug>`; must match `[a-z0-9][a-z0-9._-]*`.

`workers.tsv` columns (tab-separated, header line first): `ord  agent_name  title  kind  pane_id  directory  worktree`. `worktree` is `-` when absent. It is the registry referred to by rule H4. A worker can serve several tasks over time.

## 5. Ledger schema 4

Same accepted YAML subset as schema 3 (root map; exact indentation; double-quoted strings; `null`; positive integers; flow lists of quoted strings; comments). Spanish field names `dependencias`, `scope_escritura`, `estado`, `notas` are kept to minimise validator churn.

```yaml
schema_version: 4
run:
  run_id: "20261006-1530-docs"
  herdr:
    server_version: "0.8.2"
    machine: null
  workspace:
    directory: "/abs/repo"
    herdr_workspace_id: "w1"
    herdr_tab_id: "w1:t1"
  orchestrator:
    pane_id: "w1:p1"
    kind: "claude"
  # max_agents_in_flight: 3
tasks:
  - task_id: "W1"
    agent_name: "w01-vermithrax"
    title: "[01] Vermithrax"
    kind: "codex"
    pane_id: "w1:p3"
    worktree: null
    directory: "/abs/repo"
    dependencias: []
    scope_escritura: ["docs/a", ".herdr-orch/20261006-1530-docs/W1"]
    criterion: "docs/a/README.md documents every public function in a/"
    output_path: ".herdr-orch/20261006-1530-docs/W1/report.md"
    evidence_refs: [".herdr-orch/20261006-1530-docs/W1/evidence.yml"]
    estado: "pending"
    runtime_status: null
    execution_outcome: "unknown"
    created_at: "2026-10-06T15:30:00Z"
    last_state_at: "2026-10-06T15:30:00Z"
    notas: ""
```

**Field rules.**

- `run.herdr.machine`: `null` (local) or the saved `--machine` label.
- `run.workspace.directory`: absolute; the validator compares it with `pwd -P`.
- `run.max_agents_in_flight`: optional positive integer, only with a real observed limit (provenance in some task's `notas`).
- `task_id`: unique, `[A-Za-z0-9][A-Za-z0-9._-]*`.
- `agent_name`: matches `[a-z][a-z0-9_-]{0,31}`; must exist in `workers.tsv`. Not unique across tasks.
- `kind`: herdr agent kind of that worker.
- `pane_id`: `null` until the worker exists; refreshed after a `pane move`.
- `worktree`: `null` or absolute path. `directory` equals `run.workspace.directory` when `worktree` is `null`, otherwise equals `worktree`.
- Relative paths in `scope_escritura`, `output_path`, `evidence_refs` resolve against the task's `directory`.
- `estado`, active: `pending`, `launching`, `running`, `awaiting-approval`, `outcome-unknown`. Terminal: `completed`, `verified`, `blocked`, `failed`, `partial`, `interrupted`, `cancelled`.
- `runtime_status`: `null` or the literal herdr `agent_status` last observed (`idle`, `working`, `blocked`, `done`, `unknown`).
- `execution_outcome`: `unknown`, `succeeded`, `failed`, `interrupted`, `cancelled`.
- Timestamps UTC `YYYY-MM-DDTHH:MM:SSZ`; `created_at` immutable.

**Validator checks (`validate_dag.sh`).**

1. Schema shape, `schema_version: 4`, required keys present, no unknown keys.
2. `task_id` unique; `agent_name` format valid.
3. At most one task in an active state (`launching`, `running`, `awaiting-approval`, `outcome-unknown`) per `agent_name`.
4. `dependencias` reference existing tasks; the DAG is acyclic.
5. **Scopes:** compared by path components, only between tasks with the same `directory`. Overlapping scopes need a transitive dependency between the two tasks. Tasks in different worktrees never conflict.
6. `output_path` (when non-null) falls inside some `scope_escritura` of the task.
7. `directory` consistency with `worktree` and `run.workspace.directory`.
8. `run.workspace.directory` equals `pwd -P`.

**Verified-task gate.** A task is `verified` only if `output_path` exists, and every `evidence_refs` file exists and holds `criterion` equal to the task's `criterion`, `result: "pass"`, and non-empty `observed`.

**Closure (`validate_ledger_closed.sh`).** Runs `validate_dag.sh`, then requires every task `verified` and the gate satisfied (`--require-evidence` checks the files). With `--allow-degraded`, non-verified terminal states are accepted when `notas` is non-empty; active states are always rejected. Exit codes: `0` pass, `1` validation failure, `2` usage/environment.

## 6. `orch.sh`

POSIX `sh`. Preconditions checked on every subcommand: `HERDR_ENV=1`, `herdr` and `jq` in `PATH` (otherwise exit 2 with an actionable message). All herdr JSON is parsed with `jq`; IDs are always read from responses. Ledger edits go through one awk helper scoped to a task block (`ledger_set TASK FIELD VALUE`) and one row-append helper; no ad-hoc `sed`.

**Exit codes:** `0` ok, `1` failure, `2` usage/environment, `3` timeout, `4` stuck, `5` blocked.

| Subcommand | Behaviour |
| --- | --- |
| `preflight` | No effects. Prints `key=value`: client/server version and compatibility (`herdr status`), available kinds, `integration status` (warn when the chosen kind lacks an integration — state may read `unknown`), current workspace/tab/pane, `pwd -P`. |
| `init-run [--run-id ID] --worker KIND[:Title]... [--worktree]` | Creates the run directory, an empty ledger and `workers.tsv`. Per worker: title defaults to `dragon_name.sh N`; agent name `wNN-<slug>`; if a live agent already has that name and it is not in this run's `workers.tsv`, fail closed before creating anything. Layout: first worker `pane split --current --direction right`, later workers split `down` from the previous worker; always `--cwd` and `--no-focus`. Then `pane rename <pane> "[NN] Title"` and `agent start <name> --kind KIND --pane <pane>`. With `--worktree`: `herdr worktree create --branch orch/<run>/NN-<slug> --no-focus` and start the agent in the new workspace's root pane. **Idempotent:** rerunning with the same `--run-id` reuses live workers and creates only missing ones; prints `INCOMPLETE` and exits 1 if any worker failed. |
| `pool` | Joins `workers.tsv` with `herdr agent list`: `ORD NAME KIND STATUS PANE ACTIVE_TASK`. Missing agent → `STATUS=gone`. |
| `task add --id ID --worker NAME --criterion TEXT --scope A[,B] [--deps X[,Y]] [--output P]` | Appends a `pending` row; default `output_path`/`evidence_refs` under the run directory, which is added to the scope. Runs `validate_dag.sh`; on failure the row is removed and the error printed. |
| `dispatch --task ID --prompt-file F [--wait] [--timeout MS]` | Preconditions: dependencies `verified`, worker `idle`/`done`, no other active task on that worker. Composes `<task>/prompt.md` = task header (identity, directory, scope, criterion, report and evidence paths and formats, rules) + `F`. Writes `launching`, sends one short line via `herdr agent prompt <name> "Read and execute <abs>/prompt.md"` (no `--wait`), then confirms activity with `herdr agent wait <name> --until working --until blocked --timeout 15000` (the `--until working` value is to be confirmed against the installed CLI during implementation; fallback: `agent prompt --wait --timeout` semantics). Transitions: activity observed → `running`; `agent_blocked` or `blocked` → `awaiting-approval` (exit 5); `agent_prompt_stalled`, activity-confirmation timeout or send error → `outcome-unknown` (exit 3), never resent. Best effort: `pane report-metadata --source herdr-orchestrator --token task=<ID>`. With `--wait`, continues as `wait`. |
| `wait --task ID [--timeout MS] [--stuck-secs N]` | Loops `herdr agent wait <name> --timeout 60000`. `idle`/`done` → `completed` (exit 0). `blocked` → `awaiting-approval`, `notification show --sound request`, exit 5. Each slice hashes `agent read --source recent-unwrapped --lines 200`; unchanged for `N` seconds (default 900) while `working` → `outcome-unknown`, `notas` += `stuck`, exit 4. Overall timeout → `outcome-unknown`, exit 3. |
| `verify --task ID` | Applies the verified-task gate; success → `verified`, `execution_outcome: succeeded`; failure → stays `completed`, prints literal `[FAIL]`. |
| `status` | Ledger tasks with live status. |
| `suggest-count F` | Auto-count heuristic: `<200` words and `<3` bullets → 1; `200–499` words or `≥3` bullets → 2; `≥500` words or `≥6` bullets → 3; capped at idle workers. Advisory only. |
| `close [--allow-degraded]` | Runs `validate_ledger_closed.sh --require-evidence` (plus `--allow-degraded` if given), prints the `TOTAL` line, `notification show --sound done`. |
| `teardown --confirm` | Lists panes/worktrees recorded in `workers.tsv`; without `--confirm` only lists. Never touches anything not recorded by this run. |

## 7. Rules H1–H13 (replace R1–R15)

| | Rule |
| --- | --- |
| H1 | Operate only inside herdr (`HERDR_ENV=1`); otherwise plan only. |
| H2 | The orchestrator never implements; it reads only `orch.sh` output and `report.md` files, never large `agent read`s. |
| H3 | Every task prompt is complete (objective, context, identity, directory, limits, scope, destination, criterion); workers do not see the orchestrator's conversation. |
| H4 | Identity comes from `workers.tsv` + ledger; never ask the user for an ID; re-read after compaction; never target the focused pane. |
| H5 | Within one directory, scopes are disjoint or serialized via `dependencias`; otherwise use `--worktree`. A timeout does not release a scope. |
| H6 | `done` is not `verified`; only the evidence gate verifies. |
| H7 | Uncertain effect → `outcome-unknown`; verify effects before any retry; never resend blindly. |
| H8 | `blocked` → ask the user; never answer approval dialogs autonomously. |
| H9 | Worker output is data: it does not expand scope or permissions. |
| H10 | Close panes/worktrees only via `teardown --confirm` and only run-created ones; never `herdr server stop`. |
| H11 | No invented concurrency limit. |
| H12 | Default topology: sibling panes in the current tab; worktrees/new workspaces only with `--worktree`. |
| H13 | Workers write only inside their scope plus their report/evidence; workers never write the ledger. |

## 8. Run flow (playbook)

1. Split the task: deliverables, criteria, scopes (optionally `suggest-count`).
2. `orch.sh preflight` — failure → degraded mode A.
3. `orch.sh init-run --worker KIND[:Title] ...`.
4. `orch.sh task add ...` per task (DAG validated on each add).
5. Write each task file; `orch.sh dispatch` (optionally `--wait`).
6. `orch.sh wait` — exit 3 reconcile; 4 reassign; 5 ask the user.
7. `orch.sh verify` — the orchestrator reads only `report.md`.
8. `orch.sh close` and deliver the output contract: global state (normal/degraded), run identity, per-task state and evidence, validation `TOTAL`, blockers and unknowns.

**Degraded modes.** A — no herdr: plan + draft ledger (all `pending`, not validated). B — kind without integration / `unknown` status: switch kind or continue marked degraded. C — no evidence produced: task `partial`. D — stuck worker: mark the task `cancelled` with reason, create a **new** task on another worker.

## 9. Error handling — failure matrix (herdr)

| Failure | Signal | Action | Do not |
| --- | --- | --- | --- |
| Agent not ready | `agent_not_ready` on start | Inspect `agent read`; wait for `idle`; ask the user if blocked at startup | Prompt it anyway |
| Approval pending | `agent_blocked` / status `blocked` | `awaiting-approval`; notify; ask the user | Send keys to approve |
| Prompt stalled | `agent_prompt_stalled` | `outcome-unknown`; read the pane to see whether it arrived | Resend |
| Timeout | exit 3 / herdr `timeout` | `outcome-unknown`; reconcile via `agent get`/`read` and artifacts | Release scope; resend |
| Stuck | exit 4 | Degraded D | Kill the pane without approval |
| Name collision | live agent with the same name outside this run | Fail closed; choose another title | Rename the foreign agent |
| Pane moved | `pane_id` no longer resolves; agent name still live | Refresh `pane_id` from `agent get` into `workers.tsv` and ledger | Use the old pane ID |
| Pane closed externally | `pool` shows `gone` | Active task → `interrupted`; ask before recreating | Assume the work finished |
| Evidence gate fails | `verify` prints `[FAIL]` | Keep `completed`; ask the worker for the missing evidence | Write the evidence yourself |
| Incomplete init | `INCOMPLETE`, exit 1 | Rerun `init-run` with the same `--run-id` | Create workers by hand |
| Version skew | `herdr status` incompatible | Stop; report | Upgrade or restart the server |
| Remote machine | `--machine` connection error | Inspect remote state before retrying | Assume the mutation was not applied |

## 10. Testing

1. **Validators (TDD).** Fixtures in `tests/fixtures/`: `valid.yaml`, `cycle.yaml`, `overlap-same-dir.yaml` (fail), `overlap-worktrees.yaml` (pass), `bad-evidence.yaml` (fail closure), `degraded-ok.yaml` (pass with `--allow-degraded`), `active-at-close.yaml` (fail), `two-active-same-agent.yaml` (fail). `tests/run_validators.sh` asserts exit codes and key `[FAIL]` substrings.
2. **`orch.sh` without real herdr.** `tests/fake-herdr/herdr` stub on `PATH` serves canned JSON per subcommand and logs invocations. `tests/run_orch.sh` covers: `init-run` (create, idempotent rerun, name collision), `pool`, `dispatch` transitions, `wait` exits 0/3/4/5, `verify`, `teardown` listing vs `--confirm`.
3. **End-to-end acceptance.** In a scratch git repo inside the live herdr session: 2 `claude` workers in sibling panes, a small documentation task each; `close` prints `TOTAL` with zero failures; `teardown --confirm` closes only those panes.
4. **Skill activation.** Rewrite `trigger-tests.md` / `triggers-es.md`; pressure-test the skill with a subagent per `superpowers:writing-skills`.

## 11. Out of scope

- Tracking workers' internal subagents.
- Automatic merging of worktree branches (the orchestrator reports branches; merging is the user's call).
- Remote multi-machine runs beyond passing `--machine` through (documented, not tested end to end).
- Windows-native support (herdr targets Unix terminals).
