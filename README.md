# herdr-orchestrator

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](SKILL/LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.0-green.svg)](SKILL/SKILL.md)
[![Platform](https://img.shields.io/badge/platform-herdr-8A2BE2.svg)](https://herdr.dev)
[![Español](https://img.shields.io/badge/read%20in-Espa%C3%B1ol-blue.svg)](README.es.md)

> Ask Claude, inside [herdr](https://herdr.dev), to split a big task across several coding agents. It opens the panes, hands out the work, waits, checks every result against written evidence and gives you a short summary.

## What it is

A Claude Code skill. You keep talking to Claude in your herdr pane as usual; when a task is big enough to share, Claude becomes the **orchestrator**:

- it starts **worker agents** in sibling panes of your tab — `claude`, `codex`, `opencode` or any other kind herdr supports;
- each worker gets a complete, self-contained task file and a folder it may write to;
- Claude never does the work itself and never reads the workers' full transcripts — only their short reports — so its own context stays small;
- a task counts as done only when the worker's evidence file (a three-line note: the criterion, `pass`/`fail`, and what was actually checked) proves the acceptance criterion.

## Before you start

- Run Claude Code **inside a herdr pane** (herdr sets `HERDR_ENV=1`); outside herdr the skill only proposes a plan.
- Install the agent CLIs you want as workers (`claude`, `codex`, `opencode`…); herdr starts them in the new panes.
- Install the skill (see [Install](#install)). Claude picks it up when you ask to orchestrate workers in herdr.

## How you use it

Just ask, in your own words:

> *Orchestrate two workers in herdr: one documents `src/a`, the other documents `src/b`.*

> *Reparte este refactor entre un worker claude y uno codex en herdr y verifica cada resultado.*

What you will see:

1. Two new panes appear next to yours, labelled `[01] Vermithrax`, `[02] Pyreclaw`… (default names come from a dragon catalog).
2. Each worker receives its task and starts working; you can watch or ignore them.
3. If a worker stops to ask for an approval, Claude tells you which pane needs you and you get a herdr notification. **You** answer it; Claude never does.
4. When everything is checked, Claude replies with a short report: what each worker did, whether its evidence passed, and anything that needs your attention.
5. The worker panes stay open until you ask Claude to close them.

## How it works

```
your pane (Claude, orchestrator)
        |   orch.sh  (SKILL/scripts)
        v
  herdr CLI  --->  [01] worker pane   [02] worker pane   ...
        |
        v
.herdr-orch/<run>/            (inside your project, excluded via .git/info/exclude)
    ledger.yaml               the run's record: every task, its worker and its state
    workers.tsv               which agent lives in which pane
    <task>/prompt.md          the task file the worker reads
    <task>/report.md          the worker's short report (asked to stay within 500 words)
    <task>/evidence.yml       criterion · result · what was checked
```

One run goes through six steps:

1. **Split** the request into tasks, each with a criterion and the files it may touch. Tasks that would write the same files are put in order instead of running in parallel.
2. **Start workers** in sibling panes (`init-run`). If a pane fails to start, rerunning completes only what is missing.
3. **Send** each worker its task (`dispatch`): one short line pointing at its task file.
4. **Wait** for each worker (`wait`). Approvals go to you; a worker that disappears, hangs or whose result is uncertain is reported, never silently retried.
5. **Verify** each report and its evidence (`verify`).
6. **Close** the run (`close`): a validator checks the whole ledger and prints `TOTAL: N passed, 0 failed`.

## Guarantees

- **Never answers for you.** Approval prompts and Claude's folder-trust dialog are always left to you.
- **Never resends blindly.** If it is unclear whether a worker got its task, Claude first checks what actually happened in that pane (`reconcile`) and only resends when the task provably never arrived.
- **Only touches what it created.** Closing panes or worktrees affects only this run's workers, never your pane or anything else, and only when you ask.
- **No result without evidence.** "The agent went idle" is not success; only a passing evidence check is.
- **Stays in herdr.** Outside a herdr pane it only proposes a plan; it doesn't pretend to run anything.

## Differences from the original

This repo is a fork of DragonJAR's [OpenCode-Orchestrator-Skill](https://github.com/DragonJAR/OpenCode-Orchestrator-Skill) 1.0.0, but it does a different job:

| | OpenCode-Orchestrator-Skill | herdr-orchestrator |
| --- | --- | --- |
| Runtime | OpenCode V2 server (HTTP API) | herdr terminal multiplexer (CLI) |
| Workers | OpenCode sessions, each with ≥2 native subagents | Agents of any kind in sibling panes; their internal subagents are their business |
| Seeing the work | OpenCode TUI tabs (`attach-tabs`) | Real herdr panes, labelled `[NN] Name` |
| Ledger | YAML schema 3 (sessions, `parentID`, locations) | YAML schema 4 (agent, pane, worktree, delivery evidence) |
| Isolation | Disjoint write scopes; overlaps serialized via DAG dependencies | The same, or one git worktree (a separate checkout of the repo) per worker on request |
| Kept from the original | — | Orchestrator-never-implements, complete task prompts, written evidence gate, POSIX validators, fail-closed rules, dragon names |
| Removed | — | HTTP/auth discovery, tabs patching, per-OS adapters, the two-subagent rule |

The OpenCode version is preserved at tag `opencode-final`.

## Install

The folder name must equal the skill name, `herdr-orchestrator`.

```bash
git clone https://github.com/sabas1080/herdr-orchestrator.git ~/.claude/skills/herdr-orchestrator-src
ln -s ~/.claude/skills/herdr-orchestrator-src/SKILL ~/.claude/skills/herdr-orchestrator   # or copy SKILL/ there
```

| Requirement | Version |
| --- | --- |
| herdr | ≥ 0.8.2 — Claude must run inside a herdr pane (`HERDR_ENV=1`) |
| jq | any recent |
| POSIX `sh` + `awk` | for `orch.sh` and the validators |
| git | only for the optional worktree mode |

## Letting workers run unattended

By default, workers start in your normal permission mode, so a Claude worker stops whenever it wants to edit a file or run a command, and waits for you. If you want them to work on their own, tell Claude which mode to start them in; it passes native arguments with `--agent-arg`:

```sh
sh SKILL/scripts/orch.sh init-run --worker claude --worker claude --agent-arg --permission-mode --agent-arg auto
```

Only do this when you want unattended workers. Also note that a folder Claude has never seen (a new repo or a worktree) shows Claude's folder-trust dialog once; answer it in that pane and ask Claude to continue — it reruns `init-run` with the same options.

## For developers

All mechanics live in `SKILL/scripts/orch.sh` (POSIX sh, needs `herdr` + `jq`). Claude runs it from the project root; you normally don't.

```
orch.sh preflight
orch.sh init-run [--run-id ID] --worker KIND[:Title]... [--worktree] [--agent-arg ARG]...
orch.sh pool [--run ID]
orch.sh task add --id ID --worker NAME|NN --criterion TEXT --scope A[,B] [--deps X[,Y]] [--prompt-file F] [--run ID]
orch.sh task set --task ID --estado cancelled|failed|partial|blocked|interrupted --notas TEXT [--run ID]
orch.sh task reassign --task ID --worker NAME|NN [--run ID]
orch.sh task status --task ID [--run ID]
orch.sh dispatch --task ID [--prompt-file F] [--wait] [--timeout MS] [--run ID]
orch.sh wait --task ID [--timeout MS] [--stuck-secs N] [--run ID]
orch.sh wait --any [--timeout MS] [--run ID]
orch.sh reconcile --task ID [--run ID]
orch.sh verify --task ID [--run ID]
orch.sh suggest-count FILE
orch.sh summary [--run ID]
orch.sh close [--allow-degraded] [--run ID]
orch.sh teardown [--confirm] [--remove-worktrees] [--run ID]
```

Exit codes: `0` ok · `1` failure · `2` usage/environment · `3` outcome unknown/timeout · `4` stuck (advisory) · `5` waiting for your approval · `6` not settled yet (`task status`).
The skill's own instructions are in [SKILL/SKILL.md](SKILL/SKILL.md); details in [SKILL/references/](SKILL/references/).

### Tests

```sh
sh tests/run_validators.sh   # ledger validators
sh tests/run_orch.sh         # orch.sh against a fake herdr (sets a memory cap when the shell allows it)
sh tests/check_skill.sh      # skill structure and links
```

The tests never touch your herdr session. A live run against real herdr 0.8.2 with two `claude` workers is recorded in [docs/superpowers/acceptance/2026-10-06-e2e.md](docs/superpowers/acceptance/2026-10-06-e2e.md): both tasks verified, `TOTAL: 4 passed, 0 failed`.

## Origin and license

Originally by [DragonJAR](https://github.com/DragonJAR/OpenCode-Orchestrator-Skill); rebuilt for herdr by Electronic Cats. MIT, see [SKILL/LICENSE](SKILL/LICENSE).
