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
  (cd "$WS" && PATH="$FAKE_BIN:$PATH" && set -f && SKILL_SCRIPTS=$SCRIPTS &&
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

# ---- orch.sh subcommand cases are appended by Tasks 4-7 --------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ]
