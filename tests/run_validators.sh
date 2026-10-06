#!/bin/sh
# Validator tests. Each case copies a fixture into a temp workspace, edits
# fields with setf, substitutes @WS@/@WT@ with physical temp paths and checks
# the validator's exit code plus an expected output substring.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SCRIPTS=$ROOT/SKILL/scripts
FIX=$ROOT/tests/fixtures
PASS=0; FAILS=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# mk NAME [BASE]: fresh case dir; raw ledger copied from fixture BASE (default valid)
mk() {
  C=$TMP/$1; mkdir -p "$C/ws" "$C/wt"
  WS=$(cd "$C/ws" && pwd -P); WT=$(cd "$C/wt" && pwd -P)
  cp "$FIX/${2:-valid}.yaml" "$C/raw.yaml"
}
# setf TASK FIELD VALUE: replace FIELD inside one task block of the raw ledger
setf() {
  awk -v id="$1" -v f="$2" -v v="$3" '
    /^  - task_id: / { cur = $0; sub(/^  - task_id: "/, "", cur); sub(/"$/, "", cur) }
    cur == id && index($0, "    " f ":") == 1 { print "    " f ": " v; next }
    { print }' "$C/raw.yaml" > "$C/raw.tmp" && mv "$C/raw.tmp" "$C/raw.yaml"
}
# render: YAML-escape backslashes in the paths, then sed-escape \, # and & for the replacement
render() {
  _ws=$(printf '%s' "$WS" | sed -e 's/\\/\\\\/g' -e 's/[\\#&]/\\&/g'); _wt=$(printf '%s' "$WT" | sed -e 's/\\/\\\\/g' -e 's/[\\#&]/\\&/g')
  sed -e "s#@WS@#$_ws#g" -e "s#@WT@#$_wt#g" "$C/raw.yaml" > "$WS/ledger.yaml"
}
dag() { render; (cd "$WS" && sh "$SCRIPTS/validate_dag.sh" ledger.yaml); }
closed() { render; (cd "$WS" && sh "$SCRIPTS/validate_ledger_closed.sh" ledger.yaml "$@"); }
# evidence TASK CRITERION [RESULT]: write report + evidence for TASK in the case workspace
evidence() {
  d=$WS/.herdr-orch/r1/$1; mkdir -p "$d"
  printf '# report\n' > "$d/report.md"
  printf 'criterion: "%s"\nresult: "%s"\nobserved: "checked by test"\n' "$2" "${3:-pass}" > "$d/evidence.yml"
}
# check NAME WANT_RC SUBSTRING CMD...
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

# ---- validate_dag.sh -------------------------------------------------------
mk valid; check dag-valid 0 "TOTAL: " dag

mk empty
cat > "$C/raw.yaml" <<'EOF'
schema_version: 4
run:
  run_id: "r1"
  herdr:
    server_version: "0.8.2"
  workspace:
    directory: "@WS@"
    herdr_workspace_id: "w1"
    herdr_tab_id: "w1:t1"
  orchestrator:
    pane_id: "w1:p1"
    kind: "claude"
tasks: []
EOF
check dag-empty-tasks 0 "empty tasks" dag

mk cycle
setf W1 estado '"pending"'; setf W1 execution_outcome '"unknown"'; setf W1 dependencias '["W2"]'
setf W2 estado '"pending"'; setf W2 execution_outcome '"unknown"'; setf W2 dependencias '["W1"]'
check dag-cycle 1 "cycle detected" dag

mk overlap-same-dir
setf W2 scope_escritura '["docs/a/sub", "@WS@/.herdr-orch/r1/W2"]'
check dag-overlap-same-dir 1 "share scope without a dependency" dag

mk overlap-with-dep
setf W2 scope_escritura '["docs/a/sub", "@WS@/.herdr-orch/r1/W2"]'; setf W2 dependencias '["W1"]'
check dag-overlap-with-dependency 0 "TOTAL: " dag

mk overlap-worktrees worktree; check dag-overlap-worktrees 0 "TOTAL: " dag

mk reassign-after-cancel
setf W1 estado '"cancelled"'; setf W1 execution_outcome '"cancelled"'; setf W1 notas '"stuck; pane read showed no writes"'
setf W2 scope_escritura '["docs/a", "@WS@/.herdr-orch/r1/W2"]'
check dag-reassign-after-cancel 0 "TOTAL: " dag

mk reassign-after-interrupted
setf W1 estado '"interrupted"'; setf W1 execution_outcome '"interrupted"'; setf W1 notas '"wait: agent is gone"'
setf W2 scope_escritura '["docs/a", "@WS@/.herdr-orch/r1/W2"]'
check dag-reassign-after-interrupted 0 "TOTAL: " dag

mk cancelled-without-notas
setf W1 estado '"cancelled"'; setf W1 execution_outcome '"cancelled"'
check dag-cancelled-without-notas 1 "requires non-empty notas" dag

mk two-active-same-agent
setf W1 estado '"running"'; setf W1 execution_outcome '"unknown"'; setf W1 runtime_status '"working"'
setf W2 estado '"running"'; setf W2 execution_outcome '"unknown"'; setf W2 runtime_status '"working"'
setf W2 agent_name '"w01-vermithrax-ab12"'
check dag-two-active-same-agent 1 "more than one active task" dag

mk unknown-key
setf W1 title '"[01] Vermithrax"\n    color: "red"'
check dag-unknown-key 1 "unknown task key: color" dag

mk pwd-mismatch; render
check dag-pwd-mismatch 1 "does not match the physical current directory" \
  sh -c "cd '$C' && sh '$SCRIPTS/validate_dag.sh' '$WS/ledger.yaml'"

mk completed-outcome
setf W1 estado '"completed"'; setf W1 execution_outcome '"unknown"'
check dag-completed-outcome 1 "completed requires execution_outcome succeeded" dag

mk output-outside-rundir
setf W1 output_path '"@WS@/docs/a/report.md"'
check dag-output-outside-rundir 1 "output_path must be an absolute file path under" dag

mk missing-run-scope
setf W1 scope_escritura '["docs/a"]'
check dag-missing-run-scope 1 "must include its run directory" dag

mk dep-not-verified
setf W1 estado '"pending"'; setf W1 execution_outcome '"unknown"'
setf W2 estado '"running"'; setf W2 execution_outcome '"unknown"'; setf W2 runtime_status '"working"'; setf W2 dependencias '["W1"]'
check dag-dep-not-verified 1 "cannot be launched until dependency W1 is verified" dag

mk schema3
sed 's/^schema_version: 4/schema_version: 3/' "$C/raw.yaml" > "$C/raw.tmp" && mv "$C/raw.tmp" "$C/raw.yaml"
check dag-schema3 1 "schema_version must be the integer 4" dag

mk dir-mismatch
setf W1 directory '"/tmp"'
check dag-dir-mismatch 1 "directory must equal run.workspace.directory" dag

mk scope-escape
setf W1 scope_escritura '["../outside", "@WS@/.herdr-orch/r1/W1"]'
check dag-scope-escape 1 "escapes the workspace" dag

mk bad-agent-name
setf W1 agent_name '"W01-Bad"'
check dag-bad-agent-name 1 "agent_name outside grammar" dag

mk quoted-criterion
setf W1 criterion '"the \\"README\\" lists a:b"'   # awk -v turns \\ into \
check dag-quoted-criterion 0 "TOTAL: " dag

# ---- check_evidence.sh -----------------------------------------------------
mk evidence-unit; render; evidence W1 'docs/a/README.md exists'
check ev-pass 0 "" sh "$SCRIPTS/check_evidence.sh" "$WS/.herdr-orch/r1/W1/evidence.yml" 'docs/a/README.md exists'
check ev-wrong-criterion 1 "[FAIL]" sh "$SCRIPTS/check_evidence.sh" "$WS/.herdr-orch/r1/W1/evidence.yml" 'something else'
evidence W1 'docs/a/README.md exists' fail
check ev-result-fail 1 "result" sh "$SCRIPTS/check_evidence.sh" "$WS/.herdr-orch/r1/W1/evidence.yml" 'docs/a/README.md exists'
check ev-missing-file 1 "missing" sh "$SCRIPTS/check_evidence.sh" "$WS/nope.yml" 'x'
check ev-usage 2 "" sh "$SCRIPTS/check_evidence.sh"

# ---- validate_ledger_closed.sh ----------------------------------------------
mk closed-valid; render
evidence W1 'docs/a/README.md exists'; evidence W2 'docs/b/README.md exists'
check closed-valid 0 "TOTAL: " closed --require-evidence

mk closed-bad-evidence; render
evidence W1 'docs/a/README.md exists'; evidence W2 'wrong criterion'
check closed-bad-evidence 1 "evidence does not prove" closed --require-evidence

mk closed-missing-evidence; render
evidence W1 'docs/a/README.md exists'
check closed-missing-evidence 1 "nonexistent evidence_refs" closed --require-evidence

mk closed-missing-report; render
evidence W1 'docs/a/README.md exists'; evidence W2 'docs/b/README.md exists'
rm "$WS/.herdr-orch/r1/W2/report.md"
check closed-missing-report 1 "nonexistent output_path" closed --require-evidence

mk degraded-ok
setf W2 estado '"failed"'; setf W2 execution_outcome '"failed"'; setf W2 notas '"worker crashed; no files written"'
render; evidence W1 'docs/a/README.md exists'
check closed-degraded-ok 0 "TOTAL: " closed --require-evidence --allow-degraded
check closed-degraded-strict 1 "is not in local estado verified" closed --require-evidence

mk active-at-close
setf W2 estado '"running"'; setf W2 execution_outcome '"unknown"'; setf W2 runtime_status '"working"'
render; evidence W1 'docs/a/README.md exists'
check closed-active-at-close 1 "active estado" closed --require-evidence --allow-degraded

mk closed-worktree worktree; render
evidence W1 'docs/a/README.md exists'; evidence W2 'docs/a/README.md exists in the worktree'
check closed-worktree 0 "TOTAL: " closed --require-evidence

mk closed-dag-fail
setf W1 estado '"pending"'; setf W1 execution_outcome '"unknown"'; setf W1 dependencias '["W2"]'
setf W2 estado '"pending"'; setf W2 execution_outcome '"unknown"'; setf W2 dependencias '["W1"]'
check closed-dag-fail 1 "the DAG gate rejected the ledger" closed

mk closed-quoted-criterion
setf W1 criterion '"the \\"README\\" lists a:b"'   # awk -v turns \\ into \
render; evidence W2 'docs/b/README.md exists'
mkdir -p "$WS/.herdr-orch/r1/W1"; printf '# r\n' > "$WS/.herdr-orch/r1/W1/report.md"
printf 'criterion: "the \\"README\\" lists a:b"\nresult: "pass"\nobserved: "ok"\n' > "$WS/.herdr-orch/r1/W1/evidence.yml"
check closed-quoted-criterion 0 "TOTAL: " closed --require-evidence

# workspace path containing a backslash must survive the awk hand-off
C=$TMP/bs; mkdir -p "$C/ws/a\\b" "$C/wt"; cp "$FIX/valid.yaml" "$C/raw.yaml"
WS=$(cd "$C/ws/a\\b" && pwd -P); WT=$(cd "$C/wt" && pwd -P)
check dag-backslash-workspace 0 "TOTAL: " dag

printf '\n%d passed, %d failed\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ]
