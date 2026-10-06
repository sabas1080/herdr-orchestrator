#!/bin/sh
# Final gate for a closed herdr-orchestrator ledger (schema 4). Structure, IDs,
# states, paths, dependencies, cycles, scopes and timestamps are delegated to
# validate_dag.sh; this script adds the closure and evidence gates (spec §5).
# Dependencies: POSIX sh, awk and dirname. Run it from run.workspace.directory.
# output_path / evidence_refs are absolute (validate_dag.sh enforces it).
# Exit codes: 0 = pass, 1 = validation failure, 2 = usage / environment error.
set -u
LC_ALL=C
export LC_ALL
command -v awk >/dev/null 2>&1 || { printf 'ERROR: awk not available\n' >&2; exit 2; }
usage() {
  printf 'Usage: %s <ledger-path> [--require-evidence] [--allow-degraded]\n' "$0" >&2
  exit 2
}
LEDGER=
REQUIRE_EVIDENCE=0
ALLOW_DEGRADED=0
for arg in "$@"; do
  case "$arg" in
    --require-evidence) REQUIRE_EVIDENCE=1 ;;
    --allow-degraded) ALLOW_DEGRADED=1 ;;
    -*) printf 'ERROR: unknown flag: %s\n' "$arg" >&2; usage ;;
    *) [ -z "$LEDGER" ] || usage; LEDGER=$arg ;;
  esac
done
[ -n "$LEDGER" ] || usage
[ -f "$LEDGER" ] && [ -r "$LEDGER" ] || { printf 'ERROR: cannot read the ledger: %s\n' "$LEDGER" >&2; exit 2; }
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
[ -r "$SCRIPT_DIR/_validators.awk" ] || { printf 'ERROR: missing %s\n' "$SCRIPT_DIR/_validators.awk" >&2; exit 2; }
_VAL_LIB=$(cat "$SCRIPT_DIR/_validators.awk")
for f in validate_dag.sh check_evidence.sh; do
  [ -r "$SCRIPT_DIR/$f" ] || { printf 'ERROR: missing %s\n' "$SCRIPT_DIR/$f" >&2; exit 2; }
done

sh "$SCRIPT_DIR/validate_dag.sh" "$LEDGER"
DAG_RC=$?
[ "$DAG_RC" -ne 2 ] || exit 2

# Extract the closure fields as delimiter-safe records (FS = \034).
SEP=$(printf '\034')
RECORDS=$(awk -v sep="$SEP" "$_VAL_LIB
"'
function badline(msg) {
  bad = 1
  if (!reported) { printf "[FAIL] line %d: %s\n", FNR, msg | "cat 1>&2"; reported = 1 }
}
{
  if (FNR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)
  line = $0; sub(/\r$/, "", line); line = strip_comment(line)
  if (line ~ /^  - task_id:/) {
    raw = line; sub(/^  - task_id:[ \t]*/, "", raw)
    if (!parse_scalar(raw, 0)) { badline("invalid task_id"); next }
    n++; id[n] = PVAL; ev_n[n] = 0; rt_null[n] = 0
    st[n] = ""; oc[n] = ""; rt[n] = ""; cr[n] = ""; op[n] = ""; nt[n] = ""
    next
  }
  if (n && line ~ /^    [A-Za-z_][A-Za-z0-9_]*:/) {
    key = line; sub(/^    /, "", key); sub(/:.*/, "", key)
    raw = line; sub(/^    [A-Za-z_][A-Za-z0-9_]*:[ \t]*/, "", raw); raw = trim(raw)
    if (key == "evidence_refs") {
      if (!list_items(raw, LIST_ITEM)) { badline("invalid flow-style list in evidence_refs"); next }
      ev_n[n] = LIST_N
      for (i = 1; i <= LIST_N; i++) ev[n, i] = LIST_ITEM[i]
    } else if (key == "runtime_status" && raw == "null") {
      rt[n] = ""; rt_null[n] = 1
    } else if (key ~ /^(estado|execution_outcome|runtime_status|criterion|output_path|notas)$/) {
      if (!parse_scalar(raw, 0)) { badline("invalid scalar in " key); next }
      if (key == "estado") st[n] = PVAL
      else if (key == "execution_outcome") oc[n] = PVAL
      else if (key == "runtime_status") rt[n] = PVAL
      else if (key == "criterion") cr[n] = PVAL
      else if (key == "output_path") op[n] = PVAL
      else nt[n] = PVAL
    }
  }
}
END {
  for (t = 1; t <= n; t++) {
    clean = nt[t]; gsub(/\034/, " ", clean)
    print "TASK" sep id[t] sep st[t] sep oc[t] sep rt[t] sep rt_null[t] sep cr[t] sep op[t] sep ev_n[t] sep clean
    for (k = 1; k <= ev_n[t]; k++) print "EVIDENCE" sep id[t] sep st[t] sep cr[t] sep ev[t, k]
  }
  if (bad) exit 1
}' "$LEDGER")
if [ "$?" -ne 0 ]; then
  printf '[FAIL] could not extract fields from the ledger\n'
  printf 'TOTAL: 0 passed, 1 failed\n'
  exit 1
fi

FAILS=0
PASSED=0
TASKS=0
if [ "$DAG_RC" -ne 0 ]; then
  FAILS=$((FAILS + 1))
  printf '[FAIL] the DAG gate rejected the ledger (exit %s)\n' "$DAG_RC"
fi

check_verified() {
  if [ "$outcome" != "succeeded" ]; then
    printf '[FAIL] %s requires execution_outcome succeeded (actual: %s)\n' "$task_id" "$outcome"; task_bad=1
  fi
  if [ "$runtime_is_null" = "1" ] || [ -z "$runtime" ]; then
    printf '[FAIL] %s records no observed runtime_status\n' "$task_id"; task_bad=1
  fi
  if [ -z "$evidence_count" ] || [ "$evidence_count" -eq 0 ]; then
    printf '[FAIL] %s verified without evidence_refs\n' "$task_id"; task_bad=1
  fi
  if [ "$REQUIRE_EVIDENCE" -eq 1 ] && [ ! -f "$path" ]; then
    printf '[FAIL] %s nonexistent output_path: %s (--require-evidence)\n' "$task_id" "$path"; task_bad=1
  fi
  if [ "$task_bad" -eq 0 ]; then
    printf '[OK] %s has a verified terminal outcome and its report\n' "$task_id"
    PASSED=$((PASSED + 1))
  fi
}

while IFS="$SEP" read -r kind task_id f1 f2 f3 f4 f5 f6 f7 f8; do
  [ -n "$kind" ] || continue
  if [ "$kind" = "TASK" ]; then
    estado=$f1; outcome=$f2; runtime=$f3; runtime_is_null=$f4
    path=$f6; evidence_count=$f7; notas=$f8
    TASKS=$((TASKS + 1)); task_bad=0
    case "$estado" in
      verified) check_verified ;;
      failed|blocked|partial|cancelled|interrupted)
        if [ "$ALLOW_DEGRADED" -eq 0 ]; then
          printf '[FAIL] %s is not in local estado verified (estado: %s)\n' "$task_id" "$estado"; task_bad=1
        elif [ -z "$notas" ]; then
          printf '[FAIL] %s in estado %s requires non-empty notas with the reason\n' "$task_id" "$estado"; task_bad=1
        else
          printf '[OK] %s has degraded terminal outcome (%s) with reason in notas\n' "$task_id" "$estado"
          PASSED=$((PASSED + 1))
        fi ;;
      *)
        printf '[FAIL] %s in an active estado not allowed at close (estado: %s)\n' "$task_id" "$estado"; task_bad=1 ;;
    esac
    FAILS=$((FAILS + task_bad))
  elif [ "$kind" = "EVIDENCE" ]; then
    # Evidence is a gate only for verified tasks; degraded tasks may lack it.
    estado=$f1; criterion=$f2; evidence_path=$f3
    [ "$estado" = "verified" ] || continue
    if [ ! -f "$evidence_path" ]; then
      printf '[FAIL] %s nonexistent evidence_refs: %s\n' "$task_id" "$evidence_path"
      FAILS=$((FAILS + 1))
    elif reason=$(sh "$SCRIPT_DIR/check_evidence.sh" "$evidence_path" "$criterion"); then
      printf '[OK] %s evidence_refs confirms criterion: %s\n' "$task_id" "$evidence_path"
      PASSED=$((PASSED + 1))
    else
      printf '[FAIL] %s evidence does not prove criterion/result/observed: %s (%s)\n' "$task_id" "$evidence_path" "${reason#\[FAIL\] }"
      FAILS=$((FAILS + 1))
    fi
  fi
done <<EOF
$RECORDS
EOF

if [ "$TASKS" -eq 0 ]; then
  printf '[FAIL] ledger with no tasks to close\n'
  FAILS=$((FAILS + 1))
fi
printf 'TOTAL: %d passed, %d failed\n' "$PASSED" "$FAILS"
[ "$FAILS" -eq 0 ]
