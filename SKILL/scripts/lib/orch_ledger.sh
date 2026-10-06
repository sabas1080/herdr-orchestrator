# orch_ledger.sh — ledger.yaml and workers.tsv helpers. Sourced, never executed.
# Readers need no lock; every writer requires the caller to hold the run lock.

# awk decoder for a double-quoted YAML scalar (inverse of yaml_q); null -> ""
AWK_DEC='function dec(s,   o, i, c) {
  if (s == "null") return ""
  if (substr(s, 1, 1) != "\"") return s
  o = ""
  for (i = 2; i < length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") { i++; c = substr(s, i, 1) }
    o = o c
  }
  return o
}'

# ledger_new SERVER_VERSION WS_ID TAB_ID ORCH_PANE ORCH_KIND (writer)
ledger_new() {
  _ln_tmp=$RUN_DIR/.ledger.tmp.$$
  {
    printf 'schema_version: 4\nrun:\n'
    printf '  run_id: %s\n' "$(yaml_q "$RUN_ID")"
    printf '  herdr:\n    server_version: %s\n' "$(yaml_q "$1")"
    printf '  workspace:\n    directory: %s\n' "$(yaml_q "$WS")"
    printf '    herdr_workspace_id: %s\n    herdr_tab_id: %s\n' "$(yaml_q "$2")" "$(yaml_q "$3")"
    printf '  orchestrator:\n    pane_id: %s\n    kind: %s\n' "$(yaml_q "$4")" "$(yaml_q "$5")"
    printf 'tasks: []\n'
  } > "$_ln_tmp" && mv "$_ln_tmp" "$LEDGER"
}
# ledger_append_task KEY=YAMLVALUE... in schema order, task_id first (writer)
ledger_append_task() {
  _la_tmp=$RUN_DIR/.ledger.tmp.$$
  {
    awk '{ if ($0 == "tasks: []") print "tasks:"; else print }' "$LEDGER"
    _la_first=1
    for _la_kv in "$@"; do
      if [ "$_la_first" = 1 ]; then printf '  - %s: %s\n' "${_la_kv%%=*}" "${_la_kv#*=}"; _la_first=0
      else printf '    %s: %s\n' "${_la_kv%%=*}" "${_la_kv#*=}"; fi
    done
  } > "$_la_tmp" && mv "$_la_tmp" "$LEDGER"
}
# ledger_get TASK FIELD -> decoded scalar ("" for null), raw text for lists
ledger_get() {
  awk -v id="$1" -v f="$2" "$AWK_DEC"'
    /^  - task_id: / {
      v = $0; sub(/^  - task_id: /, "", v); cur = dec(v)
      if (cur == id && f == "task_id") { print cur; exit }
      next
    }
    cur == id && index($0, "    " f ": ") == 1 { print dec(substr($0, length(f) + 7)); exit }
  ' "$LEDGER"
}
# ledger_list TASK FIELD -> one decoded list item per line
ledger_list() {
  ledger_get "$1" "$2" | awk "$(cat "$SKILL_SCRIPTS/_validators.awk")"'
    { if (list_items($0, ITEMS)) for (i = 1; i <= LIST_N; i++) print ITEMS[i] }'
}
# ledger_run_get SECTION KEY -> run.SECTION.KEY ("" SECTION for run-level keys)
ledger_run_get() {
  awk -v s="$1" -v k="$2" "$AWK_DEC"'
    /^tasks:/ { exit }
    s == "" && index($0, "  " k ": ") == 1 { print dec(substr($0, length(k) + 5)); exit }
    /^  [a-z_]+:$/ { sec = substr($0, 3, length($0) - 3); next }
    s != "" && sec == s && index($0, "    " k ": ") == 1 { print dec(substr($0, length(k) + 7)); exit }
  ' "$LEDGER"
}
# ledger_rows -> "task_id<TAB>agent_name<TAB>estado" per task
ledger_rows() {
  awk "$AWK_DEC"'
    function flush() { if (id != "") print id "\t" ag "\t" st }
    /^  - task_id: / { flush(); v = $0; sub(/^  - task_id: /, "", v); id = dec(v); ag = ""; st = ""; next }
    /^    agent_name: / { v = $0; sub(/^    agent_name: /, "", v); ag = dec(v) }
    /^    estado: / { v = $0; sub(/^    estado: /, "", v); st = dec(v) }
    END { flush() }
  ' "$LEDGER"
}
# ledger_update TASK KEY=YAMLVALUE... : replace fields inside one task (writer)
ledger_update() {
  _lu_id=$1; shift
  _lu_tmp=$RUN_DIR/.ledger.tmp.$$
  if printf '%s\n' "$@" | awk -v id="$_lu_id" "$AWK_DEC"'
      NR == FNR { k = $0; sub(/=.*/, "", k); upd[k] = substr($0, length(k) + 2); next }
      /^  - task_id: / { v = $0; sub(/^  - task_id: /, "", v); in_t = (dec(v) == id); if (in_t) found = 1; print; next }
      in_t && match($0, /^    [A-Za-z_][A-Za-z0-9_]*: /) {
        k = substr($0, 5, RLENGTH - 6)
        if (k in upd) { print "    " k ": " upd[k]; hit[k] = 1; next }
      }
      { print }
      END { if (!found) exit 3; for (k in upd) if (!(k in hit)) exit 4 }
    ' - "$LEDGER" > "$_lu_tmp"; then
    mv "$_lu_tmp" "$LEDGER"
  else
    rm -f "$_lu_tmp"; die "ledger_update: task $_lu_id or one of its fields not found"
  fi
}

# State machine (spec §5). allowed_transition FROM TO -> 0 when allowed.
allowed_transition() {
  case "$1>$2" in
    'pending>launching'|'launching>running'|'launching>completed'|'launching>awaiting-approval'|'launching>outcome-unknown'|'launching>pending') return 0 ;;
    'running>running'|'running>completed'|'running>awaiting-approval'|'running>outcome-unknown'|'running>interrupted') return 0 ;;
    'awaiting-approval>awaiting-approval'|'awaiting-approval>running'|'awaiting-approval>completed'|'awaiting-approval>outcome-unknown'|'awaiting-approval>interrupted') return 0 ;;
    'outcome-unknown>outcome-unknown'|'outcome-unknown>running'|'outcome-unknown>completed'|'outcome-unknown>awaiting-approval'|'outcome-unknown>interrupted'|'outcome-unknown>pending') return 0 ;;
    'completed>verified') return 0 ;;
  esac
  case "$1" in verified|blocked|failed|partial|interrupted|cancelled) return 1 ;; esac
  case "$2" in cancelled|failed|partial|blocked|interrupted) return 0 ;; esac
  return 1
}
# outcome_for STATE -> execution_outcome to record ("" = leave unchanged)
outcome_for() {
  case "$1" in
    completed) printf 'succeeded' ;;
    interrupted|cancelled|failed) printf '%s' "$1" ;;
    pending|launching|running|awaiting-approval|outcome-unknown) printf 'unknown' ;;
  esac
}
# set_state TASK NEW [RUNTIME] [NOTE]: guarded transition (writer)
set_state() {
  _ss_t=$1; _ss_new=$2; _ss_rt=${3:-}; _ss_note=${4:-}
  _ss_old=$(ledger_get "$_ss_t" estado)
  allowed_transition "$_ss_old" "$_ss_new" || die "illegal transition for $_ss_t: $_ss_old -> $_ss_new"
  set -- "estado=$(yaml_q "$_ss_new")" "last_state_at=$(yaml_q "$(now_utc)")"
  _ss_oc=$(outcome_for "$_ss_new")
  [ -z "$_ss_oc" ] || set -- "$@" "execution_outcome=$(yaml_q "$_ss_oc")"
  [ -z "$_ss_rt" ] || set -- "$@" "runtime_status=$(yaml_q "$_ss_rt")"
  if [ -n "$_ss_note" ]; then
    _ss_prev=$(ledger_get "$_ss_t" notas)
    set -- "$@" "notas=$(yaml_q "${_ss_prev:+$_ss_prev; }$_ss_note")"
  fi
  ledger_update "$_ss_t" "$@"
}

# workers.tsv (spec §4): ord agent_name title kind workspace_id pane_id directory worktree
WORKERS_HEADER='ord	agent_name	title	kind	workspace_id	pane_id	directory	worktree'
workers_init() { printf '%s\n' "$WORKERS_HEADER" > "$WORKERS"; }
workers_add() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$WORKERS"; }
workers_rows() { tail -n +2 "$WORKERS"; }
workers_field() {
  awk -F'\t' -v n="$1" -v c="$2" 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $2 == n { print $(col[c]); exit }' "$WORKERS" 2>/dev/null
}
workers_field_by_ord() {
  awk -F'\t' -v o="$1" -v c="$2" 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $1 + 0 == o + 0 { print $(col[c]); exit }' "$WORKERS" 2>/dev/null
}
workers_set() {
  _ws_tmp=$WORKERS.tmp.$$
  awk -F'\t' -v OFS='\t' -v n="$1" -v c="$2" -v v="$3" '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; print; next }
    $2 == n { $(col[c]) = v } { print }' "$WORKERS" > "$_ws_tmp" && mv "$_ws_tmp" "$WORKERS"
}
workers_delete() {
  _wd_tmp=$WORKERS.tmp.$$
  awk -F'\t' -v n="$1" 'NR == 1 || $2 != n' "$WORKERS" > "$_wd_tmp" && mv "$_wd_tmp" "$WORKERS"
}
