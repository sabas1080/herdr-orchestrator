# orch_herdr.sh — herdr CLI wrapper. Sourced, never executed.
# herdr prints JSON on stdout; server errors are JSON on stderr with exit 1
# ({"error":{"code":...}}); syntax errors exit 2. Codes are mapped, never text.

# hcall ARGS...: run herdr; sets H_OUT, H_RC, H_ERR ("" on success), H_ERRMSG
hcall() {
  _hc_err=$(mktemp "${TMPDIR:-/tmp}/orch-herr.XXXXXX")
  H_OUT=$(herdr "$@" 2>"$_hc_err"); H_RC=$?
  H_ERR=""; H_ERRMSG=""
  if [ "$H_RC" -ne 0 ]; then
    H_ERR=$(jq -r '.error.code // empty' < "$_hc_err" 2>/dev/null)
    H_ERRMSG=$(jq -r '.error.message // empty' < "$_hc_err" 2>/dev/null)
    [ -n "$H_ERR" ] || { H_ERR="exit_$H_RC"; H_ERRMSG=$(cat "$_hc_err"); }
  fi
  rm -f "$_hc_err"
  return "$H_RC"
}
# agent_status NAME -> idle|working|blocked|done|unknown, "gone" or "error:<code>"
agent_status() {
  if hcall agent get "$1"; then printf '%s' "$H_OUT" | jq -r '.result.agent.agent_status // "unknown"'
  elif [ "$H_ERR" = agent_not_found ]; then printf 'gone'
  else printf 'error:%s' "$H_ERR"; fi
}
# live_agent_names -> names of live named agents, one per line (name is optional in herdr)
live_agent_names() {
  hcall agent list || return 1
  printf '%s' "$H_OUT" | jq -r '.result.agents[] | .name // empty'
}
# shell_ready PANE -> 0 when the pane's shell owns the foreground (nothing running)
shell_ready() {
  hcall pane process-info --pane "$1" || return 1
  [ "$(printf '%s' "$H_OUT" | jq -r '.result.process_info | (.foreground_process_group_id == .shell_pid)')" = true ]
}
wait_shell_ready() {
  _wr_i=0
  until shell_ready "$1"; do
    _wr_i=$((_wr_i + 1)); [ "$_wr_i" -lt 20 ] || return 1
    sleep 0.5 2>/dev/null || sleep 1
  done
}
# notify BODY SOUND(done|request|none): best effort, never fails the caller
notify() { herdr notification show "herdr-orchestrator" --body "$1" --sound "$2" >/dev/null 2>&1 || true; }
