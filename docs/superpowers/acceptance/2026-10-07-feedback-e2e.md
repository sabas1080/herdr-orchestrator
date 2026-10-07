# herdr-orchestrator 0.2.0 — live acceptance run (2026-10-07)

Environment: herdr 0.8.2 (protocol 20), orchestrator = Claude Code in pane `wN:p1` (tab `wN:t1`), workers = 2 × `claude` started with `--agent-arg --permission-mode --agent-arg auto`. Scripts: `SKILL/scripts` of branch `feat/feedback-round-1` (HEAD after the docs commit), run directly. Toy repo (no own `.git`, inside the trusted project folder): `src/a/calc.py` (`add`, `sub`), `src/b/greet.py` (`greet`), three task bodies in `tasks/`.

Goal: exercise every feature added from the agent feedback round against the real herdr: `task add --prompt-file`, `dispatch` without `--prompt-file`, the `pool` fix, `task status`, `task reassign`, `wait --any`, `observed: |`, `summary`.

## Result

**PASS** on the first attempt. `TOTAL: 6 passed, 0 failed`; `teardown --confirm` closed exactly the two panes it had created.

## Transcript (key lines)

```
$ orch.sh init-run --run-id fb-e2e --worker claude:Alpha --worker claude:Beta --agent-arg --permission-mode --agent-arg auto
started  [01] Alpha -> w01-alpha-0df1 (claude, wN:p2)
started  [02] Beta -> w02-beta-0df1 (claude, wN:p3)
$ orch.sh task add --id W1 --worker 1 --scope docs/a --criterion "…" --prompt-file tasks/w1.md     → task W1 added -> w01-alpha-0df1
$ orch.sh task add --id W2 --worker 2 --scope docs/b --criterion "…" --prompt-file tasks/w2.md     → task W2 added -> w02-beta-0df1
$ orch.sh task add --id W3 --worker 1 --scope docs/README.md --criterion "…" --prompt-file tasks/w3.md → task W3 added -> w01-alpha-0df1
$ orch.sh dispatch --task W1                      → dispatch: W1 running on w01-alpha-0df1   (rc 0, body from W1/task.md)
$ orch.sh dispatch --task W2                      → dispatch: W2 running on w02-beta-0df1    (rc 0)
$ orch.sh pool
1  w01-alpha-0df1  claude  working  wN:p2  W1  running      ← active task shown, not the queued W3
2  w02-beta-0df1   claude  working  wN:p3  W2  running
$ orch.sh task status --task W1                   → status: W1 running (w01-alpha-0df1)      (rc 6)
$ orch.sh task status --task W3                   → status: W3 pending (w01-alpha-0df1)      (rc 6)
$ orch.sh wait --any --timeout 540000             → wait: W1 completed (done); next: orch.sh verify --task W1   (rc 0)
$ orch.sh verify --task W1                        → [OK] W1 verified                          (rc 0)
$ orch.sh task reassign --task W3 --worker 2      → task W3 -> w02-beta-0df1                  (rc 0; notas: "reassigned from w01-alpha-0df1")
$ orch.sh wait --any --timeout 540000             → wait: W2 completed (done); next: orch.sh verify --task W2   (rc 0, 3 s)
$ orch.sh verify --task W2                        → [OK] W2 verified                          (rc 0)
$ orch.sh dispatch --task W3                      → dispatch: W3 running on w02-beta-0df1     (rc 0, stored body, reassigned worker)
$ orch.sh wait --any --timeout 540000             → wait: W3 completed (done)                 (rc 0, 12 s)
$ orch.sh verify --task W3                        → [OK] W3 verified                          (rc 0)
$ orch.sh task status --task W3                   → status: W3 verified (w02-beta-0df1)       (rc 0)
$ orch.sh summary
run=fb-e2e · workspace=… · server_version=0.8.2
W1  [01] Alpha  claude  verified  Documented the two public functions of `src/a/calc.py` …   …/W1/evidence.yml
W2  [02] Beta   claude  verified  Created `docs/b/README.md` (32 lines) documenting the …     …/W2/evidence.yml
W3  [02] Beta   claude  verified  Created `docs/README.md` (6 lines), an index that links …   …/W3/evidence.yml
tasks=3 verified=3 degraded=0 open=0
$ orch.sh close                                   → TOTAL: 6 passed, 0 failed                 (rc 0)
$ orch.sh teardown --confirm                      → closed pane wN:p2, closed pane wN:p3      (rc 0)
$ orch.sh pool                                    → both workers STATUS=gone (rows kept for audit)
```

Worker evidence (W1, verbatim). The worker chose the block form on its own after reading the new header text:

```yaml
criterion: "docs/a/README.md documents add and sub from src/a/calc.py"
result: "pass"
observed: |
  Read src/a/calc.py: public functions are add(x, y) and sub(x, y).
  Wrote docs/a/README.md (33 lines) with sections for add and sub,
  each with signature, description and example.
  Ran: python3 -c "import sys; sys.path.insert(0,'src/a'); import calc; print(calc.add(2,3), calc.sub(5,3))"
  Output: 5 2 -- matches the README examples (add(2,3)=5, sub(5,3)=2).
  grep -c -E 'add\(|sub\(' docs/a/README.md -> 5.
```

W1's report had 201 words (limit 500). After teardown only the orchestrator pane `wN:p1` remained in the tab and no `w0N-*-0df1` agent was live.

## Findings fed back into the work

1. `summary` took the first physical line of each report; reports wrap their paragraphs, so W2 and W3 came out cut mid-sentence. → `summary` now joins the first non-heading paragraph.
2. No cancelled row and no `--allow-degraded` were needed to move W3 to the worker that freed up first: the scenario from the feedback report.
