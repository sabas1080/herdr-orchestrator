# Trigger tests

Check these against the `description` in `SKILL.md` whenever you edit it. Spanish list: [triggers-es.md](triggers-es.md).

## Should activate

| Query | Why |
| --- | --- |
| orchestrate three agents in herdr to document these modules | Multi-agent run in herdr |
| fan out this refactor to codex and claude workers in herdr panes | Mixed-kind workers in panes |
| use herdr to run workers in parallel and verify each result | Parallel workers plus verification |
| split this task across herdr worker panes | Task split across worker panes |
| start a multi-agent run in herdr | Explicit multi-agent run |
| dispatch these tasks to herdr workers and wait for them | dispatch + wait |
| resume the herdr orchestration run 20261006-docs | Rerun of an existing run id |
| close the herdr-orchestrator run and validate the ledger | close + ledger validation |

## Should not activate

| Query | Why / what handles it |
| --- | --- |
| split this pane to the right in herdr | Manual pane control: herdr skill |
| send ctrl+c to the agent in pane w1:p2 | Manual pane control: herdr skill |
| orchestrate OpenCode sessions | OpenCode sessions are out of scope (see tag `opencode-final`) |
| explain what a coding agent is | General question, no run |
| fix this bug | Single agent, no orchestration |
| run the test suite in a background pane | Background pane: herdr skill |
