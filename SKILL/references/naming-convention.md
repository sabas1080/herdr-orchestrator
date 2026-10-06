# Naming convention

| Thing | Form | Example |
| --- | --- | --- |
| Task ID | stable key chosen by the orchestrator, `[A-Za-z0-9][A-Za-z0-9._-]*` | `W1` |
| Pane label | `[NN] Title`: two-digit ordinal from `init-run` order, then the title | `[01] Vermithrax` |
| Agent name | `wNN-<slug>-<sfx4>` | `w01-vermithrax-k3f9` |
| Branch (worktree runs) | `orch/<run>/NN-<slug>` | `orch/20261006-docs/01-vermithrax` |

## Agent names

- `slug`: at most 20 characters of `[a-z0-9-]` derived from the title (lowercased, other characters become `-`, no leading or trailing dash).
- `sfx4`: 4 hex characters derived from the run id. Agent names are global to the herdr server, so the suffix keeps two runs from colliding.
- Total length is at most 32 characters and matches `[a-z][a-z0-9_-]{0,31}`. A live agent with the same name outside the run makes `init-run` fail closed (choose another title or run id).

## Titles

- Default titles come from `scripts/dragon_name.sh N`: a catalog of 100 names in 5 families of 20 (fire 01-20, ice 21-40, storm 41-60, abyssal 61-80, arcane 81-100); beyond 100 a deterministic synthesis gives stable, distinct names.
- To set a title: `--worker claude:Doc\ Writer` or `--worker "codex:Doc Writer"`. Pass one `--worker` flag per worker, because titles contain spaces. Titles cannot contain tabs.

## Identity

The task ID (`W1`) is the stable key in commands and in the ledger; the title and the ordinal are labels for humans. Resolve a worker with `--worker NN` (ordinal) or its agent name from `orch.sh pool`; never ask the user for a pane ID, and never rely on the focused pane.
