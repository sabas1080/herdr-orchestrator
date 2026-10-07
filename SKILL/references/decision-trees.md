# Decision trees

## Tree 1 Preflight

```text
orch.sh preflight
 |
 +-- exit 0, gate=ready, template=ok --> init-run
 |
 +-- exit 2 (no HERDR_ENV, herdr/jq missing, client/server incompatible, template missing)
       --> degraded mode A: deliver the plan and the proposed tasks; claim nothing ran
```

## Tree 2 Scopes

```text
Do two tasks' write scopes overlap (same files or one inside the other)?
 |
 +-- no  --> run them in parallel on different workers
 |
 +-- yes --> can one wait for the other?
       |
       +-- yes --> task add --deps <first>   (serialize)
       |
       +-- no  --> did the USER ask for isolated worktrees?
             |
             +-- yes --> init-run --worktree (one branch per worker)
             |
             +-- no  --> split the scopes differently, or ask the user
```

## Tree 3 Waiting

```text
orch.sh wait --task ID            (or wait --any: same exits for the first running task that settles;
 |                                 task status --task ID: same exits without blocking, 6 = not settled)
 +-- exit 0 --> verify
 +-- exit 1 --> agent gone: task interrupted --> ask the user before recreating
 |              herdr error x3: estado unchanged --> preflight, retry wait
 +-- exit 3 --> reconcile --task ID --> pending? re-dispatch (after Verify effects)
 |                                      running / awaiting-approval / completed? continue
 +-- exit 4 --> stuck (advisory): keep waiting, or ask the user to interrupt that worker in its pane, then
 |              task set --estado cancelled --notas "<effects>" + task add (new ID, other worker)
 |              (a task still pending needs no cancellation: task reassign --task ID --worker N)
 +-- exit 5 --> tell the user which pane needs approval --> wait again (never approve)
```

## Tree 4 Closing

```text
Is every task terminal?
 |
 +-- no  --> keep waiting / reconcile / verify; nothing is closed while a task is pending, completed or active
 |
 +-- yes --> are all verified?
       |
       +-- yes --> orch.sh close --> TOTAL ... 0 failed --> output contract
       |
       +-- no (failed, partial, blocked, cancelled, interrupted with a reason in notas)
             --> orch.sh close --allow-degraded --> report the run as degraded and list each notas
```

## Tree 5 Destructive actions

```text
About to close a pane or remove a worktree?
 |
 +-- created by this run (listed in workers.tsv / orch.sh teardown dry run)?
 |     |
 |     +-- no  --> do not touch it
 |     +-- yes --> did the user explicitly ask?
 |           |
 |           +-- no  --> do not; leave panes open
 |           +-- yes --> orch.sh teardown (review) --> teardown --confirm
 |                       worktrees: add --remove-worktrees only if the user asked
 |
 +-- --force, --trust-repository, herdr server stop --> only with the user's explicit say-so
```
