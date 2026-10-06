# herdr-orchestrator — design spec

- **Date:** 2026-10-06
- **Status:** approved in brainstorming; revised after an adversarial review (fable) — rev 2
- **Revision 3 (implementation):** §5 state machine and §6 rows updated to match the shipped code (`launching>pending`, reconcile delivery rule, `--agent-arg`, wait error exit, teardown behaviours, preflight template check, suggest-count outside herdr); the code is the source of truth.
- **Branch:** `feat/herdr-orchestrator`
- **Baseline:** tag `opencode-final` (`afcffba`) preserves the last OpenCode-only state
- **Target:** herdr CLI 0.8.2, protocol 20 (facts in §12 verified against the live CLI)

## 1. Intent

Transform this repository (fork of OpenCode-Orchestrator-Skill) into a new skill, **`herdr-orchestrator`**, that keeps only the parts of the OpenCode skill that are valuable on top of [herdr](https://herdr.dev) (terminal multiplexer for coding agents).

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
| Isolation | Disjoint write scopes by default; `--worktree` opt-in (only when the user asks) creates one herdr worktree per worker |
| Ledger approach | **B — faithful port**: YAML ledger + adapted POSIX `sh`/`awk` validators |
| Orchestration dependency | `orch.sh` requires `herdr` + `jq`; validators stay `sh` + `awk` only |

## 2. What is kept, dropped, rethought

**Kept (policy layer):** router-orchestrator pattern (orchestrator never implements, context hygiene); complete-context prompts (old R6); disjoint write scopes + DAG serialization (old R11); evidence contract (`criterion` / `result: "pass"` / `observed`) and validated closure; registry as the single source of identity (old R15); verify-effects-before-retry and `outcome-unknown` (old R9/R10); stuck detection (advisory); `blocked` = awaiting approval, never auto-approved; idempotent `init-run`; `[NN] Name` titles and `dragon_name.sh`; auto-count heuristic; degraded modes; output contract.

**Dropped (herdr provides it natively, or OpenCode-only, or out of scope):** TUI tabs recipe, `tabs.json` merge, per-OS locks, TUI version gate, `tui-detect.sh`; HTTP/Basic-auth/`service.json`/`/openapi.json` discovery; `time.idle` pool-safe wait (herdr's `agent prompt --wait` already gates on observed activity); `verify-daughters` / `parentID` hierarchy; per-OS adapters; Windows drive-letter/UNC path handling in the validators (~120 lines).

**Rethought:** the "≥2 native subagents per worker" rule is removed — herdr cannot observe an agent's internal subagents, so it is unverifiable. The ledger tracks one level: workers' tasks.

**Deferred (YAGNI for 0.1.0):** `pane report-metadata` sidebar tokens, `run.max_agents_in_flight`, a separate `status` subcommand (merged into `pool`), multi-machine runs (`--machine` does not exist in 0.8.2; only `--remote` attach), automatic merging of worktree branches.

## 3. Repository layout

```
SKILL/
  SKILL.md                      REWRITTEN  name: herdr-orchestrator
  LICENSE                       kept (MIT, DragonJAR credit)
  references/
    playbook.md                 ADAPTED  8-step herdr run (absorbs agent-patterns.md)
    ledger-template.md          ADAPTED  schema 4 + state machine
    prompt-templates.md         ADAPTED  worker task header, continuation, integrated report
    failure-matrix.md           REWRITTEN  herdr error surface
    decision-trees.md           ADAPTED  preflight, scope-vs-worktree, closure, destructive
    agents-and-safety.md        ADAPTED  scope rule, mixed kinds, worktree policy, approvals
    naming-convention.md        ADAPTED  agent `w01-vermithrax-k3f9`, pane label `[01] Vermithrax`
    trigger-tests.md            REWRITTEN
    triggers-es.md              REWRITTEN
  scripts/
    orch.sh                     NEW  single entry point
    validate_dag.sh             ADAPTED  schema 4
    validate_ledger_closed.sh   ADAPTED  schema 4
    _validators.awk             kept (shared helpers)
    dragon_name.sh              kept unchanged (title catalog)
    lib/orch_common.sh          env checks, run resolution, YAML quoting, lock, slugify
    lib/orch_ledger.sh          ledger + workers.tsv read/write helpers
    lib/orch_herdr.sh           herdr call wrapper and error-code mapping
    prompt-templates/task-header.md   header prepended to every task prompt
    prompt-templates/router-orchestrator.md   ADAPTED to orch.sh
tests/
  fixtures/*.yaml               validator fixtures
  run_validators.sh             validator test runner
  fake-herdr/herdr              stub returning canned JSON (scenario-driven)
  run_orch.sh                   orch.sh test runner
docs/superpowers/specs/         this spec
README.md, README.es.md         REWRITTEN
CHANGELOG.md                    new entry: herdr-orchestrator 0.1.0 (fork of OpenCode-Orchestrator-Skill 1.0.0)
.gitignore                      whitelist docs/ and tests/ (done)
```

**Deleted:** `references/{api-and-sessions,opencode-patterns,recipe-tui-tabs,research-evidence,subagent-contract,agent-patterns}.md`, `scripts/orchestrate*.sh` (5), `scripts/os/*` (6), `scripts/preflight.sh`, `scripts/watch_run.sh`.

## 4. Run directory, path model and registry

Everything a run produces lives under the **run directory** `RUN_DIR = <orchestrator pwd -P>/.herdr-orch/<run_id>/`. `orch.sh` adds `.herdr-orch/` to `.git/info/exclude` when inside a git repo (the exclude lives in the common git dir, so it also covers linked worktrees).

```
RUN_DIR/
  ledger.yaml          tasks (schema 4) — written only by orch.sh
  workers.tsv          worker pool — written only by orch.sh
  .lock/               mkdir-based write lock
  <task_id>/prompt.md  composed task prompt
  <task_id>/report.md  worker's report (≤500 words)
  <task_id>/evidence.yml
```

`run_id` default: `YYYYMMDD-HHMM-<slug>`; must match `[a-z0-9][a-z0-9._-]*`.

**Path model (single rule).**

- `output_path` and `evidence_refs` are **absolute paths under `RUN_DIR/<task_id>/`**, for every task including worktree tasks. Reports and evidence therefore always live in the orchestrator's tree, survive worktree removal, and are reachable by the closure gate.
- Each task's `scope_escritura` always contains the absolute `RUN_DIR/<task_id>` entry, plus the task's work scopes.
- Relative paths in `scope_escritura` resolve against the task's `directory`. Absolute paths are accepted only when they fall under `run.workspace.directory` or under the task's own `directory`.
- Every scope entry is canonicalised to an absolute path before comparison. Two tasks conflict only if their canonical scopes overlap by path components. Because a worktree task's relative scopes canonicalise under its worktree path, tasks in different worktrees never conflict — no special "same directory" filter is needed.

**Registry.** `workers.tsv` (tab-separated, header line first) columns: `ord  agent_name  title  kind  workspace_id  pane_id  directory  worktree`. `worktree` is `-` when absent. It is the registry referred to by rule H4. A worker can serve several tasks over time (not concurrently).

**Write discipline.** Every write to `ledger.yaml` or `workers.tsv` happens under the lock (`mkdir RUN_DIR/.lock`, retry every 0.5 s for up to 60 s, then fail with the lock's path and age so the user can remove a stale lock by hand) and is written to a temp file in `RUN_DIR` then `mv`'d into place. Ledger edits go through one awk helper scoped to a task block (`ledger_set TASK FIELD VALUE`) and one row-append helper; no ad-hoc `sed`.

## 5. Ledger schema 4

Same accepted YAML subset as schema 3 (root map; exact indentation; double-quoted strings; `null`; positive integers; flow lists of quoted strings; comments). Spanish field names `dependencias`, `scope_escritura`, `estado`, `notas` are kept to minimise validator churn. Unknown keys are rejected.

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

**Field rules.**

- `run.herdr.server_version`: from `herdr status --json` → `.server.version`.
- `run.workspace.directory`: absolute; must equal the validator's `pwd -P`.
- `task_id`: unique, `[A-Za-z0-9][A-Za-z0-9._-]*`.
- `agent_name`: matches `[a-z][a-z0-9_-]{0,31}`; must exist in `workers.tsv`. Not unique across tasks.
- `title`: the worker's pane label `[NN] Name`, copied from `workers.tsv`.
- `kind`: herdr agent kind of that worker.
- `pane_id`: copied from `workers.tsv`; refreshed after a `pane move`.
- `worktree`: `null` or absolute path. `directory` equals `run.workspace.directory` when `worktree` is `null`, otherwise equals `worktree`.
- `output_path`: absolute, under `RUN_DIR/<task_id>/`. `evidence_refs`: non-empty list of absolute paths under `RUN_DIR/<task_id>/`.
- `runtime_status`: `null` or the literal herdr `agent_status` last observed (`idle`, `working`, `blocked`, `done`, `unknown`).
- `execution_outcome`: `unknown`, `succeeded`, `failed`, `interrupted`, `cancelled`.
- Timestamps UTC `YYYY-MM-DDTHH:MM:SSZ`; `created_at` immutable.

**State machine.** Active states: `launching`, `running`, `awaiting-approval`, `outcome-unknown`. Terminal states: `verified`, `blocked`, `failed`, `partial`, `interrupted`, `cancelled`. `pending` and `completed` are resting states.

| From | To | Written by | Notes |
| --- | --- | --- | --- |
| `pending` | `launching` | `dispatch` | before sending |
| `launching` | `running` / `completed` / `awaiting-approval` / `outcome-unknown` | `dispatch` | mapping in §6 |
| `launching` | `pending` | `reconcile` | only under the delivery rule in §6 (a dispatch that never reached the worker) |
| `running`, `awaiting-approval` | `running` / `awaiting-approval` / `completed` / `outcome-unknown` / `interrupted` | `wait`, `reconcile` | self-transitions allowed |
| `outcome-unknown` | `running` / `completed` / `awaiting-approval` / `interrupted` / `pending` | `reconcile` | `pending` only under the delivery rule (§6) |
| `completed` | `verified` | `verify` | gate in this section |
| any non-terminal | `cancelled` / `failed` / `partial` / `blocked` / `interrupted` | `task set` | `notas` required |
| terminal | — | — | no transitions; reassignment creates a new task |

`execution_outcome` is set to `succeeded` when the task reaches `completed` (the agent settled), `interrupted`/`cancelled`/`failed` with the matching terminal state, and stays `unknown` otherwise. `verify` changes only `estado`. `completed` requires `execution_outcome: succeeded`.

**Validator checks (`validate_dag.sh`).**

1. Schema shape, `schema_version: 4`, required keys present, no unknown keys, scalar formats.
2. `task_id` unique; `agent_name` format valid.
3. At most one task in an active state per `agent_name`.
4. `dependencias` reference existing tasks; the DAG is acyclic; a task in an active or post-active state (`launching` onward) has all dependencies `verified`.
5. **Scopes:** canonical scopes (per §4) of two tasks must not overlap unless one transitively depends on the other. Tasks in a terminal non-verified state (`blocked`, `failed`, `partial`, `interrupted`, `cancelled`) are excluded from the overlap check and must have non-empty `notas` (effects reconciled) — this is what makes reassignment possible (Degraded D); they release their scope, so ask the user to stop the worker first if it may still be writing.
6. `output_path` and every `evidence_refs` entry are absolute and under `RUN_DIR/<task_id>/`, and fall inside some `scope_escritura` entry of the task.
7. `directory` consistency with `worktree` and `run.workspace.directory`.
8. `run.workspace.directory` equals `pwd -P`.
9. `completed` ⇒ `execution_outcome: succeeded`; terminal non-verified states ⇒ non-empty `notas`.

**Verified-task gate.** A task is `verified` only if `output_path` exists, and every `evidence_refs` file exists and holds `criterion` equal to the task's `criterion`, `result: "pass"`, and non-empty `observed`.

**Closure (`validate_ledger_closed.sh`).** Runs `validate_dag.sh`, then requires every task `verified` and the gate satisfied (`--require-evidence` checks the files). With `--allow-degraded`, non-verified terminal states are accepted when `notas` is non-empty; active, `pending` and `completed` states are always rejected. Exit codes: `0` pass, `1` validation failure, `2` usage/environment.

## 6. `orch.sh`

POSIX `sh`. Preconditions checked on every subcommand: `HERDR_ENV=1`, `herdr` and `jq` in `PATH` (otherwise exit 2 with an actionable message). All herdr JSON is parsed with `jq`, tolerating optional fields (e.g. `.name // empty`); IDs are always read from responses. herdr server errors arrive as JSON on stderr with exit 1 (`.error.code`); `orch.sh` maps codes, never parses free text. Internal pane reads may be large, but `orch.sh` prints only verdicts, never raw pane content.

**Exit codes:** `0` ok, `1` failure, `2` usage/environment, `3` outcome unknown / timeout, `4` stuck (advisory), `5` awaiting approval.

| Subcommand | Behaviour |
| --- | --- |
| `preflight` | No effects. Prints `key=value`: `herdr status --json` (`.server.compatible`, `.server.version`, `.client.version`), the kinds list from `herdr agent` help, `template=ok|missing` (the task-header template must be readable; missing is exit 2), current workspace/tab/pane (`pane current --current`), `pwd -P`, git repo yes/no, and a final `gate=ready` (or `gate=blocked reason=…`). Exit 2 when not compatible. The text-only `integration status` is not parsed. |
| `init-run [--run-id ID] --worker KIND[:Title]... [--worktree] [--agent-arg ARG]...` | `--agent-arg` (repeatable, non-empty, no newline) is passed after `--` to `herdr agent start` for every worker, e.g. `--permission-mode auto`; it does not answer trust dialogs. Unknown kinds (per the `herdr agent` kinds list) are rejected. Creates `RUN_DIR`, an empty ledger and `workers.tsv`. Per worker: title defaults to `dragon_name.sh N`; agent name `wNN-<slug≤20>-<sfx4>` (`slugify` in `lib/orch_common.sh`) where `sfx4` is derived deterministically from `run_id` (avoids collisions between runs on one server). If a live agent already has that name and it is not in this run's `workers.tsv`, fail closed before creating anything. **Layout:** first worker `pane split --current --direction right`; workers 2–3 split `down` from the previous worker (one column of up to 3); worker 4+ starts a new column by splitting `right` from the top worker of the last column. Always `--cwd` and `--no-focus`. The `workers.tsv` row is recorded **immediately after the split succeeds**, then `pane rename <pane> "[NN] Title"`, a shell-readiness check (`pane process-info`: shell in foreground), and `agent start <name> --kind KIND --pane <pane>`. With `--worktree` (only when the user asked): `herdr worktree create --branch orch/<run>/NN-<slug> --no-focus`; take `.result.root_pane.pane_id` when present, otherwise the single pane from `pane list --workspace <id>`; record `workspace_id` and `worktree`. **Idempotent:** rerunning with the same `--run-id` reuses live agents, starts agents in recorded panes that still exist with a shell in foreground, and creates only what is missing; prints `INCOMPLETE` and exits 1 if any worker failed (`agent_not_ready` included — e.g. a Claude folder-trust dialog in a fresh worktree, which the user answers in that pane). |
| `pool` | Joins `workers.tsv` with `herdr agent list` and the ledger: `ORD NAME KIND STATUS PANE TASK ESTADO`. Missing agent → `STATUS=gone`. |
| `task add --id ID --worker NAME --criterion TEXT --scope A[,B] [--deps X[,Y]]` | Appends a `pending` row with `output_path`/`evidence_refs` under `RUN_DIR/<ID>/` and that directory added to the scope. Runs `validate_dag.sh`; on failure the row is removed (under the lock) and the `[FAIL]` printed. |
| `task set --task ID --estado S --notas TEXT` | Guarded manual transition to `cancelled`/`failed`/`partial`/`blocked`/`interrupted` (table in §5); `notas` required; updates `last_state_at` and `execution_outcome`. |
| `dispatch --task ID --prompt-file F [--wait] [--timeout MS]` | Preconditions: task `pending`, dependencies `verified`, worker `idle`/`done`, no other active task on that worker. Composes `RUN_DIR/<ID>/prompt.md` = task header (identity, directory, scope, criterion, absolute report and evidence paths and formats, rules) + `F`. Writes `launching`, then sends one line with a marker: `herdr agent prompt <name> "[herdr-orch <run>/<ID>] Read and execute <abs>/prompt.md" --wait --timeout 15000`. Mapping: settled `idle`/`done` → `completed` (exit 0); settled `blocked` → `awaiting-approval` (exit 5); error `agent_blocked` (herdr rejected the prompt **before sending** because the agent sits at an approval dialog) → `outcome-unknown` with `notas` "prompt not sent: agent at approval dialog" and exit 5, so that after the user resolves the dialog `reconcile` returns the task to `pending`; error `timeout` (activity observed, not yet settled) → `running` (exit 0); error `agent_prompt_stalled` → `outcome-unknown` with `notas` "prompt sent: agent_prompt_stalled", any other send error → `outcome-unknown` with `notas` "send uncertain: <code>" (exit 3), never resent. Success paths record `notas` "prompt sent". A task left in `launching` is not re-dispatched: `reconcile` it. With `--wait`, a `running` result continues as `wait`. |
| `wait --task ID [--timeout MS] [--stuck-secs N]` | Loops `herdr agent wait <name> --timeout 60000`. `idle`/`done` → `completed` (exit 0). `blocked` → `awaiting-approval`, `notification show --sound request`, exit 5. `agent_not_found` → `interrupted` with `notas` "agent gone", exit 1. Three consecutive slices with a herdr error (not `agent_not_found`) → exit 1, `estado` unchanged. Overall timeout → `outcome-unknown`, exit 3. **Stuck (advisory):** each slice hashes a normalised `agent read --source recent-unwrapped --lines 200` (last 3 lines dropped, digits stripped, to ignore spinners and timers); if unchanged for `N` seconds (default 1800) only while `working`, prints `stuck` and exits 4 **without changing `estado`** — the orchestrator decides (Degraded D). |
| `reconcile --task ID` | For `launching`/`outcome-unknown`/`running`/`awaiting-approval`: reads `agent get` and checks `output_path`. Agent gone → `interrupted`; `working` → `running`; `blocked` → `awaiting-approval` (exit 5); `idle`/`done` with the report present → `completed`. `idle`/`done` without a report: an internal pane read (`--lines 400`) is searched for the task marker; marker seen → `completed` ("prompt seen, no report yet"). **Delivery rule:** otherwise the task returns to `pending` ("reconciled: prompt not delivered", `runtime_status` cleared) only when the current attempt's `notas` (text after the last such reset) show `prompt not sent`, or show neither `prompt sent` nor `prompt not sent` and no `runtime_status` was ever observed; in every other case it becomes `completed` with "delivered earlier; no report". Any other status, a failed pane read or a forbidden transition: exit 3, unchanged. Prints the verdict only. |
| `verify --task ID` | Applies the verified-task gate; success → `verified`; failure → stays `completed`, prints the literal `[FAIL]`. |
| `suggest-count F` | Works without herdr (no `HERDR_ENV` needed). Auto-count heuristic: `<200` words and `<3` bullets → 1; `200–499` words or `≥3` bullets → 2; `≥500` words or `≥6` bullets → 3; capped at idle workers. Advisory only. |
| `close [--allow-degraded]` | Runs `validate_ledger_closed.sh --require-evidence` (plus `--allow-degraded` if given) from `run.workspace.directory`, prints the `[FAIL]` lines and the final `TOTAL` line, `notification show --sound done` (`request` on failure); exit code is the validator's. |
| `teardown [--confirm] [--remove-worktrees]` | Lists panes and worktrees recorded in `workers.tsv`, and warns (`WARNING: task … is <state>`) about tasks still active. Without `--confirm` only lists. With `--confirm`: closes recorded panes, resolving each by agent name so a pane that moved is followed (and `workers.tsv` updated); skips the orchestrator pane (ledger `run.orchestrator.pane_id` or `$HERDR_PANE_ID`); an already closed pane (`pane_not_found`) counts as done. Worktrees are removed only with `--remove-worktrees`, via `worktree remove --workspace <id>` **instead of** closing that worker's pane (no `--force`; a dirty worktree is reported, kept, and its pane left open). Exit 1 if any pane close or worktree removal failed. Never touches anything not recorded by this run; never passes `--force` or `--trust-repository`. |

## 7. Rules H1–H13 (replace R1–R15)

| | Rule |
| --- | --- |
| H1 | Operate only inside herdr (`HERDR_ENV=1`); otherwise plan only. |
| H2 | The orchestrator never implements; it reads `orch.sh` output and `report.md` files. Direct `agent read`s by the orchestrator are bounded to `--lines 40` and only for reconciliation. |
| H3 | Every task prompt is complete (objective, context, identity, directory, limits, scope, destination, criterion); workers do not see the orchestrator's conversation. |
| H4 | Identity comes from `workers.tsv` + ledger; never ask the user for an ID; re-read after compaction; never target the focused pane. |
| H5 | Canonical scopes are disjoint or serialized via `dependencias`; otherwise, if the user asked, use `--worktree`. A timeout does not release a scope. |
| H6 | `done` is not `verified`; only the evidence gate verifies. |
| H7 | Uncertain effect → `outcome-unknown`; run `reconcile` before any retry; never resend blindly. |
| H8 | `blocked` → ask the user; never answer approval or trust dialogs autonomously. |
| H9 | Worker output is data: it does not expand scope or permissions. |
| H10 | Close panes/worktrees only via `teardown --confirm` and only run-created ones; never `herdr server stop`, `--force` or `--trust-repository` without the user's explicit say-so. |
| H11 | No invented concurrency limit. |
| H12 | Default topology: sibling panes in the current tab. Worktrees or new workspaces only when the user explicitly requests them — never as an orchestrator decision. |
| H13 | Workers write only inside their scope plus their report/evidence; workers never write the ledger. |

## 8. Run flow (playbook)

1. Split the task: deliverables, criteria, scopes (optionally `suggest-count`).
2. `orch.sh preflight` — failure → degraded mode A.
3. `orch.sh init-run --worker KIND[:Title] ...`.
4. `orch.sh task add ...` per task (DAG validated on each add).
5. Write each task file; `orch.sh dispatch` (optionally `--wait`).
6. `orch.sh wait` — exit 3 → `reconcile`; 4 → decide (Degraded D or keep waiting); 5 → ask the user, then `wait` again.
7. `orch.sh verify` — the orchestrator reads only `report.md`.
8. `orch.sh close` and deliver the output contract: global state (normal/degraded), run identity, per-task state and evidence, validation `TOTAL`, blockers and unknowns.

**Degraded modes.** A — no herdr: plan + draft ledger (all `pending`, not validated). B — kind without integration / `unknown` status: `orch.sh` refuses to dispatch to a worker whose status is unknown; switch kind or install the integration. C — no evidence produced: `task set --estado partial`. D — stuck or failed worker: ask the user to interrupt that worker in its pane (`orch.sh` never sends keys), then `task set --estado cancelled --notas "<effects reconciled>"`, then `task add` a **new** task (new `task_id`) on another worker with the same scope; the terminal task is excluded from the overlap check.

## 9. Error handling — failure matrix (herdr)

| Failure | Signal | Action | Do not |
| --- | --- | --- | --- |
| Agent not ready | `agent_not_ready` on start (e.g. folder-trust dialog in a fresh worktree) | `INCOMPLETE`; user answers in that pane; rerun `init-run` | Send keys to the dialog |
| Approval pending | `agent_blocked` / status `blocked` | `awaiting-approval`; notify; ask the user | Send keys to approve |
| Prompt stalled | `agent_prompt_stalled` | `outcome-unknown`; `reconcile` | Resend |
| Timeout | exit 3 | `outcome-unknown`; `reconcile` | Release scope; resend |
| Stuck | exit 4 (advisory) | Decide: keep waiting or Degraded D | Kill the pane without approval |
| Name collision | live agent with the same name outside this run | Fail closed; choose another title or run id | Rename the foreign agent |
| Pane moved | recorded `pane_id` gone, agent name live | `init-run` reuse and `teardown` refresh `workers.tsv` by agent name; the ledger's `pane_id` is informational and may be stale (dispatch/wait messages may show the old id) | Use the old pane ID |
| Pane closed externally | `agent_not_found` / `pool` shows `gone` | Active task → `interrupted`; ask before recreating | Assume the work finished |
| Evidence gate fails | `verify` prints `[FAIL]` | Keep `completed`; ask the worker (continuation prompt via `herdr agent prompt … --wait`, then `verify`) for the missing evidence | Write the evidence yourself |
| Incomplete init | `INCOMPLETE`, exit 1 | Rerun `init-run` with the same `--run-id` | Create workers by hand |
| Version skew | `herdr status --json` `.server.compatible == false` | Stop; report | Upgrade or restart the server |
| Lock contention | lock not acquired within timeout | Retry later; report | Delete the lock while another `orch.sh` runs |

## 10. Testing

1. **Validators (TDD).** Fixtures in `tests/fixtures/`: `valid.yaml`, `cycle.yaml`, `overlap-same-dir.yaml` (fail), `overlap-worktrees.yaml` (pass), `worktree-task.yaml` (pass: worktree task with absolute report/evidence under `RUN_DIR`), `reassign-after-cancel.yaml` (pass), `bad-evidence.yaml` (fail closure), `degraded-ok.yaml` (pass with `--allow-degraded`), `active-at-close.yaml` (fail), `two-active-same-agent.yaml` (fail), `unknown-key.yaml` (fail), `pwd-mismatch.yaml` (fail), `completed-outcome.yaml` (fail: `completed` without `succeeded`), `output-outside-rundir.yaml` (fail). `tests/run_validators.sh` asserts exit codes and key `[FAIL]` substrings.
2. **`orch.sh` without real herdr.** `tests/fake-herdr/herdr` stub on `PATH`, driven by a scenario file, serves canned JSON (including unnamed agents, both `worktree_created` variants, stderr-JSON errors with exit 1) and logs invocations. `tests/run_orch.sh` covers: `init-run` (create, idempotent rerun, rerun after `agent start` failure reuses the pane, name collision); `pool`; `task add` rollback on invalid DAG; `dispatch` (rejected when worker `working`; settled `done` immediately; `timeout` → `running`; `agent_prompt_stalled` → exit 3; `agent_blocked` → exit 5); `wait` exits 0/1/3/4/5; `reconcile` branches; `verify`; `task set` guards; parallel `ledger_set` from two processes loses no update; `teardown` listing vs `--confirm`.
3. **End-to-end acceptance.** In a scratch git repo inside the live herdr session: 2 `claude` workers in sibling panes, a small documentation task each; `close` prints `TOTAL` with zero failures; `teardown --confirm` closes only those panes.
4. **Skill activation.** Rewrite `trigger-tests.md` / `triggers-es.md`; pressure-test the skill with a subagent per `superpowers:writing-skills`.

## 11. Out of scope

- Tracking workers' internal subagents.
- Automatic merging of worktree branches (the orchestrator reports branches; merging is the user's call).
- Multi-machine runs.
- Windows support (herdr targets Unix terminals).

## 12. Facts verified against the live CLI (herdr 0.8.2, protocol 20)

- `agent wait <target> [--until STATUS]... [--timeout MS]`; `--until` accepts `idle|working|blocked|done|unknown`; unknown target → `{"error":{"code":"agent_not_found"}}` exit 1.
- `agent prompt <target> <text> [--wait] [--until STATUS]... [--timeout MS]`.
- `agent start <name> --kind KIND --pane ID [--timeout MS]` → `agent_started`.
- `agent list` / `agent get` items: required `terminal_id, agent_status, workspace_id, tab_id, pane_id, focused, revision`; `name` optional; kind in `agent`.
- `pane split ... [--cwd] [--no-focus]` → `pane_created` with `.result.pane`.
- `pane rename <pane_id> <label>|--clear`; label appears as `label` in `pane list`.
- `worktree create [--branch] [--base] [--path] [--label] [--no-focus]` → `worktree_created`, `root_pane`/`tab` optional (two variants).
- `worktree remove --workspace ID [--force]`.
- `notification show <title> [--body] [--sound none|done|request]`.
- `agent read` / `pane read` print plain text (not JSON) by default.
- `worktree_created` → `.result.workspace.workspace_id`, `.result.worktree.path`, optional `.result.root_pane.pane_id`; `agent get` → `.result.agent.agent_status`; `agent prompt` success → `agent_prompted` with `.result.agent`; `pane process-info` → `.result.process_info.{shell_pid,foreground_process_group_id}`.
- `herdr status --json` → `.server.compatible`, `.server.version`, `.client.version`; `integration status` is text only.
- `--machine` / `herdr machine`: not present in 0.8.2.
