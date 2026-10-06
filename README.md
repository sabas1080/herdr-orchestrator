# herdr-orchestrator

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](SKILL/LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.0-green.svg)](SKILL/SKILL.md)
[![Platform](https://img.shields.io/badge/platform-herdr-8A2BE2.svg)](https://herdr.dev)
[![Español](https://img.shields.io/badge/read%20in-Espa%C3%B1ol-blue.svg)](README.es.md)

> A Claude Code skill that orchestrates several coding agents inside [herdr](https://herdr.dev): the orchestrator splits the work, workers run in sibling panes, and every result is verified against written evidence before the run closes.

## What it does

- **A Claude orchestrator that never implements.** It splits the task, dispatches complete task files and reads only short reports, never raw worker transcripts.
- **Mixed-kind workers in sibling panes.** `claude`, `codex`, `opencode` and other agent kinds run side by side in the orchestrator's tab.
- **Schema-4 ledger plus evidence gate.** `.herdr-orch/<run>/ledger.yaml` records worker identity, scopes and an explicit state machine; a task is `verified` only when its `evidence.yml` passes `check_evidence.sh`.
- **POSIX validators.** `validate_dag.sh` and `validate_ledger_closed.sh` need only `sh` + `awk`.
- **Fail-closed handling** of approvals, timeouts and stuck workers: the orchestrator never answers a dialog, never resends a prompt blindly and reconciles uncertain outcomes first.

## Install

The folder name must equal the skill `name` (`herdr-orchestrator`).

```bash
git clone https://github.com/sabas1080/OpenCode-Orchestrator-Skill.git ~/.claude/skills/herdr-orchestrator-src
ln -s ~/.claude/skills/herdr-orchestrator-src/SKILL ~/.claude/skills/herdr-orchestrator   # or copy SKILL/ there
```

## Requirements

| Requirement | Version |
| --- | --- |
| herdr | >= 0.8.2 (run inside a herdr pane, `HERDR_ENV=1`) |
| jq | any recent |
| POSIX `sh` + `awk` | for `orch.sh` and the validators |
| git | for the optional `--worktree` mode |

## Quick start

```sh
sh SKILL/scripts/orch.sh preflight                                   # gate=ready ?
sh SKILL/scripts/orch.sh init-run --run-id 20261006-docs --worker claude --worker codex
sh SKILL/scripts/orch.sh task add --id W1 --worker 1 --scope docs/a --criterion "docs/a/README.md documents every public function of a/"
sh SKILL/scripts/orch.sh task add --id W2 --worker 2 --scope docs/b --criterion "docs/b/README.md documents every public function of b/"
sh SKILL/scripts/orch.sh dispatch --task W1 --prompt-file /tmp/w1.md
sh SKILL/scripts/orch.sh dispatch --task W2 --prompt-file /tmp/w2.md
sh SKILL/scripts/orch.sh wait --task W1 && sh SKILL/scripts/orch.sh verify --task W1
sh SKILL/scripts/orch.sh wait --task W2 && sh SKILL/scripts/orch.sh verify --task W2
sh SKILL/scripts/orch.sh close                                       # TOTAL: N passed, 0 failed
```

Other subcommands: `pool`, `task set`, `reconcile` (resolves `launching` / `outcome-unknown` tasks), `suggest-count FILE` and `teardown` (dry run; `--confirm` closes only this run's worker panes).

### Worker permission mode (`--agent-arg`)

`init-run --agent-arg ARG` (repeatable, one value per flag) is passed after `--` to `herdr agent start`. For example, to start Claude workers in auto permission mode:

```sh
sh SKILL/scripts/orch.sh init-run --run-id 20261006-docs --worker claude --worker claude \
  --agent-arg --permission-mode --agent-arg auto
```

Use it only for unattended workers the user actually wants. Without it, workers start in your default permission mode and stop at approval prompts, which the orchestrator reports and never answers.

### Folder trust

A fresh folder or worktree makes Claude show its folder-trust dialog. `init-run` then prints `INCOMPLETE`; answer the dialog once yourself in that pane and rerun `init-run --run-id ID` with the same `--worker` and `--agent-arg` flags. The orchestrator never answers it.

## Architecture

```
orchestrator pane (Claude)
        |
        v
  orch.sh  --->  herdr CLI  --->  worker panes (claude | codex | opencode ...)
        |
        v
.herdr-orch/<run>/
    ledger.yaml          schema 4, written only by orch.sh
    workers.tsv          worker registry (identity)
    <task>/prompt.md     composed task file
    <task>/report.md     short worker report
    <task>/evidence.yml  criterion, result, observed
```

## Live acceptance

Run against a real herdr 0.8.2 with 2 `claude` workers (permission mode `auto`): both tasks completed and verified, `close` printed `TOTAL: 4 passed, 0 failed`, and `teardown --confirm` closed exactly the two worker panes. Two earlier attempts stopped where the rules require (trust dialog, approval prompt). Details: [docs/superpowers/acceptance/2026-10-06-e2e.md](docs/superpowers/acceptance/2026-10-06-e2e.md).

## Tests

```sh
sh tests/run_validators.sh   # validators
sh tests/run_orch.sh         # orch.sh against a fake herdr
sh tests/check_skill.sh      # skill structure and links
```

## Origin

Fork of DragonJAR's [OpenCode-Orchestrator-Skill](https://github.com/DragonJAR/OpenCode-Orchestrator-Skill) 1.0.0, rebuilt for herdr by Electronic Cats. The OpenCode version is preserved at tag `opencode-final`.

## License

MIT, see [SKILL/LICENSE](SKILL/LICENSE).
