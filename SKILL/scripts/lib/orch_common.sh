# orch_common.sh — shared helpers for orch.sh. Sourced, never executed.
# Globals: SKILL_SCRIPTS (set by the caller), WS, ORCH_HOME, RUN_ID, RUN_DIR,
# LEDGER, WORKERS, LOCK_HELD.

die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }
usage_die() { die "$1" 2; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

need_env() {
  [ "${HERDR_ENV:-}" = 1 ] || die "not inside a herdr pane (HERDR_ENV is not 1): plan only (degraded mode A)" 2
  command -v herdr >/dev/null 2>&1 || die "herdr not found in PATH" 2
  command -v jq >/dev/null 2>&1 || die "jq not found in PATH (orch.sh requires it)" 2
}

# yaml_q STR -> double-quoted YAML scalar; \ and " escaped; newlines/tabs -> spaces
yaml_q() {
  printf '"%s"' "$(printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}
# yaml_list CSV -> flow list of quoted items; "" -> []
yaml_list() {
  _yl_out=""; _yl_ifs=$IFS; IFS=,
  for _yl_it in $1; do
    [ -n "$_yl_it" ] && _yl_out="$_yl_out${_yl_out:+, }$(yaml_q "$_yl_it")"
  done
  IFS=$_yl_ifs; printf '[%s]' "$_yl_out"
}
# slugify TEXT -> [a-z0-9-], at most 20 chars, no leading/trailing dash
slugify() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//' |
    cut -c1-20 | sed 's/-$//'
}
# run_suffix RUN_ID -> 4 hex chars derived from the run id (agent names are
# server-global, so two runs must not produce the same name)
run_suffix() { printf '%s' "$1" | cksum | awk '{ printf "%04x", $1 % 65536 }'; }

# resolve_run [ID]: run selection from the physical cwd (spec §4)
resolve_run() {
  WS=$(pwd -P)
  ORCH_HOME=$WS/.herdr-orch
  RUN_ID=${1:-}
  if [ -z "$RUN_ID" ] && [ -f "$ORCH_HOME/current" ]; then RUN_ID=$(cat "$ORCH_HOME/current"); fi
  [ -n "$RUN_ID" ] || usage_die "no run selected in $WS: pass --run ID, or run init-run from the workspace root"
  case "$RUN_ID" in [!a-z0-9]*|*[!a-z0-9._-]*) usage_die "invalid run id: $RUN_ID" ;; esac
  RUN_DIR=$ORCH_HOME/$RUN_ID
  LEDGER=$RUN_DIR/ledger.yaml
  WORKERS=$RUN_DIR/workers.tsv
}
require_run() {
  resolve_run "${1:-}"
  [ -f "$LEDGER" ] && [ -f "$WORKERS" ] || usage_die "run $RUN_ID is not initialised in $WS (missing ledger.yaml or workers.tsv)"
}
# exclude_orch_home: keep .herdr-orch/ out of git (common dir covers worktrees)
exclude_orch_home() {
  _gd=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  mkdir -p "$_gd/info"
  grep -qx '.herdr-orch/' "$_gd/info/exclude" 2>/dev/null || printf '.herdr-orch/\n' >> "$_gd/info/exclude"
}

# Run lock (spec §4): mkdir is atomic; wait up to 60 s, then fail loudly.
LOCK_HELD=0
lock_acquire() {
  _lk_i=0
  until mkdir "$RUN_DIR/.lock" 2>/dev/null; do
    _lk_i=$((_lk_i + 1))
    [ "$_lk_i" -lt 120 ] || die "could not acquire $RUN_DIR/.lock within 60s; if no orch.sh is running remove it: rmdir '$RUN_DIR/.lock'"
    sleep 0.5 2>/dev/null || sleep 1
  done
  LOCK_HELD=1
}
lock_release() {
  if [ "$LOCK_HELD" = 1 ]; then rmdir "$RUN_DIR/.lock" 2>/dev/null; LOCK_HELD=0; fi
  return 0
}
# with_lock CMD ARGS...: run CMD holding the lock. Never nest.
with_lock() { lock_acquire; "$@"; _wl_rc=$?; lock_release; return "$_wl_rc"; }
