# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Driven by feedback from a real 5-worker, 9-task run.

### Added
- `task reassign --task ID --worker N`: moves a `pending` task to another worker (worker fields rewritten, DAG re-validated, `notas` records the previous agent). No cancelled row, so the run no longer closes as degraded when nothing failed.
- `wait --any [--timeout MS]`: settles the first running task that is no longer working (one `agent list` per poll); same output and exit codes as `wait --task`.
- `task status --task ID`: non-blocking ledger state with `wait`'s exit codes plus `6` while not settled.
- `task add --prompt-file F` stores the task body as `<run>/<task>/task.md`; `dispatch --task ID` uses it when `--prompt-file` is omitted.
- `summary`: run identity, one tab-separated row per task (worker, kind, estado, first report line, evidence path) and counts, for the output contract.
- Evidence `observed` accepts a literal block scalar (`observed: |`), so long observations no longer have to fit one line.

### Changed
- `pool` shows a worker's active task before a queued pending one (it used to show the last ledger row).
- Docs: H2 clarified (splitting and aggregating are the orchestrator's own work; implementing a worker's task is not); `teardown` keeps `workers.tsv` rows, so `pool` lists them as `gone`; the unattended-Claude `--agent-arg` recipe is spelled out (no per-kind shorthand: `orch.sh` is kind-agnostic).

## [0.1.0] - 2026-10-06

Fork of OpenCode-Orchestrator-Skill 1.0.0 (preserved at tag `opencode-final`), rebuilt for herdr.

### Added
- `scripts/orch.sh` (preflight, init-run, pool, task add/set, dispatch, wait, reconcile, verify, suggest-count, close, teardown) on the herdr CLI + jq.
- `init-run --agent-arg ARG` (repeatable) passes native agent args after `--` to `herdr agent start`, e.g. `--permission-mode auto` for unattended Claude workers.
- `reconcile --task`, including tasks left in `launching`: resolves uncertain dispatches from the worker's real state without resending prompts.
- `suggest-count FILE` advises 1-3 workers (works outside herdr).
- `teardown` (dry run; `--confirm` closes only the run's worker panes, `--remove-worktrees` for worktree runs).
- Ledger schema 4 (herdr identity, worktree-aware canonical scopes, explicit state machine) and `check_evidence.sh`.
- Test suites: `tests/run_validators.sh`, `tests/run_orch.sh` (fake herdr), `tests/check_skill.sh`.
- Live acceptance run on herdr 0.8.2 with 2 claude workers: `TOTAL: 4 passed, 0 failed` (`docs/superpowers/acceptance/2026-10-06-e2e.md`).

### Removed
- OpenCode HTTP/session plumbing, TUI tabs recipe, per-OS adapters, Windows path handling, the two-subagent minimum.

## [1.0.0] - 2026-10-03

First public release of the OpenCode V2 two-level orchestration skill.

### Added

- `SKILL/scripts/orchestrate.sh` — multi-OS swiss-army knife with 12 subcommands:
  `preflight`, `ensure-root`, `create-worker`, `send-prompt`, `attach-tabs`,
  `watch`, `wait-idle`, `init-run`, `sessions`, `self-check`, `pool`,
  `tabs`, `verify-daughters`, `delete-session`.
- `SKILL/scripts/orchestrate-{darwin,linux,wsl,windows}.sh` — explicit OS
  dispatch wrappers (per-OS invocation without relying on `uname`).
- `SKILL/scripts/os/{_common,darwin,linux,wsl,windows-gbash,tui-detect}.sh` —
  shared helpers + OS adapters; lock mechanism per OS (`flock(1)` on
  linux/wsl, `python3 fcntl` on darwin/windows-gbash).
- `SKILL/scripts/dragon_name.sh` — catalog of 100 dragon names grouped by
  element (Fire/Ice/Storm/Abyssal/Arcane) plus deterministic synthesis for
  runs with >100 workers.
- `SKILL/scripts/preflight.sh` — one-shot discovery: endpoint, version,
  `/openapi.json` guard, agent catalogs, default model pair, root session
  hint, TUI/tabs gate. Caches state under `ORCHESTRATE_CACHE_DIR` (chmod 600
  on the auth password file; never echoed to stdout).
- `SKILL/scripts/watch_run.sh` — bounded POSIX+awk watcher (idle + outcome +
  artifacts + permissions) with fixed deadline.
- `SKILL/scripts/validate_dag.sh` — canonical YAML/DAG/scope/state validator.
- `SKILL/scripts/validate_ledger_closed.sh` — closure validator (strict and
  `--allow-degraded` modes; `--require-evidence` for the evidence gate).
- 14 `SKILL/references/*.md` — operational, contractual, evidence, and pattern
  documentation.
- `SKILL/LICENSE` (MIT, DragonJAR.org 2026).

### Multi-OS portability

- POSIX sh + awk + sed + curl only; no bashisms, no `local`, no `[[ ]]`.
- OS-specific behavior isolated to `os/{darwin,linux,wsl,windows-gbash}.sh` via
  a uniform `os_project_dir` + `os_tabs_merge SID TITLE TUI_CWD BACKUP_DIR`
  interface.
- `windows-gbash.sh` uses `cygpath -w` for the Windows literal path and probes
  `fcntl` availability in MSYS2 python3 (fail-closed otherwise).
- `wsl.sh` detects drvfs (`/mnt/c`) and refuses to take a lock there.
- Cross-OS verification on darwin; linux/wsl/windows-gbash verified by code
  inspection (POSIX conformance).

### Fail-closed gates

- `dedup_guard TITLE` (return code contract: 0 reuse, 1 create, 2 collision,
  3 catalog query failure): never allows a duplicate or an unchecked creation.
- `pool_list` reads `time.updated` vs `time.idle` to correctly mark a session
  as `running` when active (previous code marked everything `idle` if `time.idle`
  existed, which led to overwrite races).
- `verify-daughters --worker-id WID` aborts with exit 2 when the query
  returns zero children (a mistyped worker-id would otherwise read as
  success).
- `delete-session` enumerates children via `GET /api/session?parentID=` and
  aborts unless the count is known; `--force` does NOT override this gate.
- `send-prompt` verifies the session has a resolved `model.id` before
  sending; an empty prompt file dies; a `dispatch_$SID` timestamp is cached
  so `wait-idle` only accepts an idle timestamp that is NEWER than the
  dispatch (pool-safe).
- `attach-tabs` consumes the tabs gate (single source: `tui-detect.sh`) and
  fails closed when the gate is blocked, when `--tui-cwd` contradicts the
  detected cwd, or when the cwd directory does not exist.

### DRY

- `auth_flag`, `cache_put/get/has`, `require_state`, `parse_kv`, `die`,
  `tabs_json_path`, `pool_list`, `pool_max_ordinal`, `session_body`,
  `find_dedup`, `dedup_guard`, `post_new_session`, `json_escape`,
  `json_get_field` — all live once in `SKILL/scripts/os/_common.sh`.
- The tabs gate is decided ONCE in `tui-detect.sh`; `resolve_gate` in
  `orchestrate.sh` re-probes only when the cache's pin is stale.
- `pool_list` is the single source of the deployed workers' table; both
  `pool` (visibility) and `init-run` (reuse/create) read it via the same call.
- `worker_list` + `title_normalize` are the only two functions that know the
  `[NN] Name` pattern.

### Known limitations

- i18n: if the orchestrator session is created with different `[00]`
  names across languages (e.g., Spanish `Orquestador` vs English `Orchestrator`),
  both will coexist in the pool. Use `pool` to inspect, and `delete-session`
  to clean.
- Cross-OS live verification was performed only on darwin. Linux / WSL /
  Windows Git Bash are verified by code inspection; the first deployment on
  each should run the full battery documented in the install section.
- The `/openapi.json` is the single source of truth. Some paths documented in
  references/ are flagged with `requiere verificación` (e.g. `--param`,
  `opencode ai --server`); the skill's default routes are HTTP-direct via
  the cached endpoint and Basic auth.