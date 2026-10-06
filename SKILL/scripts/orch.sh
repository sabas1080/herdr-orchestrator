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
orch.sh init-run [--run-id ID] --worker KIND[:Title]... [--worktree]
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
  printf 'kinds=%s\n' "$(herdr agent 2>&1 | sed -n 's/^ *kinds: *//p')"
  hcall pane current --current || die "cannot read the current pane: $H_ERR" 2
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

sub_init_run() {
  _ir_run=""; _ir_wt=0; _ir_specs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) [ $# -ge 2 ] || usage_die "--run-id needs a value"; _ir_run=$2; shift 2 ;;
      --worker) [ $# -ge 2 ] || usage_die "--worker needs KIND[:Title]"; _ir_specs="$_ir_specs$2
"; shift 2 ;;
      --worktree) _ir_wt=1; shift ;;
      *) usage_die "init-run: unknown argument: $1" ;;
    esac
  done
  [ -n "$_ir_specs" ] || usage_die "init-run: at least one --worker KIND[:Title] is required"
  [ -n "$_ir_run" ] || _ir_run=$(date -u +%Y%m%d-%H%M)-run
  resolve_run "$_ir_run"
  _ir_sfx=$(run_suffix "$RUN_ID")
  _ir_kinds=$(herdr agent 2>&1 | sed -n 's/^ *kinds: *//p')
  _ir_live=$(live_agent_names) || die "cannot list herdr agents: $H_ERR"

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
    if printf '%s\n' "$_ir_live" | grep -qx -- "$_ir_name" && [ -z "$(workers_field "$_ir_name" agent_name)" ]; then
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
    if printf '%s\n' "$_ir_live" | grep -qx -- "$_ir_name"; then
      printf 'reused   %s -> %s (%s)\n' "$_ir_label" "$_ir_name" "$(workers_field "$_ir_name" pane_id)"
      continue
    fi
    _ir_pane=$(workers_field "$_ir_name" pane_id)
    if [ -n "$_ir_pane" ] && ! hcall pane get "$_ir_pane"; then
      with_lock workers_delete "$_ir_name"; _ir_pane=""
    fi
    if [ -z "$_ir_pane" ]; then
      if [ "$_ir_wt" = 1 ]; then
        if ! hcall worktree create --branch "orch/$RUN_ID/$(printf '%02d' "$_ir_ord")-$(slugify "$_ir_title")" --no-focus; then
          printf 'FAILED   %s: worktree create (%s)\n' "$_ir_label" "$H_ERR"; _ir_failed=$((_ir_failed + 1)); continue
        fi
        _ir_wsid=$(printf '%s' "$H_OUT" | jq -r '.result.workspace.workspace_id')
        _ir_dir=$(printf '%s' "$H_OUT" | jq -r '.result.worktree.path')
        _ir_pane=$(printf '%s' "$H_OUT" | jq -r '.result.root_pane.pane_id // empty')
        if [ -z "$_ir_pane" ] && hcall pane list --workspace "$_ir_wsid"; then
          _ir_pane=$(printf '%s' "$H_OUT" | jq -r '.result.panes[0].pane_id // empty')
        fi
        _ir_wtcol=$_ir_dir
      else
        split_target "$_ir_ord"
        # shellcheck disable=SC2086 # _tgt_args is a deliberate word list
        if ! hcall pane split $_tgt_args --cwd "$WS" --no-focus; then
          printf 'FAILED   %s: pane split (%s)\n' "$_ir_label" "$H_ERR"; _ir_failed=$((_ir_failed + 1)); continue
        fi
        _ir_pane=$(printf '%s' "$H_OUT" | jq -r '.result.pane.pane_id')
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
    if hcall agent start "$_ir_name" --kind "$_ir_kind" --pane "$_ir_pane"; then
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
    printf 'INCOMPLETE: %d worker(s) failed; rerun init-run --run-id %s with the same --worker flags\n' "$_ir_failed" "$RUN_ID"
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
      --run) _po_run=${2:-}; shift 2 ;;
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

# ---- dispatcher --------------------------------------------------------------
cmd=${1:-help}
[ $# -gt 0 ] && shift
case "$cmd" in
  help|-h|--help) usage_text; exit 0 ;;
esac
need_env
case "$cmd" in
  preflight) sub_preflight "$@" ;;
  init-run) sub_init_run "$@" ;;
  pool) sub_pool "$@" ;;
  *) usage_text >&2; usage_die "unknown subcommand: $cmd" ;;
esac
