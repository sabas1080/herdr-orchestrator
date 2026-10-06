#!/bin/sh
# orch.sh tests against tests/fake-herdr: never touches a real herdr session.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SCRIPTS=$ROOT/SKILL/scripts
ORCH=$SCRIPTS/orch.sh
FAKE_BIN=$ROOT/tests/fake-herdr
PASS=0; FAILS=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

check() {
  name=$1; want=$2; sub=$3; shift 3
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -ne "$want" ]; then
    printf 'FAIL %s: rc=%s want=%s\n%s\n' "$name" "$rc" "$want" "$out"; FAILS=$((FAILS + 1)); return
  fi
  if [ -n "$sub" ] && ! printf '%s\n' "$out" | grep -F -- "$sub" >/dev/null; then
    printf 'FAIL %s: missing "%s"\n%s\n' "$name" "$sub" "$out"; FAILS=$((FAILS + 1)); return
  fi
  printf 'ok   %s\n' "$name"; PASS=$((PASS + 1))
}
# resp KEY CONTENT [RC] [STDERR]: clears stale .rc/.err first so a later success
# response is not poisoned by an earlier error response for the same key.
resp() {
  rm -f "$FAKE_HERDR_DIR/responses/$1.rc" "$FAKE_HERDR_DIR/responses/$1.err"
  printf '%s\n' "$2" > "$FAKE_HERDR_DIR/responses/$1"
  if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "$FAKE_HERDR_DIR/responses/$1.rc"; fi
  if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$FAKE_HERDR_DIR/responses/$1.err"; fi
}
herr() { printf '{"error":{"code":"%s","message":"fake %s"}}' "$1" "$1"; }
agent_json() { printf '{"result":{"agent":{"name":"%s","agent_status":"%s","pane_id":"w1:p2"},"type":"agent_info"}}' "$1" "$2"; }
base_responses() {
  resp status_--json '{"client":{"version":"0.8.2"},"server":{"version":"0.8.2","compatible":true}}'
  resp pane_current '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","agent":"claude"},"type":"pane_current"}}'
  resp agent_ 'herdr agent commands:
  kinds: pi|claude|codex|opencode'
  resp agent_list '{"result":{"agents":[{"agent":"claude","agent_status":"idle","pane_id":"w9:p1"}],"type":"agent_list"}}'
  resp pane_split.1 '{"result":{"pane":{"pane_id":"w1:p2","workspace_id":"w1"},"type":"pane_created"}}'
  resp pane_split.2 '{"result":{"pane":{"pane_id":"w1:p3","workspace_id":"w1"},"type":"pane_created"}}'
  resp pane_split.3 '{"result":{"pane":{"pane_id":"w1:p4","workspace_id":"w1"},"type":"pane_created"}}'
  resp pane_split.4 '{"result":{"pane":{"pane_id":"w1:p5","workspace_id":"w1"},"type":"pane_created"}}'
  resp pane_rename '{"result":{"type":"ok"}}'
  resp pane_process-info '{"result":{"process_info":{"shell_pid":10,"foreground_process_group_id":10},"type":"pane_process_info"}}'
  resp agent_start '{"result":{"agent":{},"argv":["claude"],"type":"agent_started"}}'
  resp pane_get '{"result":{"pane":{"pane_id":"w1:p2"},"type":"pane_info"}}'
  resp pane_close '{"result":{"type":"pane_closed"}}'
  resp notification_show '{"result":{"type":"notification_show"}}'
}
new_case() {
  C=$TMP/$1; mkdir -p "$C/ws" "$C/fake/responses"
  WS=$(cd "$C/ws" && pwd -P)
  FAKE_HERDR_DIR=$C/fake; export FAKE_HERDR_DIR
  (cd "$WS" && git init -q)
  : > "$FAKE_HERDR_DIR/calls.log"
  base_responses
}
reset_counts() { rm -f "$FAKE_HERDR_DIR"/.count.*; }
orch() { (cd "$WS" && PATH="$FAKE_BIN:$PATH" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 sh "$ORCH" "$@"); }
calls() { grep -c -- "$1" "$FAKE_HERDR_DIR/calls.log" || true; }
# lib CODE: run CODE with the orch libraries sourced, inside the case workspace
lib() {
  (cd "$WS" && PATH="$FAKE_BIN:$PATH" && set -f && set -u && SKILL_SCRIPTS=$SCRIPTS &&
   . "$SCRIPTS/lib/orch_common.sh" && . "$SCRIPTS/lib/orch_ledger.sh" && . "$SCRIPTS/lib/orch_herdr.sh" &&
   eval "$1")
}
# lib_run CODE: like lib, with RUN_ID=r1 resolved and an empty ledger + workers.tsv
lib_run() {
  lib "resolve_run r1 && mkdir -p \"\$RUN_DIR\" && ledger_new 0.8.2 w1 w1:t1 w1:p1 claude && workers_init && $1"
}
# task_row ID AGENT SCOPE -> shell words (for eval inside lib_run) of a full
# pending task; $WS and $RUN_DIR expand inside lib_run.
task_row() {
  printf '"task_id=\\"%s\\"" "agent_name=\\"%s\\"" "title=\\"[01] T\\"" "kind=\\"claude\\"" "pane_id=\\"w1:p2\\"" "worktree=null" "directory=\\"$WS\\"" "dependencias=[]" "scope_escritura=[\\"%s\\", \\"$RUN_DIR/%s\\"]" "criterion=\\"c\\"" "output_path=\\"$RUN_DIR/%s/report.md\\"" "evidence_refs=[\\"$RUN_DIR/%s/evidence.yml\\"]" "estado=\\"pending\\"" "runtime_status=null" "execution_outcome=\\"unknown\\"" "created_at=\\"2026-10-06T00:00:00Z\\"" "last_state_at=\\"2026-10-06T00:00:00Z\\"" "notas=\\"\\""' "$1" "$2" "$3" "$1" "$1" "$1"
}
unresp() { rm -f "$FAKE_HERDR_DIR/responses/$1" "$FAKE_HERDR_DIR/responses/$1.rc" "$FAKE_HERDR_DIR/responses/$1.err"; }

# ---- Task 3: libraries -----------------------------------------------------
new_case lib
check lib-slugify 0 "vermithrax-the-great" lib 'slugify "Vermithrax the Great!!"'
check lib-run-suffix 0 "" lib 's1=$(run_suffix abc); s2=$(run_suffix abc); [ "$s1" = "$s2" ] && printf "%s" "$s1" | grep -qx "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"'
check lib-yaml-q 0 '"a \"b\" c\\d"' lib 'yaml_q "a \"b\" c\\d"'
check lib-yaml-list 0 '["a", "b c"]' lib 'yaml_list "a,b c"'
check lib-ledger-roundtrip 0 'the "README" lists a:b \x' lib_run "
  ledger_append_task $(task_row W1 w01-a-0001 docs/a) &&
  ledger_update W1 \"criterion=\$(yaml_q 'the \"README\" lists a:b \\x')\" &&
  ledger_get W1 criterion"
check lib-ledger-validates 0 "TOTAL: " lib_run "
  ledger_append_task $(task_row W1 w01-a-0001 docs/a) &&
  ledger_append_task $(task_row W2 w02-b-0001 docs/b) &&
  sh \"\$SKILL_SCRIPTS/validate_dag.sh\" \"\$LEDGER\""
check lib-ledger-list 0 "docs/a" lib_run "
  ledger_append_task $(task_row W1 w01-a-0001 docs/a) && ledger_list W1 scope_escritura"
check lib-ledger-rows 0 "W2	w02-b-0001	pending" lib_run "
  ledger_append_task $(task_row W1 w01-a-0001 docs/a) &&
  ledger_append_task $(task_row W2 w02-b-0001 docs/b) && ledger_rows"
check lib-run-get 0 "w1:t1" lib_run 'ledger_run_get workspace herdr_tab_id'
check lib-update-missing-task 1 "" lib_run 'ledger_update NOPE "notas=\"x\""'
check lib-transitions 0 "" lib '
  allowed_transition pending launching && allowed_transition completed verified &&
  allowed_transition running failed && allowed_transition outcome-unknown pending &&
  ! allowed_transition verified cancelled && ! allowed_transition pending completed &&
  ! allowed_transition cancelled pending'
check lib-set-state 0 'succeeded|idle' lib_run "
  ledger_append_task $(task_row W1 w01-a-0001 docs/a) &&
  set_state W1 launching && set_state W1 running working && set_state W1 completed idle &&
  printf '%s|%s' \"\$(ledger_get W1 execution_outcome)\" \"\$(ledger_get W1 runtime_status)\""
check lib-set-state-illegal 1 "illegal transition" lib_run "
  ledger_append_task $(task_row W1 w01-a-0001 docs/a) && set_state W1 verified"
check lib-workers 0 "w1:p9" lib_run '
  workers_add 1 w01-a-0001 Alpha claude w1 w1:p2 "$WS" - &&
  workers_set w01-a-0001 pane_id w1:p9 && workers_field w01-a-0001 pane_id &&
  [ "$(workers_field_by_ord 1 agent_name)" = w01-a-0001 ]'
# Review Focus 5: concurrent writers must not lose updates.
check lib-parallel-lock 0 "a25|b25" lib_run "
  ledger_append_task $(task_row W1 w01-a-0001 docs/a) &&
  ledger_append_task $(task_row W2 w02-b-0001 docs/b);
  ( i=0; while [ \$i -lt 25 ]; do i=\$((i+1)); with_lock ledger_update W1 \"notas=\\\"a\$i\\\"\"; done ) &
  ( i=0; while [ \$i -lt 25 ]; do i=\$((i+1)); with_lock ledger_update W2 \"notas=\\\"b\$i\\\"\"; done ) &
  wait; printf '%s|%s' \"\$(ledger_get W1 notas)\" \"\$(ledger_get W2 notas)\""
resp agent_get '' 1 "$(herr agent_not_found)"
check lib-agent-status-gone 0 "gone" lib 'agent_status w01-x'
resp agent_get "$(agent_json w01-x working)"
check lib-agent-status 0 "working" lib 'agent_status w01-x'
check lib-shell-ready 0 "" lib 'shell_ready w1:p2'
resp pane_process-info '{"result":{"process_info":{},"type":"pane_process_info"}}'
check lib-shell-ready-empty 1 "" lib 'shell_ready w1:p2'
check lib-slugify-ascii 0 "" env LC_ALL=$(locale -a | grep -im1 'utf-\?8' || echo C) sh -c '
  . "$1/lib/orch_common.sh"; o=$(slugify "Ñandú 42"); printf "%s\n" "$o"; printf "%s" "$o" | grep -qx "[a-z0-9-]*"' _ "$SCRIPTS"
check lib-die-releases-lock 0 "" lib_run '
  ( lock_acquire; die x ) 2>/dev/null; [ ! -d "$RUN_DIR/.lock" ]'

# ---- Task 4: preflight / init-run / pool -----------------------------------
new_case preflight
check pre-ready 0 "gate=ready" orch preflight
check pre-no-herdr-env 2 "HERDR_ENV" sh -c "cd '$WS' && HERDR_ENV=0 PATH='$FAKE_BIN:$PATH' sh '$ORCH' preflight"
resp status_--json '{"client":{"version":"0.8.2"},"server":{"version":"0.9.0","compatible":false}}'
check pre-incompatible 2 "gate=blocked" orch preflight

new_case init
check init-two 0 "run t1 ready" orch init-run --run-id t1 --worker claude --worker codex:Glacielle
check init-split-count 0 "" sh -c "[ \$(grep -c '^pane split' '$FAKE_HERDR_DIR/calls.log') -eq 2 ]"
check init-first-split-right 0 "" grep -q -- "pane split --current --direction right" "$FAKE_HERDR_DIR/calls.log"
check init-second-split-down 0 "" grep -q -- "pane split --pane w1:p2 --direction down" "$FAKE_HERDR_DIR/calls.log"
check init-workers-tsv 0 "codex" sh -c "awk -F'\t' 'NR==3{print \$4}' '$WS/.herdr-orch/t1/workers.tsv'"
check init-names 0 "" sh -c "awk -F'\t' 'NR==2{print \$2}' '$WS/.herdr-orch/t1/workers.tsv' | grep -qx 'w01-vermithrax-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]'"
check init-ledger-valid 0 "empty tasks" sh -c "cd '$WS' && sh '$SCRIPTS/validate_dag.sh' .herdr-orch/t1/ledger.yaml"
check init-exclude 0 "" grep -qx '.herdr-orch/' "$WS/.git/info/exclude"
check init-label 0 "" grep -q -- 'pane rename w1:p3 \[02\] Glacielle' "$FAKE_HERDR_DIR/calls.log"
N1=$(awk -F'\t' 'NR==2{print $2}' "$WS/.herdr-orch/t1/workers.tsv")
N2=$(awk -F'\t' 'NR==3{print $2}' "$WS/.herdr-orch/t1/workers.tsv")
resp agent_list "{\"result\":{\"agents\":[{\"name\":\"$N1\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p2\"},{\"name\":\"$N2\",\"agent_status\":\"working\",\"pane_id\":\"w1:p3\"},{\"agent_status\":\"idle\",\"pane_id\":\"w9:p1\"}],\"type\":\"agent_list\"}}"
check init-rerun-reuses 0 "reused" orch init-run --run-id t1 --worker claude --worker codex:Glacielle
check init-rerun-no-new-split 0 "" sh -c "[ \$(grep -c '^pane split' '$FAKE_HERDR_DIR/calls.log') -eq 2 ]"
check pool-lists 0 "working" orch pool
check pool-unnamed-agent-ignored 0 "" sh -c "cd '$WS' && PATH='$FAKE_BIN:$PATH' HERDR_ENV=1 sh '$ORCH' pool | grep -c . | grep -qx 3"

new_case init-partial
resp agent_start.2 '' 1 "$(herr agent_not_ready)"
check init-partial-incomplete 1 "INCOMPLETE" orch init-run --run-id t2 --worker claude --worker claude
N1=$(awk -F'\t' 'NR==2{print $2}' "$WS/.herdr-orch/t2/workers.tsv")
resp agent_list "{\"result\":{\"agents\":[{\"name\":\"$N1\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p2\"}],\"type\":\"agent_list\"}}"
check init-partial-rerun 0 "started" orch init-run --run-id t2 --worker claude --worker claude
check init-partial-reused-pane 0 "" sh -c "[ \$(grep -c '^pane split' '$FAKE_HERDR_DIR/calls.log') -eq 2 ] && [ \$(grep -c '^agent start' '$FAKE_HERDR_DIR/calls.log') -eq 3 ]"

new_case collision
SFX=$(lib 'run_suffix t3')
resp agent_list "{\"result\":{\"agents\":[{\"name\":\"w01-vermithrax-$SFX\",\"agent_status\":\"idle\",\"pane_id\":\"w5:p1\"}],\"type\":\"agent_list\"}}"
check init-collision 1 "already live outside run t3" orch init-run --run-id t3 --worker claude
check init-collision-no-split 0 "" sh -c "! grep -q '^pane split' '$FAKE_HERDR_DIR/calls.log'"
check init-unknown-kind 2 "unknown agent kind" orch init-run --run-id t4 --worker gpt9

new_case worktree
resp worktree_create.1 '{"result":{"workspace":{"workspace_id":"w7"},"worktree":{"path":"/tmp/wt-one"},"type":"worktree_created"}}'
resp worktree_create.2 '{"result":{"workspace":{"workspace_id":"w8"},"tab":{"tab_id":"w8:t1"},"root_pane":{"pane_id":"w8:p1"},"worktree":{"path":"/tmp/wt-two"},"type":"worktree_created"}}'
resp pane_list '{"result":{"panes":[{"pane_id":"w7:p1"}],"type":"pane_list"}}'
check init-worktree 0 "run t6 ready" orch init-run --run-id t6 --worker claude --worker claude --worktree
check init-worktree-rows 0 "w8:p1	/tmp/wt-two	/tmp/wt-two" cat "$WS/.herdr-orch/t6/workers.tsv"
check init-worktree-fallback 0 "w7:p1	/tmp/wt-one" cat "$WS/.herdr-orch/t6/workers.tsv"
check init-worktree-no-split 0 "" sh -c "! grep -q '^pane split' '$FAKE_HERDR_DIR/calls.log' && [ \$(grep -c '^pane list' '$FAKE_HERDR_DIR/calls.log') -eq 1 ]"
check init-worktree-branch 0 "" grep -q -- "worktree create --branch orch/t6/01-" "$FAKE_HERDR_DIR/calls.log"

new_case subdir
orch init-run --run-id t5 --worker claude >/dev/null 2>&1
mkdir -p "$WS/sub"
check pool-from-subdir 2 "no run selected" sh -c "cd '$WS/sub' && PATH='$FAKE_BIN:$PATH' HERDR_ENV=1 sh '$ORCH' pool"

# ---- Task 4 review fixes ---------------------------------------------------
new_case fix-list-error
resp agent_list '' 1 "$(herr server_unavailable)"
check fix-list-error 1 "server_unavailable" orch init-run --run-id f1 --worker claude
check fix-list-error-nounbound 0 "" sh -c "! (cd '$WS' && PATH='$FAKE_BIN:$PATH' HERDR_ENV=1 sh '$ORCH' init-run --run-id f1 --worker claude 2>&1 | grep -q unbound)"

new_case fix-pool-run
check fix-pool-run-novalue 2 "--run needs a value" timeout 5 sh -c "cd '$WS' && PATH='$FAKE_BIN:$PATH' HERDR_ENV=1 sh '$ORCH' pool --run"

new_case fix-pane-get
orch init-run --run-id g1 --worker claude >/dev/null 2>&1
resp pane_get '' 1 "$(herr pane_not_found)"
check fix-pane-gone 0 "started" orch init-run --run-id g1 --worker claude
check fix-pane-gone-resplit 0 "" sh -c "[ \$(grep -c '^pane split' '$FAKE_HERDR_DIR/calls.log') -eq 2 ]"
resp pane_get '' 1 "$(herr server_busy)"
check fix-pane-busy 1 "INCOMPLETE" orch init-run --run-id g1 --worker claude
check fix-pane-busy-no-split 0 "" sh -c "[ \$(grep -c '^pane split' '$FAKE_HERDR_DIR/calls.log') -eq 2 ]"
check fix-pane-busy-row-kept 0 "" sh -c "[ \$(wc -l < '$WS/.herdr-orch/g1/workers.tsv') -eq 2 ]"

new_case fix-moved
orch init-run --run-id m1 --worker claude >/dev/null 2>&1
NM=$(awk -F'\t' 'NR==2{print $2}' "$WS/.herdr-orch/m1/workers.tsv")
resp agent_list "{\"result\":{\"agents\":[{\"name\":\"$NM\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p9\"}],\"type\":\"agent_list\"}}"
check fix-moved 0 "moved w1:p2 -> w1:p9" orch init-run --run-id m1 --worker claude
check fix-moved-row 0 "w1:p9" cat "$WS/.herdr-orch/m1/workers.tsv"

new_case fix-null-pane
resp pane_split.1 '{"result":{"pane":{}}}'
check fix-null-pane 1 "INCOMPLETE" orch init-run --run-id n1 --worker claude
check fix-null-pane-no-rename 0 "" sh -c "! grep -q 'pane rename null' '$FAKE_HERDR_DIR/calls.log' && ! grep -q '^pane rename' '$FAKE_HERDR_DIR/calls.log'"

new_case fix-ord-title
orch init-run --run-id o1 --worker claude:Alpha >/dev/null 2>&1
check fix-ord-title 2 "rerun with the same --worker flags" orch init-run --run-id o1 --worker claude:Beta

# ---- Task 5: task add / task set / dispatch --------------------------------
# setup_run CASE: initialised run "t" with two idle claude workers and the
# agent_list/agent_get fakes pointing at them; exports N1 N2.
setup_run() {
  new_case "$1"
  orch init-run --run-id t --worker claude --worker claude >/dev/null 2>&1
  N1=$(awk -F'\t' 'NR==2{print $2}' "$WS/.herdr-orch/t/workers.tsv")
  N2=$(awk -F'\t' 'NR==3{print $2}' "$WS/.herdr-orch/t/workers.tsv")
  resp agent_list "{\"result\":{\"agents\":[{\"name\":\"$N1\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p2\"},{\"name\":\"$N2\",\"agent_status\":\"idle\",\"pane_id\":\"w1:p3\"}],\"type\":\"agent_list\"}}"
  resp agent_get "$(agent_json "$N1" idle)"
  printf 'Write docs/a/README.md describing module a.\n' > "$WS/task.md"
}
st() { (cd "$WS" && SKILL_SCRIPTS=$SCRIPTS && . "$SCRIPTS/lib/orch_common.sh" && . "$SCRIPTS/lib/orch_ledger.sh" &&
        resolve_run t && ledger_get "$1" "${2:-estado}"); }

setup_run taskadd
check task-add 0 "task W1 added" orch task add --id W1 --worker 1 --criterion 'docs/a/README.md exists' --scope docs/a
check task-add-pending 0 "pending" st W1
check task-add-valid 0 "TOTAL: " sh -c "cd '$WS' && sh '$SCRIPTS/validate_dag.sh' .herdr-orch/t/ledger.yaml"
cp "$WS/.herdr-orch/t/ledger.yaml" "$C/before.yaml"
check task-add-overlap 1 "rejected" orch task add --id W2 --worker 2 --criterion c --scope docs/a/x
check task-add-rollback 0 "" cmp -s "$C/before.yaml" "$WS/.herdr-orch/t/ledger.yaml"
check task-add-unknown-worker 2 "unknown worker" orch task add --id W3 --worker 9 --criterion c --scope docs/c
check task-add-duplicate 2 "already exists" orch task add --id W1 --worker 1 --criterion c --scope docs/z
check task-set-no-notas 2 "notas" orch task set --task W1 --estado cancelled
check task-set-bad-state 2 "estado" orch task set --task W1 --estado verified --notas x
check task-set-cancel 0 "W1 -> cancelled" orch task set --task W1 --estado cancelled --notas 'replanned'
check task-set-terminal 1 "illegal transition" orch task set --task W1 --estado failed --notas 'again'

setup_run dispatch-done
orch task add --id W1 --worker 1 --criterion 'the "README" lists a:b' --scope docs/a >/dev/null
resp agent_prompt "$(agent_json "$N1" done)"
check dispatch-done 0 "completed" orch dispatch --task W1 --prompt-file "$WS/task.md"
check dispatch-done-state 0 "completed" st W1
check dispatch-done-outcome 0 "succeeded" st W1 execution_outcome
check dispatch-prompt-file 0 'criterion: "the \"README\" lists a:b"' cat "$WS/.herdr-orch/t/W1/prompt.md"
check dispatch-prompt-body 0 "describing module a" cat "$WS/.herdr-orch/t/W1/prompt.md"
check dispatch-marker 0 "" grep -q -- "agent prompt $N1 \[herdr-orch t/W1\] Read and execute $WS/.herdr-orch/t/W1/prompt.md --wait --timeout 15000" "$FAKE_HERDR_DIR/calls.log"
check dispatch-not-pending 2 "not pending" orch dispatch --task W1 --prompt-file "$WS/task.md"

setup_run dispatch-busy
orch task add --id W1 --worker 1 --criterion c --scope docs/a >/dev/null
resp agent_get "$(agent_json "$N1" working)"
check dispatch-worker-busy 1 "is working" orch dispatch --task W1 --prompt-file "$WS/task.md"
check dispatch-busy-still-pending 0 "pending" st W1

setup_run dispatch-timeout
orch task add --id W1 --worker 1 --criterion c --scope docs/a >/dev/null
resp agent_prompt '' 1 "$(herr timeout)"
check dispatch-timeout-running 0 "running" orch dispatch --task W1 --prompt-file "$WS/task.md"
check dispatch-timeout-state 0 "running" st W1

setup_run dispatch-stalled
orch task add --id W1 --worker 1 --criterion c --scope docs/a >/dev/null
resp agent_prompt '' 1 "$(herr agent_prompt_stalled)"
check dispatch-stalled 3 "outcome-unknown" orch dispatch --task W1 --prompt-file "$WS/task.md"
check dispatch-stalled-state 0 "outcome-unknown" st W1

setup_run dispatch-blocked-before-send
orch task add --id W1 --worker 1 --criterion c --scope docs/a >/dev/null
resp agent_prompt '' 1 "$(herr agent_blocked)"
check dispatch-agent-blocked 5 "approval" orch dispatch --task W1 --prompt-file "$WS/task.md"
check dispatch-agent-blocked-state 0 "outcome-unknown" st W1
check dispatch-agent-blocked-note 0 "prompt not sent" st W1 notas

setup_run dispatch-settled-blocked
orch task add --id W1 --worker 1 --criterion c --scope docs/a >/dev/null
resp agent_prompt "$(agent_json "$N1" blocked)"
check dispatch-settled-blocked 5 "approval" orch dispatch --task W1 --prompt-file "$WS/task.md"
check dispatch-settled-blocked-state 0 "awaiting-approval" st W1
check dispatch-notified 0 "" grep -q '^notification show' "$FAKE_HERDR_DIR/calls.log"

setup_run dispatch-dep
orch task add --id W1 --worker 1 --criterion c --scope docs/a >/dev/null
orch task add --id W2 --worker 2 --criterion c --scope docs/b --deps W1 >/dev/null
check dispatch-dep-unverified 2 "dependency W1" orch dispatch --task W2 --prompt-file "$WS/task.md"

# ---- orch.sh subcommand cases are appended by Tasks 4-7 --------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ]
