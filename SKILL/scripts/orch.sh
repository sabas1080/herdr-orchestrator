#!/bin/sh
# orch.sh — herdr-orchestrator entry point (spec §6). POSIX sh; needs herdr + jq.
# Run it from the orchestrator's workspace root. Exit codes: 0 ok, 1 failure,
# 2 usage/environment, 3 outcome unknown/timeout, 4 stuck (advisory),
# 5 awaiting approval.
set -u
set -f
SKILL_SCRIPTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SKILL_SCRIPTS/lib/orch_common.sh"
. "$SKILL_SCRIPTS/lib/orch_ledger.sh"
. "$SKILL_SCRIPTS/lib/orch_herdr.sh"
trap 'lock_release' EXIT
trap 'lock_release; exit 130' INT TERM

usage_text() {
  cat <<'USAGE'
orch.sh preflight
orch.sh init-run [--run-id ID] --worker KIND[:Title]... [--worktree] [--agent-arg ARG]...
orch.sh pool [--run ID]
orch.sh task add --id ID --worker NAME|NN --criterion TEXT --scope A[,B] [--deps X[,Y]] [--run ID]
orch.sh task set --task ID --estado cancelled|failed|partial|blocked|interrupted --notas TEXT [--run ID]
orch.sh dispatch --task ID --prompt-file F [--wait] [--timeout MS] [--run ID]
orch.sh wait --task ID [--timeout MS] [--stuck-secs N] [--run ID]
orch.sh reconcile --task ID [--run ID]
orch.sh verify --task ID [--run ID]
orch.sh suggest-count FILE
orch.sh close [--allow-degraded] [--run ID]
orch.sh teardown [--confirm] [--remove-worktrees] [--run ID]
USAGE
}

# ---- preflight ---------------------------------------------------------------
sub_preflight() {
  hcall status --json || die "herdr status failed: $H_ERR $H_ERRMSG" 2
  _pf_compat=$(printf '%s' "$H_OUT" | jq -r '.server.compatible')
  printf 'server_version=%s\n' "$(printf '%s' "$H_OUT" | jq -r '.server.version')"
  printf 'client_version=%s\n' "$(printf '%s' "$H_OUT" | jq -r '.client.version')"
  printf 'compatible=%s\n' "$_pf_compat"
  printf 'kinds=%s\n' "$(herdr agent </dev/null 2>&1 | sed -n 's/^ *kinds: *//p')"
  hcall pane current --current || die "cannot read the current pane: $H_ERR" 2
  if [ -r "$SKILL_SCRIPTS/prompt-templates/task-header.md" ]; then printf 'template=ok\n'
  else printf 'template=missing\n'; die "prompt-templates/task-header.md is missing or unreadable" 2; fi
  printf '%s' "$H_OUT" | jq -r '.result.pane | "workspace_id=\(.workspace_id)\ntab_id=\(.tab_id)\npane_id=\(.pane_id)\norchestrator_kind=\(.agent // "none")"'
  printf 'workspace_dir=%s\n' "$(pwd -P)"
  if git rev-parse --git-dir >/dev/null 2>&1; then printf 'git=yes\n'; else printf 'git=no\n'; fi
  if [ "$_pf_compat" != true ]; then printf 'gate=blocked reason=herdr client and server are not compatible\n'; exit 2; fi
  printf 'gate=ready\n'
}

# ---- init-run ----------------------------------------------------------------
# split_target ORD: herdr split arguments for worker ORD (spec §6 layout):
# 1 -> right of the orchestrator; then down within a column of up to 3;
# 4, 7, ... -> a new column right of the previous column's top worker.
split_target() {
  if [ "$1" -eq 1 ]; then _tgt_args="--current --direction right"; return; fi
  if [ $(( ($1 - 1) % 3 )) -eq 0 ]; then _st_from=$(( $1 - 3 )); _st_dir=right
  else _st_from=$(( $1 - 1 )); _st_dir=down; fi
  _st_pane=$(workers_field_by_ord "$_st_from" pane_id)
  if [ -n "$_st_pane" ]; then _tgt_args="--pane $_st_pane --direction $_st_dir"
  else _tgt_args="--current --direction right"; fi
}

# agent_start_with_args NAME KIND PANE ARGS_NL: hcall agent start, passing the
# newline-separated ARGS_NL (if non-empty) as separate native args after `--`.
agent_start_with_args() {
  _as_a=$4
  set -- agent start "$1" --kind "$2" --pane "$3"
  if [ -n "$_as_a" ]; then
    set -- "$@" --
    _as_old=$IFS; IFS='
'
    for _as_x in $_as_a; do set -- "$@" "$_as_x"; done
    IFS=$_as_old
  fi
  hcall "$@"
}

sub_init_run() {
  _ir_run=""; _ir_wt=0; _ir_specs=""; _ir_aargs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) [ $# -ge 2 ] || usage_die "--run-id needs a value"; _ir_run=$2; shift 2 ;;
      --worker) [ $# -ge 2 ] || usage_die "--worker needs KIND[:Title]"; _ir_specs="$_ir_specs$2
"; shift 2 ;;
      --agent-arg) [ $# -ge 2 ] || usage_die "--agent-arg needs a value"
        case "$2" in '') usage_die "--agent-arg value must not be empty" ;; esac
        case "$2" in *'
'*) usage_die "--agent-arg value must not contain a newline" ;; esac
        _ir_aargs="$_ir_aargs$2
"; shift 2 ;;
      --worktree) _ir_wt=1; shift ;;
      *) usage_die "init-run: unknown argument: $1" ;;
    esac
  done
  [ -n "$_ir_specs" ] || usage_die "init-run: at least one --worker KIND[:Title] is required"
  [ -n "$_ir_run" ] || _ir_run=$(date -u +%Y%m%d-%H%M)-run
  resolve_run "$_ir_run"
  _ir_sfx=$(run_suffix "$RUN_ID")
  _ir_kinds=$(herdr agent </dev/null 2>&1 | sed -n 's/^ *kinds: *//p')
  hcall agent list || die "cannot list herdr agents: $H_ERR $H_ERRMSG"
  _ir_live=$(printf '%s' "$H_OUT" | jq -r '.result.agents[]? | select((.name // "") != "") | "\(.name)\t\(.pane_id // "")"')

  # Pass 1: names, kinds, collisions. Nothing is created if this fails.
  _ir_ord=0; _ir_plan=""
  while IFS= read -r _ir_spec; do
    [ -n "$_ir_spec" ] || continue
    _ir_ord=$((_ir_ord + 1))
    _ir_kind=${_ir_spec%%:*}; _ir_title=""
    case "$_ir_spec" in *:*) _ir_title=${_ir_spec#*:} ;; esac
    if [ -n "$_ir_kinds" ]; then
      case "|$_ir_kinds|" in *"|$_ir_kind|"*) ;; *) usage_die "unknown agent kind '$_ir_kind' (herdr kinds: $_ir_kinds)" ;; esac
    fi
    [ -n "$_ir_title" ] || _ir_title=$(sh "$SKILL_SCRIPTS/dragon_name.sh" "$_ir_ord")
    case "$_ir_title" in *"	"*) usage_die "worker titles cannot contain tabs" ;; esac
    _ir_slug=$(slugify "$_ir_title")
    _ir_name="w$(printf '%02d' "$_ir_ord")${_ir_slug:+-$_ir_slug}-$_ir_sfx"
    _ir_have=$(workers_field_by_ord "$_ir_ord" agent_name)
    if [ -n "$_ir_have" ] && [ "$_ir_have" != "$_ir_name" ]; then
      usage_die "worker $(printf '%02d' "$_ir_ord") is already $_ir_have in run $RUN_ID; rerun with the same --worker flags"
    fi
    if printf '%s\n' "$_ir_live" | cut -f1 | grep -qx -- "$_ir_name" && [ -z "$(workers_field "$_ir_name" agent_name)" ]; then
      die "agent name $_ir_name is already live outside run $RUN_ID; choose another title or --run-id"
    fi
    _ir_plan="$_ir_plan$_ir_ord	$_ir_name	$_ir_title	$_ir_kind
"
  done <<EOF
$_ir_specs
EOF

  mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
  printf '%s\n' "$RUN_ID" > "$ORCH_HOME/current"
  exclude_orch_home
  if [ ! -f "$LEDGER" ]; then
    hcall status --json || die "herdr status failed: $H_ERR" 2
    _ir_sv=$(printf '%s' "$H_OUT" | jq -r '.server.version')
    hcall pane current --current || die "cannot read the current pane: $H_ERR" 2
    _ir_cur=$H_OUT
    with_lock ledger_new "$_ir_sv" \
      "$(printf '%s' "$_ir_cur" | jq -r '.result.pane.workspace_id')" \
      "$(printf '%s' "$_ir_cur" | jq -r '.result.pane.tab_id')" \
      "$(printf '%s' "$_ir_cur" | jq -r '.result.pane.pane_id')" \
      "$(printf '%s' "$_ir_cur" | jq -r '.result.pane.agent // "unknown"')"
  fi
  [ -f "$WORKERS" ] || with_lock workers_init

  # Pass 2: create what is missing; record each pane right after its split.
  _ir_failed=0
  while IFS='	' read -r _ir_ord _ir_name _ir_title _ir_kind; do
    [ -n "$_ir_ord" ] || continue
    _ir_label="[$(printf '%02d' "$_ir_ord")] $_ir_title"
    if printf '%s\n' "$_ir_live" | cut -f1 | grep -qx -- "$_ir_name"; then
      _ir_old=$(workers_field "$_ir_name" pane_id)
      _ir_new=$(printf '%s\n' "$_ir_live" | awk -F'\t' -v n="$_ir_name" '$1 == n { print $2; exit }')
      if [ -n "$_ir_new" ] && [ -n "$_ir_old" ] && [ "$_ir_new" != "$_ir_old" ]; then
        with_lock workers_set "$_ir_name" pane_id "$_ir_new"
        printf 'reused   %s -> %s (moved %s -> %s)\n' "$_ir_label" "$_ir_name" "$_ir_old" "$_ir_new"
      else
        printf 'reused   %s -> %s (%s)\n' "$_ir_label" "$_ir_name" "$_ir_old"
      fi
      continue
    fi
    _ir_pane=$(workers_field "$_ir_name" pane_id)
    if [ -n "$_ir_pane" ] && ! hcall pane get "$_ir_pane"; then
      if [ "$H_ERR" = pane_not_found ]; then
        with_lock workers_delete "$_ir_name"; _ir_pane=""
      else
        printf 'FAILED   %s: pane get %s (%s)\n' "$_ir_label" "$_ir_pane" "$H_ERR"
        _ir_failed=$((_ir_failed + 1)); continue
      fi
    fi
    if [ -z "$_ir_pane" ]; then
      if [ "$_ir_wt" = 1 ]; then
        if ! hcall worktree create --branch "orch/$RUN_ID/$(printf '%02d' "$_ir_ord")-$(slugify "$_ir_title")" --no-focus; then
          printf 'FAILED   %s: worktree create (%s)\n' "$_ir_label" "$H_ERR"; _ir_failed=$((_ir_failed + 1)); continue
        fi
        _ir_wsid=$(printf '%s' "$H_OUT" | jq -r '.result.workspace.workspace_id // empty')
        _ir_dir=$(printf '%s' "$H_OUT" | jq -r '.result.worktree.path // empty')
        _ir_pane=$(printf '%s' "$H_OUT" | jq -r '.result.root_pane.pane_id // empty')
        if [ -z "$_ir_pane" ] && hcall pane list --workspace "$_ir_wsid"; then
          _ir_pane=$(printf '%s' "$H_OUT" | jq -r '.result.panes[0].pane_id // empty')
        fi
        if [ -z "$_ir_wsid" ] || [ -z "$_ir_dir" ]; then
          printf 'FAILED   %s: worktree create returned no workspace or path\n' "$_ir_label"; _ir_failed=$((_ir_failed + 1)); continue
        fi
        _ir_wtcol=$_ir_dir
      else
        split_target "$_ir_ord"
        # shellcheck disable=SC2086 # _tgt_args is a deliberate word list
        if ! hcall pane split $_tgt_args --cwd "$WS" --no-focus; then
          printf 'FAILED   %s: pane split (%s)\n' "$_ir_label" "$H_ERR"; _ir_failed=$((_ir_failed + 1)); continue
        fi
        _ir_pane=$(printf '%s' "$H_OUT" | jq -r '.result.pane.pane_id // empty')
        _ir_wsid=$(printf '%s' "$H_OUT" | jq -r '.result.pane.workspace_id // empty')
        [ -n "$_ir_wsid" ] || _ir_wsid=$(ledger_run_get workspace herdr_workspace_id)
        _ir_dir=$WS; _ir_wtcol=-
      fi
      if [ -z "$_ir_pane" ]; then
        printf 'FAILED   %s: no pane id returned\n' "$_ir_label"; _ir_failed=$((_ir_failed + 1)); continue
      fi
      with_lock workers_add "$_ir_ord" "$_ir_name" "$_ir_title" "$_ir_kind" "$_ir_wsid" "$_ir_pane" "$_ir_dir" "$_ir_wtcol"
      hcall pane rename "$_ir_pane" "$_ir_label" || printf 'warning: could not label pane %s (%s)\n' "$_ir_pane" "$H_ERR" >&2
    fi
    if ! wait_shell_ready "$_ir_pane"; then
      printf 'FAILED   %s: pane %s has no idle shell in the foreground\n' "$_ir_label" "$_ir_pane"
      _ir_failed=$((_ir_failed + 1)); continue
    fi
    if agent_start_with_args "$_ir_name" "$_ir_kind" "$_ir_pane" "$_ir_aargs"; then
      printf 'started  %s -> %s (%s, %s)\n' "$_ir_label" "$_ir_name" "$_ir_kind" "$_ir_pane"
    else
      printf 'FAILED   %s: agent start %s (%s) — answer any dialog in pane %s, then rerun\n' \
        "$_ir_label" "$_ir_name" "$H_ERR" "$_ir_pane"
      _ir_failed=$((_ir_failed + 1))
    fi
  done <<EOF
$_ir_plan
EOF
  if [ "$_ir_failed" -gt 0 ]; then
    printf 'INCOMPLETE: %d worker(s) failed; rerun init-run --run-id %s with the same --worker and --agent-arg flags\n' "$_ir_failed" "$RUN_ID"
    exit 1
  fi
  printf 'run %s ready: %s\n' "$RUN_ID" "$RUN_DIR"
}

# ---- pool --------------------------------------------------------------------
# resolve_worker ARG -> agent_name for an ordinal (1, 01) or an agent name
resolve_worker() {
  case "$1" in
    *[!0-9]*|'') _rw=$(workers_field "$1" agent_name) ;;
    *) _rw=$(workers_field_by_ord "$1" agent_name) ;;
  esac
  [ -n "$_rw" ] && printf '%s' "$_rw"
}
sub_pool() {
  _po_run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run) [ $# -ge 2 ] || usage_die "--run needs a value"; _po_run=$2; shift 2 ;;
      *) usage_die "pool: unknown argument: $1" ;;
    esac
  done
  require_run "$_po_run"
  hcall agent list || die "cannot list herdr agents: $H_ERR"
  _po_agents=$H_OUT
  _po_rows=$(ledger_rows)
  printf 'ORD\tNAME\tKIND\tSTATUS\tPANE\tTASK\tESTADO\n'
  workers_rows | while IFS='	' read -r _o _n _t _k _w _p _d _x; do
    _st=$(printf '%s' "$_po_agents" | jq -r --arg n "$_n" \
      '[.result.agents[] | select((.name // "") == $n) | .agent_status][0] // "gone"')
    _tk=$(printf '%s\n' "$_po_rows" | awk -F'\t' -v n="$_n" '
      $2 == n && $3 !~ /^(verified|cancelled|failed|partial|blocked|interrupted)$/ { t = $1 "\t" $3 }
      END { if (t == "") t = "-\t-"; print t }')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_o" "$_n" "$_k" "$_st" "$_p" "$_tk"
  done
}

# ---- task add / task set -------------------------------------------------------
sub_task() {
  _tk_sub=${1:-}; [ $# -gt 0 ] && shift
  case "$_tk_sub" in
    add) sub_task_add "$@" ;;
    set) sub_task_set "$@" ;;
    *) usage_die "task: expected 'add' or 'set'" ;;
  esac
}
sub_task_add() {
  _ta_run=""; _ta_id=""; _ta_w=""; _ta_crit=""; _ta_scope=""; _ta_deps=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage_die "task add: $1 needs a value"
    case "$1" in
      --run) _ta_run=$2 ;; --id) _ta_id=$2 ;; --worker) _ta_w=$2 ;;
      --criterion) _ta_crit=$2 ;; --scope) _ta_scope=$2 ;; --deps) _ta_deps=$2 ;;
      *) usage_die "task add: unknown argument: $1" ;;
    esac
    shift 2
  done
  [ -n "$_ta_id" ] && [ -n "$_ta_w" ] && [ -n "$_ta_crit" ] && [ -n "$_ta_scope" ] ||
    usage_die "task add: --id, --worker, --criterion and --scope are required"
  case "$_ta_id" in [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) usage_die "invalid task id: $_ta_id" ;; esac
  require_run "$_ta_run"
  _ta_name=$(resolve_worker "$_ta_w") || usage_die "unknown worker: $_ta_w (see orch.sh pool)"
  [ -z "$(ledger_get "$_ta_id" task_id)" ] || usage_die "task $_ta_id already exists"
  _ta_ord=$(workers_field "$_ta_name" ord)
  _ta_wt=$(workers_field "$_ta_name" worktree)
  if [ "$_ta_wt" = - ]; then _ta_wtv=null; else _ta_wtv=$(yaml_q "$_ta_wt"); fi
  _ta_dir=$RUN_DIR/$_ta_id
  mkdir -p "$_ta_dir"
  _ta_now=$(now_utc)
  lock_acquire
  cp "$LEDGER" "$LEDGER.bak"
  if ! ledger_append_task \
    "task_id=$(yaml_q "$_ta_id")" \
    "agent_name=$(yaml_q "$_ta_name")" \
    "title=$(yaml_q "[$(printf '%02d' "$_ta_ord")] $(workers_field "$_ta_name" title)")" \
    "kind=$(yaml_q "$(workers_field "$_ta_name" kind)")" \
    "pane_id=$(yaml_q "$(workers_field "$_ta_name" pane_id)")" \
    "worktree=$_ta_wtv" \
    "directory=$(yaml_q "$(workers_field "$_ta_name" directory)")" \
    "dependencias=$(yaml_list "$_ta_deps")" \
    "scope_escritura=$(yaml_list "$_ta_scope,$_ta_dir")" \
    "criterion=$(yaml_q "$_ta_crit")" \
    "output_path=$(yaml_q "$_ta_dir/report.md")" \
    "evidence_refs=$(yaml_list "$_ta_dir/evidence.yml")" \
    'estado="pending"' 'runtime_status=null' 'execution_outcome="unknown"' \
    "created_at=$(yaml_q "$_ta_now")" "last_state_at=$(yaml_q "$_ta_now")" 'notas=""'; then
    mv "$LEDGER.bak" "$LEDGER"; lock_release
    rmdir "$_ta_dir" 2>/dev/null
    die "task $_ta_id could not be appended (ledger unchanged)"
  fi
  if _ta_out=$(cd "$WS" && sh "$SKILL_SCRIPTS/validate_dag.sh" "$LEDGER"); then
    rm -f "$LEDGER.bak"; lock_release
    printf 'task %s added -> %s\n' "$_ta_id" "$_ta_name"
  else
    mv "$LEDGER.bak" "$LEDGER"; lock_release
    rmdir "$_ta_dir" 2>/dev/null
    printf '%s\n' "$_ta_out" | grep '^\[FAIL\]'
    die "task $_ta_id rejected by validate_dag.sh (ledger unchanged)"
  fi
}
sub_task_set() {
  _ts_run=""; _ts_t=""; _ts_e=""; _ts_n=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage_die "task set: $1 needs a value"
    case "$1" in
      --run) _ts_run=$2 ;; --task) _ts_t=$2 ;; --estado) _ts_e=$2 ;; --notas) _ts_n=$2 ;;
      *) usage_die "task set: unknown argument: $1" ;;
    esac
    shift 2
  done
  [ -n "$_ts_t" ] || usage_die "task set: --task is required"
  case "$_ts_e" in cancelled|failed|partial|blocked|interrupted) ;;
    *) usage_die "task set: --estado must be cancelled, failed, partial, blocked or interrupted" ;; esac
  [ -n "$_ts_n" ] || usage_die "task set: --notas with the reason is required"
  require_run "$_ts_run"
  [ -n "$(ledger_get "$_ts_t" task_id)" ] || usage_die "unknown task: $_ts_t"
  with_lock set_state "$_ts_t" "$_ts_e" "" "$_ts_n"
  printf 'task %s -> %s\n' "$_ts_t" "$_ts_e"
}

# ---- dispatch ------------------------------------------------------------------
task_marker() { printf '[herdr-orch %s/%s]' "$RUN_ID" "$1"; }
join_lines() { awk 'NR > 1 { printf ", " } { printf "%s", $0 } END { print "" }'; }
# render_header TASK -> task-header.md with every {{KEY}} replaced by $H_KEY
render_header() (
  H_TASK_ID=$1; H_RUN_ID=$RUN_ID
  H_AGENT_NAME=$(ledger_get "$1" agent_name); H_TITLE=$(ledger_get "$1" title)
  H_DIRECTORY=$(ledger_get "$1" directory)
  H_SCOPES=$(ledger_list "$1" scope_escritura | join_lines)
  H_CRITERION=$(ledger_get "$1" criterion); H_CRITERION_YAML=$(yaml_q "$H_CRITERION")
  H_OUTPUT_PATH=$(ledger_get "$1" output_path)
  H_EVIDENCE_PATH=$(ledger_list "$1" evidence_refs | head -n 1)
  export H_TASK_ID H_RUN_ID H_AGENT_NAME H_TITLE H_DIRECTORY H_SCOPES H_CRITERION \
    H_CRITERION_YAML H_OUTPUT_PATH H_EVIDENCE_PATH
  awk '{
    out = ""; line = $0
    while ((s = index(line, "{{")) > 0 && (e = index(substr(line, s + 2), "}}")) > 0) {
      out = out substr(line, 1, s - 1) ENVIRON["H_" substr(line, s + 2, e - 1)]
      line = substr(line, s + e + 3)
    }
    print out line
  }' "$SKILL_SCRIPTS/prompt-templates/task-header.md"
)
active_task_of() { # AGENT [EXCEPT_TASK] -> first other active task of AGENT
  ledger_rows | awk -F'\t' -v n="$1" -v x="${2:-}" \
    '$2 == n && $1 != x && $3 ~ /^(launching|running|awaiting-approval|outcome-unknown)$/ { print $1; exit }'
}
sub_dispatch() {
  _dp_run=""; _dp_t=""; _dp_pf=""; _dp_wait=0; _dp_to=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait) _dp_wait=1; shift; continue ;;
    esac
    [ $# -ge 2 ] || usage_die "dispatch: $1 needs a value"
    case "$1" in
      --run) _dp_run=$2 ;; --task) _dp_t=$2 ;; --prompt-file) _dp_pf=$2 ;; --timeout) _dp_to=$2 ;;
      *) usage_die "dispatch: unknown argument: $1" ;;
    esac
    shift 2
  done
  [ -z "$_dp_to" ] || [ "$_dp_wait" -eq 1 ] || usage_die "dispatch: --timeout requires --wait"
  case "$_dp_to" in *[!0-9]*|???????????*) usage_die "dispatch: --timeout must be a number of milliseconds (at most 10 digits)" ;; esac
  [ -n "$_dp_t" ] && [ -f "$_dp_pf" ] || usage_die "dispatch: --task and an existing --prompt-file are required"
  require_run "$_dp_run"
  _dp_state=$(ledger_get "$_dp_t" estado)
  [ "$_dp_state" != launching ] || usage_die "task $_dp_t is launching (a previous dispatch did not finish); run: orch.sh reconcile --task $_dp_t"
  [ "$_dp_state" = pending ] || usage_die "dispatch: task $_dp_t is ${_dp_state:-unknown}, not pending"
  while IFS= read -r _dp_d; do
    [ -n "$_dp_d" ] || continue
    [ "$(ledger_get "$_dp_d" estado)" = verified ] || usage_die "dispatch: dependency $_dp_d of $_dp_t is not verified"
  done <<EOF
$(ledger_list "$_dp_t" dependencias)
EOF
  _dp_name=$(ledger_get "$_dp_t" agent_name)
  _dp_other=$(active_task_of "$_dp_name" "$_dp_t")
  [ -z "$_dp_other" ] || die "dispatch: worker $_dp_name already runs task $_dp_other"
  _dp_st=$(agent_status "$_dp_name")
  case "$_dp_st" in
    idle|done) ;;
    unknown) die "dispatch: worker $_dp_name status is unknown (no herdr integration for this kind? check \`herdr integration status\`, or use another kind)" ;;
    *) die "dispatch: worker $_dp_name is $_dp_st (needs idle or done)" ;;
  esac
  [ -r "$_dp_pf" ] || die "dispatch: cannot read --prompt-file $_dp_pf"
  [ -r "$SKILL_SCRIPTS/prompt-templates/task-header.md" ] || die "dispatch: task-header.md template is missing or unreadable"
  mkdir -p "$RUN_DIR/$_dp_t"
  _dp_tmp=$RUN_DIR/$_dp_t/.prompt.tmp.$$
  if ! { render_header "$_dp_t" && cat "$_dp_pf"; } > "$_dp_tmp"; then
    rm -f "$_dp_tmp"; die "dispatch: could not compose the prompt for $_dp_t"
  fi
  mv "$_dp_tmp" "$RUN_DIR/$_dp_t/prompt.md" || die "dispatch: could not write prompt.md"
  with_lock set_state "$_dp_t" launching
  _dp_line="$(task_marker "$_dp_t") Read and execute $RUN_DIR/$_dp_t/prompt.md"
  if hcall agent prompt "$_dp_name" "$_dp_line" --wait --timeout 15000; then
    _dp_st=$(printf '%s' "$H_OUT" | jq -r '.result.agent.agent_status // empty')
    [ -n "$_dp_st" ] || _dp_st=$(agent_status "$_dp_name")
  else
    case "$H_ERR" in
      timeout) _dp_st=working ;;
      agent_blocked)
        with_lock set_state "$_dp_t" outcome-unknown "" "prompt not sent: agent at approval dialog"
        notify "$_dp_t: $_dp_name is waiting for approval" request
        printf 'dispatch: %s not sent; %s waits for approval in pane %s; after it is resolved run: orch.sh reconcile --task %s\n' \
          "$_dp_t" "$_dp_name" "$(ledger_get "$_dp_t" pane_id)" "$_dp_t"
        exit 5 ;;
      *)
        if [ "$H_ERR" = agent_prompt_stalled ]; then _dp_note="prompt sent: agent_prompt_stalled"
        else _dp_note="send uncertain: $H_ERR"; fi
        with_lock set_state "$_dp_t" outcome-unknown "" "$_dp_note"
        printf 'dispatch: %s outcome-unknown (%s); do not resend; run: orch.sh reconcile --task %s\n' "$_dp_t" "$H_ERR" "$_dp_t"
        exit 3 ;;
    esac
  fi
  case "$_dp_st" in
    idle|done)
      with_lock set_state "$_dp_t" completed "$_dp_st" "prompt sent"
      printf 'dispatch: %s completed (%s); next: orch.sh verify --task %s\n' "$_dp_t" "$_dp_st" "$_dp_t"; exit 0 ;;
    blocked)
      with_lock set_state "$_dp_t" awaiting-approval blocked "prompt sent"
      notify "$_dp_t: $_dp_name needs approval" request
      printf 'dispatch: %s awaiting approval in pane %s; ask the user\n' "$_dp_t" "$(ledger_get "$_dp_t" pane_id)"; exit 5 ;;
    working)
      with_lock set_state "$_dp_t" running working "prompt sent"
      printf 'dispatch: %s running on %s\n' "$_dp_t" "$_dp_name" ;;
    *)
      with_lock set_state "$_dp_t" outcome-unknown "" "prompt sent; dispatch: agent status $_dp_st"
      printf 'dispatch: %s outcome-unknown (status %s); run: orch.sh reconcile --task %s\n' "$_dp_t" "$_dp_st" "$_dp_t"; exit 3 ;;
  esac
  if [ "$_dp_wait" = 1 ]; then
    if [ -n "$_dp_to" ]; then sub_wait --run "$RUN_ID" --task "$_dp_t" --timeout "$_dp_to"
    else sub_wait --run "$RUN_ID" --task "$_dp_t"; fi
  fi
}

# ---- wait --------------------------------------------------------------------
# read_hash AGENT: hash of recent output, ignoring the last 3 lines (spinners,
# timers) and digits, so only real progress changes it (spec §6, advisory).
read_hash() {
  hcall agent read "$1" --source recent-unwrapped --lines 200 || return 1
  _rh_hash=$(printf '%s\n' "$H_OUT" | sed '$d' | sed '$d' | sed '$d' | tr -d '0-9' | cksum)
}
sub_wait() {
  _wt_run=""; _wt_t=""; _wt_to=""; _wt_stuck=1800
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage_die "wait: $1 needs a value"
    case "$1" in
      --run) _wt_run=$2 ;; --task) _wt_t=$2 ;; --timeout) _wt_to=$2 ;; --stuck-secs) _wt_stuck=$2 ;;
      *) usage_die "wait: unknown argument: $1" ;;
    esac
    shift 2
  done
  case "$_wt_to" in *[!0-9]*|???????????*) usage_die "wait: --timeout must be a number of milliseconds (at most 10 digits)" ;; esac
  case "$_wt_stuck" in ''|*[!0-9]*|???????????*) usage_die "wait: --stuck-secs must be a number (at most 10 digits)" ;; esac
  [ -n "$_wt_t" ] || usage_die "wait: --task is required"
  require_run "$_wt_run"
  _wt_state=$(ledger_get "$_wt_t" estado)
  case "$_wt_state" in running|awaiting-approval) ;;
    *) usage_die "wait: task $_wt_t is ${_wt_state:-unknown} (needs running or awaiting-approval)" ;; esac
  _wt_name=$(ledger_get "$_wt_t" agent_name)
  _wt_start=$(date +%s); _wt_deadline=0
  [ -z "$_wt_to" ] || _wt_deadline=$(( _wt_start + (_wt_to + 999) / 1000 ))
  _wt_prev=""; _wt_since=$_wt_start; _wt_fails=0
  while :; do
    _wt_slice=60000
    if [ "$_wt_deadline" -gt 0 ]; then
      _wt_rem=$(( (_wt_deadline - $(date +%s)) * 1000 ))
      [ "$_wt_rem" -ge "$_wt_slice" ] || _wt_slice=$_wt_rem
      [ "$_wt_slice" -ge 1000 ] || _wt_slice=1000
    fi
    hcall agent wait "$_wt_name" --timeout "$_wt_slice"
    case "$H_ERR" in
      ''|timeout) _wt_st=$(agent_status "$_wt_name") ;;
      agent_not_found) _wt_st=gone ;;
      *) _wt_st="error:$H_ERR" ;;
    esac
    case "$_wt_st" in
      idle|done)
        with_lock set_state "$_wt_t" completed "$_wt_st"
        printf 'wait: %s completed (%s); next: orch.sh verify --task %s\n' "$_wt_t" "$_wt_st" "$_wt_t"; exit 0 ;;
      blocked)
        [ "$(ledger_get "$_wt_t" estado)" = awaiting-approval ] || with_lock set_state "$_wt_t" awaiting-approval blocked
        notify "$_wt_t: $_wt_name needs approval" request
        printf 'wait: %s awaiting approval in pane %s; ask the user, then wait again\n' "$_wt_t" "$(ledger_get "$_wt_t" pane_id)"; exit 5 ;;
      gone)
        with_lock set_state "$_wt_t" interrupted "" "wait: agent $_wt_name is gone"
        printf 'wait: %s interrupted (agent %s is gone)\n' "$_wt_t" "$_wt_name"; exit 1 ;;
      working)
        _wt_fails=0
        [ "$(ledger_get "$_wt_t" estado)" != awaiting-approval ] || with_lock set_state "$_wt_t" running working ;;
      *)
        _wt_fails=$((_wt_fails + 1))
        if [ "$_wt_fails" -ge 3 ]; then
          if [ "$_wt_st" = unknown ]; then
            printf 'wait: %s status unknown (no herdr integration for this kind?); estado unchanged\n' "$_wt_t"
          else
            printf 'wait: %s herdr error (%s); estado unchanged\n' "$_wt_t" "${_wt_st#error:}"
          fi
          exit 1
        fi
        sleep 1 ;;
    esac
    _wt_now=$(date +%s)
    if [ "$_wt_st" = working ] && read_hash "$_wt_name"; then
      if [ "$_rh_hash" = "$_wt_prev" ]; then
        if [ $(( _wt_now - _wt_since )) -ge "$_wt_stuck" ]; then
          printf 'wait: %s stuck: no output change for %ss (advisory; estado unchanged). Keep waiting or cancel and reassign.\n' "$_wt_t" "$_wt_stuck"
          exit 4
        fi
      else
        _wt_prev=$_rh_hash; _wt_since=$_wt_now
      fi
    fi
    if [ "$_wt_deadline" -gt 0 ] && [ "$_wt_now" -ge "$_wt_deadline" ]; then
      with_lock set_state "$_wt_t" outcome-unknown "" "wait: timeout after ${_wt_to}ms"
      printf 'wait: %s timeout; outcome-unknown; run: orch.sh reconcile --task %s\n' "$_wt_t" "$_wt_t"; exit 3
    fi
  done
}

# ---- reconcile -----------------------------------------------------------------
# reconcile_write TASK NEW RT NOTE (lock held): set_state; a return to pending also clears runtime_status
reconcile_write() {
  set_state "$1" "$2" "$3" "$4" || return 1
  [ "$2" != pending ] || ledger_update "$1" 'runtime_status=null'
}
sub_reconcile() {
  _rc_run=""; _rc_t=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage_die "reconcile: $1 needs a value"
    case "$1" in --run) _rc_run=$2 ;; --task) _rc_t=$2 ;; *) usage_die "reconcile: unknown argument: $1" ;; esac
    shift 2
  done
  [ -n "$_rc_t" ] || usage_die "reconcile: --task is required"
  require_run "$_rc_run"
  _rc_state=$(ledger_get "$_rc_t" estado)
  case "$_rc_state" in outcome-unknown|launching|running|awaiting-approval) ;;
    *) usage_die "reconcile: task $_rc_t is ${_rc_state:-unknown} (needs launching, outcome-unknown, running or awaiting-approval)" ;; esac
  _rc_name=$(ledger_get "$_rc_t" agent_name)
  _rc_out=$(ledger_get "$_rc_t" output_path)
  _rc_st=$(agent_status "$_rc_name")
  case "$_rc_st" in
    gone) _rc_new=interrupted; _rc_rt=""; _rc_note="reconcile: agent gone" ;;
    working) _rc_new=running; _rc_rt=working; _rc_note="" ;;
    blocked) _rc_new=awaiting-approval; _rc_rt=blocked; _rc_note="" ;;
    idle|done)
      _rc_rt=$_rc_st
      if [ -f "$_rc_out" ]; then _rc_new=completed; _rc_note="reconcile: report present"
      else
        if ! hcall agent read "$_rc_name" --source recent-unwrapped --lines 400; then
          printf 'reconcile: %s unchanged (pane read failed: %s)\n' "$_rc_t" "$H_ERR"; exit 3
        fi
        _rc_rtold=$(ledger_get "$_rc_t" runtime_status); _rc_notas=$(ledger_get "$_rc_t" notas)
        # only the current attempt counts: text after the last "prompt not delivered" reset
        case "$_rc_notas" in *"reconciled: prompt not delivered"*) _rc_notas=${_rc_notas##*"reconciled: prompt not delivered"} ;; esac
        if printf '%s\n' "$H_OUT" | grep -F -- "$(task_marker "$_rc_t")" >/dev/null; then
          _rc_new=completed; _rc_note="reconcile: prompt seen, no report yet"
        elif case "$_rc_notas" in *"prompt not sent"*) true ;;
               *"prompt sent"*) false ;;
               *) case "$_rc_rtold" in ''|null) true ;; *) false ;; esac ;; esac; then
          _rc_new=pending; _rc_rt=""; _rc_note="reconciled: prompt not delivered"
        else _rc_new=completed; _rc_note="reconcile: delivered earlier; no report"; fi
      fi ;;
    *) printf 'reconcile: %s unchanged (agent status %s)\n' "$_rc_t" "$_rc_st"; exit 3 ;;
  esac
  if ! allowed_transition "$_rc_state" "$_rc_new"; then
    printf 'reconcile: %s stays %s (observed %s; %s -> %s is not allowed)\n' "$_rc_t" "$_rc_state" "$_rc_st" "$_rc_state" "$_rc_new"
    exit 3
  fi
  with_lock reconcile_write "$_rc_t" "$_rc_new" "$_rc_rt" "$_rc_note"
  printf 'reconcile: %s -> %s (agent %s)\n' "$_rc_t" "$_rc_new" "$_rc_st"
  [ "$_rc_new" != awaiting-approval ] || exit 5
}

# ---- verify --------------------------------------------------------------------
sub_verify() {
  _vf_run=""; _vf_t=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage_die "verify: $1 needs a value"
    case "$1" in --run) _vf_run=$2 ;; --task) _vf_t=$2 ;; *) usage_die "verify: unknown argument: $1" ;; esac
    shift 2
  done
  [ -n "$_vf_t" ] || usage_die "verify: --task is required"
  require_run "$_vf_run"
  _vf_state=$(ledger_get "$_vf_t" estado)
  [ "$_vf_state" = completed ] || usage_die "verify: task $_vf_t is ${_vf_state:-unknown} (needs completed)"
  _vf_crit=$(ledger_get "$_vf_t" criterion)
  _vf_out=$(ledger_get "$_vf_t" output_path)
  _vf_bad=0
  [ -f "$_vf_out" ] || { printf '[FAIL] %s report missing: %s\n' "$_vf_t" "$_vf_out"; _vf_bad=1; }
  while IFS= read -r _vf_e; do
    [ -n "$_vf_e" ] || continue
    if ! _vf_r=$(sh "$SKILL_SCRIPTS/check_evidence.sh" "$_vf_e" "$_vf_crit"); then
      printf '[FAIL] %s %s: %s\n' "$_vf_t" "$_vf_e" "${_vf_r#\[FAIL\] }"; _vf_bad=1
    fi
  done <<EOF
$(ledger_list "$_vf_t" evidence_refs)
EOF
  [ "$_vf_bad" = 0 ] || exit 1
  with_lock set_state "$_vf_t" verified
  printf '[OK] %s verified; report: %s\n' "$_vf_t" "$_vf_out"
}

# ---- close ---------------------------------------------------------------------
sub_close() {
  _cl_run=""; _cl_deg=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow-degraded) _cl_deg=1; shift ;;
      --run) [ $# -ge 2 ] || usage_die "--run needs a value"; _cl_run=$2; shift 2 ;;
      *) usage_die "close: unknown argument: $1" ;;
    esac
  done
  require_run "$_cl_run"
  _cl_ws=$(ledger_run_get workspace directory)
  [ -n "$_cl_ws" ] && [ -d "$_cl_ws" ] || die "run.workspace.directory missing or unreadable: $_cl_ws" 2
  if [ "$_cl_deg" = 1 ]; then set -- --require-evidence --allow-degraded; else set -- --require-evidence; fi
  _cl_out=$(cd "$_cl_ws" && sh "$SKILL_SCRIPTS/validate_ledger_closed.sh" "$LEDGER" "$@" 2>&1); _cl_rc=$?
  # [FAIL] lines plus only the last TOTAL: line (the closure total; validate_dag prints one first)
  printf '%s\n' "$_cl_out" | awk '/^\[FAIL\]/ { print } /^TOTAL:/ { t = $0 } END { if (t != "") print t }'
  if [ "$_cl_rc" -ne 0 ]; then printf '%s\n' "$_cl_out" | grep -v -e '^\[FAIL\]' -e '^TOTAL:' >&2; fi
  if [ "$_cl_rc" -eq 0 ]; then notify "run $RUN_ID closed" done
  else notify "run $RUN_ID: close failed" request; fi
  exit "$_cl_rc"
}

# ---- teardown ------------------------------------------------------------------
# Only panes/worktrees recorded in this run's workers.tsv; never --force. Exit 1
# when a close/removal failed for any reason other than pane_not_found.
sub_teardown() {
  _td_run=""; _td_ok=0; _td_rmwt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm) _td_ok=1; shift ;;
      --remove-worktrees) _td_rmwt=1; shift ;;
      --run) [ $# -ge 2 ] || usage_die "--run needs a value"; _td_run=$2; shift 2 ;;
      *) usage_die "teardown: unknown argument: $1" ;;
    esac
  done
  require_run "$_td_run"
  _td_rows=$(workers_rows)
  _td_orch=$(ledger_run_get orchestrator pane_id)
  # live panes by agent name (one list call; failure means "unknown": use the recorded pane)
  _td_live=""
  if hcall agent list; then
    _td_live=$(printf '%s' "$H_OUT" | jq -r '.result.agents[]? | select((.name // "") != "") | "\(.name)\t\(.pane_id // "")"')
  fi
  ledger_rows | while IFS='	' read -r _t _a _e; do
    case "$_e" in launching|running|awaiting-approval|outcome-unknown)
      printf 'WARNING: task %s (%s) is %s\n' "$_t" "$_a" "$_e" ;; esac
  done
  [ "$_td_ok" = 1 ] || printf 'dry run: nothing is changed without --confirm (only panes/worktrees recorded by run %s)\n' "$RUN_ID"
  _td_fail=0
  while IFS='	' read -r _o _n _t _k _w _p _d _x; do
    [ -n "$_n" ] || continue
    _td_lp=$(printf '%s\n' "$_td_live" | awk -F'\t' -v n="$_n" '$1 == n { print $2; exit }')
    _td_moved=""; _td_pane=$_p
    if [ -n "$_td_lp" ] && [ "$_td_lp" != "$_p" ]; then _td_pane=$_td_lp; _td_moved=", moved from $_p"; fi
    case "$_td_pane" in
      w*:p*) ;;
      *) printf 'skipped %s (%s): not a herdr pane id\n' "$_td_pane" "$_n"; continue ;;
    esac
    if [ "$_td_pane" = "$_td_orch" ] || [ "$_td_pane" = "${HERDR_PANE_ID:-}" ]; then
      printf 'skipped pane %s (%s): it is the orchestrator pane\n' "$_td_pane" "$_n"; continue
    fi
    if [ "$_td_ok" = 0 ]; then
      if [ "$_x" != - ] && [ "$_td_rmwt" = 1 ]; then printf 'would remove worktree %s (workspace %s, %s)\n' "$_x" "$_w" "$_n"
      else printf 'would close pane %s (%s%s)\n' "$_td_pane" "$_n" "$_td_moved"; fi
      continue
    fi
    if [ "$_x" != - ] && [ "$_td_rmwt" = 1 ]; then
      if hcall worktree remove --workspace "$_w"; then printf 'removed worktree %s\n' "$_x"
      else
        printf 'kept worktree %s (%s); pane %s was left open too; remove it yourself if intended\n' "$_x" "$H_ERR" "$_td_pane"
        _td_fail=$((_td_fail + 1))
      fi
      continue
    fi
    if hcall pane close "$_td_pane"; then
      printf 'closed pane %s (%s%s)\n' "$_td_pane" "$_n" "$_td_moved"
      [ -z "$_td_moved" ] || with_lock workers_set "$_n" pane_id "$_td_pane"
    elif [ "$H_ERR" = pane_not_found ]; then printf 'pane %s (%s): already closed\n' "$_td_pane" "$_n"
    else printf 'pane %s (%s): could not close (%s)\n' "$_td_pane" "$_n" "$H_ERR"; _td_fail=$((_td_fail + 1)); fi
  done <<EOF
$_td_rows
EOF
  [ "$_td_fail" -eq 0 ] || { printf 'teardown: %d failure(s)\n' "$_td_fail" >&2; exit 1; }
}

# ---- suggest-count -------------------------------------------------------------
# Never reads H_ERR: hcall runs inside $( ... ) here.
sub_suggest_count() {
  [ $# -eq 1 ] && [ -f "$1" ] || usage_die "suggest-count FILE"
  _sc_words=$(wc -w < "$1" | tr -d ' ')
  _sc_bullets=$(grep -cE '^[[:space:]]*([0-9]+[.)]|[-*])[[:space:]]' "$1" || true)
  _sc_n=1
  [ "$_sc_words" -lt 200 ] || _sc_n=2
  [ "$_sc_words" -lt 500 ] || _sc_n=3
  [ "$_sc_bullets" -lt 3 ] || [ "$_sc_n" -ge 2 ] || _sc_n=2
  [ "$_sc_bullets" -lt 6 ] || _sc_n=3
  _sc_idle=$( (require_run "" >/dev/null 2>&1 && hcall agent list &&
      workers_rows | while IFS='	' read -r _o _n _r; do
        printf '%s' "$H_OUT" | jq -r --arg n "$_n" '.result.agents[] | select((.name // "") == $n) | .agent_status'
      done | grep -cE '^(idle|done)$') 2>/dev/null || true)
  if [ -n "$_sc_idle" ] && [ "$_sc_idle" -gt 0 ] && [ "$_sc_n" -gt "$_sc_idle" ]; then _sc_n=$_sc_idle; fi
  printf 'suggest-count=%s words=%s bullets=%s idle_workers=%s' "$_sc_n" "$_sc_words" "$_sc_bullets" "${_sc_idle:-unknown}"
  if [ "${_sc_idle:-}" = 0 ]; then printf ' note=no idle workers'; fi
  printf '\n'
}

# ---- dispatcher --------------------------------------------------------------
cmd=${1:-help}
[ $# -gt 0 ] && shift
case "$cmd" in
  help|-h|--help) usage_text; exit 0 ;;
  suggest-count) sub_suggest_count "$@"; exit $? ;;  # planning aid: works without herdr
esac
need_env
case "$cmd" in
  preflight) sub_preflight "$@" ;;
  init-run) sub_init_run "$@" ;;
  pool) sub_pool "$@" ;;
  task) sub_task "$@" ;;
  dispatch) sub_dispatch "$@" ;;
  wait) sub_wait "$@" ;;
  reconcile) sub_reconcile "$@" ;;
  verify) sub_verify "$@" ;;
  close) sub_close "$@" ;;
  teardown) sub_teardown "$@" ;;
  *) usage_text >&2; usage_die "unknown subcommand: $cmd" ;;
esac
