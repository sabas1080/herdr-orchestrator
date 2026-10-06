#!/bin/sh
# Validate a herdr-orchestrator ledger (schema 4) and its task DAG.
# Dependencies: POSIX sh and POSIX awk. No YAML library is used.
# Accepted YAML subset: canonical root map, exact indentation, double-quoted
# strings, null, flow lists, blank lines and full-line/inline comments (an
# inline comment is a "#" preceded by whitespace, outside double quotes).
# Encoding: UTF-8 without BOM is canonical; a leading BOM is tolerated.
# Line endings: LF or CRLF for the ledger; this script must be checked out LF.
# Exit codes: 0 = pass, 1 = validation failure, 2 = usage / environment error.
# Run it from run.workspace.directory: that path must equal `pwd -P`.
set -u
# Byte-exact length/substr/comparisons, independent of the caller's locale.
LC_ALL=C
export LC_ALL
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
command -v awk >/dev/null 2>&1 || { printf 'ERROR: awk not available\n' >&2; exit 2; }
[ -r "$SCRIPT_DIR/_validators.awk" ] || { printf 'ERROR: missing %s\n' "$SCRIPT_DIR/_validators.awk" >&2; exit 2; }
# Shared awk helpers (trim, strip_comment, parse_scalar, list_items) are
# prepended to the program below. Never re-define them here.
_VAL_LIB=$(cat "$SCRIPT_DIR/_validators.awk")
if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <ledger-path>\n' "$0" >&2
  exit 2
fi
LEDGER=$1
WS_PHYS=$(pwd -P 2>/dev/null) || { printf 'ERROR: cannot determine the current directory (pwd -P)\n' >&2; exit 2; }
case "$WS_PHYS" in /*) ;; *) printf 'ERROR: the current directory must be an absolute path\n' >&2; exit 2 ;; esac
if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then
  printf 'ERROR: cannot read the ledger: %s\n' "$LEDGER" >&2
  exit 2
fi

WS_PHYS="$WS_PHYS" awk "$_VAL_LIB
"'
function fail(msg) { printf "[FAIL] %s\n", msg; failures++ }
function ok(msg) { printf "[OK] %s\n", msg; passed++ }
function split_key(s,   n) {
  if (!match(s, /^[A-Za-z_][A-Za-z0-9_]*:/)) return 0
  n = RLENGTH
  KEY = substr(s, 1, n - 1)
  RAW = trim(substr(s, n + 1))
  return 1
}
function set_run(full, raw) {
  if (!(full in RUN_KEYS)) { fail("unknown key in run: " full); return }
  if (seen_run[full]++) { fail("duplicate key: run." full); return }
  if (!parse_scalar(raw, 0) || PVAL == "") { fail("run." full " must be a non-empty double-quoted string"); return }
  run_value[full] = PVAL
}
function set_task(i, key, raw,   j, allow_null) {
  if (!(key in TASK_KEYS)) { fail("unknown task key: " key); return }
  if (seen_task[i, key]++) { fail("duplicate task key at position " i ": " key); return }
  if (key == "dependencias" || key == "scope_escritura" || key == "evidence_refs") {
    if (!list_items(raw, LIST_VALUE)) { fail("invalid flow-style list in task " i ": " key); return }
    task_count[i, key] = LIST_N
    for (j = 1; j <= LIST_N; j++) task_list[i, key, j] = LIST_VALUE[j]
    return
  }
  allow_null = (key == "pane_id" || key == "worktree" || key == "runtime_status")
  if (!parse_scalar(raw, allow_null)) { fail("invalid scalar in task " i ": " key " (use a double-quoted string)"); return }
  task_value[i, key] = PVAL
  task_null[i, key] = PNULL
}
# POSIX path helpers: normalise "." and "..", compare by path components.
function normpath(p,   n, parts, i, seg, m, out, k, res, abs) {
  if (p == "") return ""
  abs = (substr(p, 1, 1) == "/")
  n = split(p, parts, "/"); m = 0
  for (i = 1; i <= n; i++) {
    seg = parts[i]
    if (seg == "" || seg == ".") continue
    if (seg == "..") { if (m > 0 && out[m] != "..") m--; else if (!abs) out[++m] = ".." }
    else out[++m] = seg
  }
  res = ""
  for (k = 1; k <= m; k++) res = res (k > 1 ? "/" : "") out[k]
  if (abs) return "/" res
  return (res == "") ? "." : res
}
function covers(parent, child,   lp) {
  if (parent == child) return 1
  lp = length(parent)
  if (substr(parent, lp, 1) == "/") return substr(child, 1, lp) == parent
  return substr(child, 1, lp) == parent && substr(child, lp + 1, 1) == "/"
}
function touches(a, b) { return covers(a, b) || covers(b, a) }
# Canonical absolute form of a task path (spec §4): relative paths resolve
# against the task directory; absolute paths must sit under the workspace or
# under the task directory.
function canon(i, p,   n, base) {
  if (p == "") return "!OUTSIDE!"
  base = TDIR[i]
  if (substr(p, 1, 1) == "/") {
    n = normpath(p)
    if (covers(WS, n) || (base != "" && covers(base, n))) return n
    return "!OUTSIDE!"
  }
  n = normpath(p)
  if (base == "" || n == ".." || substr(n, 1, 3) == "../") return "!OUTSIDE!"
  if (n == ".") return base
  return normpath(base "/" n)
}
function norm_time(ts,   y, mo, day, hh, mi, ss, yn, mn, dn, hn, min, sn, mdays, leap) {
  if (length(ts) != 20 || substr(ts, 5, 1) != "-" || substr(ts, 8, 1) != "-" ||
      substr(ts, 11, 1) != "T" || substr(ts, 14, 1) != ":" ||
      substr(ts, 17, 1) != ":" || substr(ts, 20, 1) != "Z") return ""
  y = substr(ts, 1, 4); mo = substr(ts, 6, 2); day = substr(ts, 9, 2)
  hh = substr(ts, 12, 2); mi = substr(ts, 15, 2); ss = substr(ts, 18, 2)
  if (y !~ /^[0-9][0-9][0-9][0-9]$/ || mo !~ /^[0-9][0-9]$/ ||
      day !~ /^[0-9][0-9]$/ || hh !~ /^[0-9][0-9]$/ ||
      mi !~ /^[0-9][0-9]$/ || ss !~ /^[0-9][0-9]$/) return ""
  yn = y + 0; mn = mo + 0; dn = day + 0
  hn = hh + 0; min = mi + 0; sn = ss + 0
  if (yn < 1 || mn < 1 || mn > 12 || hn > 23 || min > 59 || sn > 59) return ""
  mdays = 31
  if (mn == 4 || mn == 6 || mn == 9 || mn == 11) mdays = 30
  if (mn == 2) {
    leap = (yn % 4 == 0 && (yn % 100 != 0 || yn % 400 == 0))
    mdays = leap ? 29 : 28
  }
  if (dn < 1 || dn > mdays) return ""
  return y mo day "T" hh mi ss
}
function active_state(s) {
  return s == "launching" || s == "running" || s == "awaiting-approval" || s == "outcome-unknown"
}
function needs_deps_verified(s) { return active_state(s) || s == "completed" || s == "verified" }
function releases(s) { return s == "blocked" || s == "failed" || s == "partial" || s == "interrupted" || s == "cancelled" }
BEGIN {
  NREQ = split("task_id agent_name title kind pane_id worktree directory dependencias scope_escritura criterion output_path evidence_refs estado runtime_status execution_outcome created_at last_state_at notas", REQ, " ")
  for (r = 1; r <= NREQ; r++) TASK_KEYS[REQ[r]] = 1
  NRUN = split("run_id herdr.server_version workspace.directory workspace.herdr_workspace_id workspace.herdr_tab_id orchestrator.pane_id orchestrator.kind", RK, " ")
  for (r = 1; r <= NRUN; r++) RUN_KEYS[RK[r]] = 1
  ws = normpath(ENVIRON["WS_PHYS"])
}
{
  if (FNR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)   # strip UTF-8 BOM
  original = $0
  sub(/\r$/, "", original)
  if (index(original, "\t")) { fail("tabs not allowed, line " FNR); next }
  line = strip_comment(original)
  if (trim(line) == "") next
  indent = 0
  while (substr(line, indent + 1, 1) == " ") indent++
  content = substr(line, indent + 1)
  sub(/[ \t]+$/, "", content)

  if (indent == 0) {
    if (content == "run:") {
      if (seen_root["run"]++) fail("duplicate run block")
      section = "run"; sub_sec = ""; next
    }
    if (content == "tasks:" || content == "tasks: []") {
      if (seen_root["tasks"]++) fail("duplicate tasks block")
      section = "tasks"; tasks_empty = (content == "tasks: []"); next
    }
    if (!split_key(content)) { fail("invalid root structure, line " FNR); next }
    if (KEY != "schema_version") { fail("unknown root key: " KEY); next }
    if (seen_root["schema_version"]++) { fail("duplicate schema_version"); next }
    if (RAW != "4") fail("schema_version must be the integer 4 (herdr-orchestrator ledger)")
    next
  }
  if (section == "run" && indent == 2) {
    if (content == "herdr:" || content == "workspace:" || content == "orchestrator:") {
      sub_sec = substr(content, 1, length(content) - 1)
      if (seen_sub[sub_sec]++) fail("duplicate run." sub_sec " block")
      next
    }
    if (!split_key(content)) { fail("invalid key or indentation inside run, line " FNR); next }
    sub_sec = ""
    set_run(KEY, RAW)
    next
  }
  if (section == "run" && indent == 4) {
    if (sub_sec == "" || !split_key(content)) { fail("field outside a run block, line " FNR); next }
    set_run(sub_sec "." KEY, RAW)
    next
  }
  if (section == "tasks" && indent == 2) {
    if (tasks_empty) { fail("tasks: [] does not accept elements, line " FNR); next }
    if (substr(content, 1, 2) != "- " || !split_key(substr(content, 3)) || KEY != "task_id") {
      fail("each task must be a list element starting with task_id, line " FNR); next
    }
    task_n++
    set_task(task_n, KEY, RAW)
    next
  }
  if (section == "tasks" && indent == 4 && task_n > 0) {
    if (!split_key(content)) { fail("invalid task field, line " FNR); next }
    set_task(task_n, KEY, RAW)
    next
  }
  fail("indentation or placement outside the YAML subset at line " FNR)
}
END {
  if (!("schema_version" in seen_root)) fail("missing schema_version")
  if (!("run" in seen_root)) fail("missing run block")
  if (!("tasks" in seen_root)) fail("missing tasks block")
  for (r = 1; r <= NRUN; r++) if (!(RK[r] in seen_run)) fail("missing run." RK[r])
  run_id = run_value["run_id"]
  if (("run_id" in run_value) && run_id !~ /^[a-z0-9][a-z0-9._-]*$/)
    fail("run.run_id outside grammar [a-z0-9][a-z0-9._-]*: " run_id)
  WS = normpath(run_value["workspace.directory"])
  if (substr(WS, 1, 1) != "/") fail("run.workspace.directory must be an absolute path")
  else if (WS != ws) fail("run.workspace.directory does not match the physical current directory (pwd -P); run the validator from the workspace root")
  RUN_DIR = WS "/.herdr-orch/" run_id
  for (i = 1; i <= task_n; i++) for (r = 1; r <= NREQ; r++)
    if (!((i, REQ[r]) in seen_task)) fail("task " i " missing required field " REQ[r])
  if (task_n == 0 && !tasks_empty) fail("tasks must be [] or contain list elements")
  if (failures > 0) { printf "TOTAL: %d passed, %d failed\n", passed, failures; exit 1 }
  if (task_n == 0) {
    ok("canonical form and run metadata valid; empty tasks")
    printf "TOTAL: %d passed, %d failed\n", passed, failures
    exit 0
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    if (id !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) fail("empty task_id or outside grammar in task " i ": " id)
    else if (id in id_index) fail("duplicate task_id: " id)
    else id_index[id] = i
    agent = task_value[i, "agent_name"]
    if (agent !~ /^[a-z][a-z0-9_-]*$/ || length(agent) > 32)
      fail(id " agent_name outside grammar [a-z][a-z0-9_-]{0,31}: " agent)
    if (task_value[i, "title"] == "") fail(id " requires a non-empty title")
    if (task_value[i, "kind"] !~ /^[a-z][a-z0-9_-]*$/) fail(id " has an invalid kind: " task_value[i, "kind"])
    if (task_value[i, "criterion"] == "") fail(id " requires a non-empty criterion")

    state = task_value[i, "estado"]
    if (state !~ /^(pending|launching|running|awaiting-approval|outcome-unknown|completed|verified|blocked|failed|partial|interrupted|cancelled)$/)
      fail(id " has invalid estado: " state)
    outcome = task_value[i, "execution_outcome"]
    if (outcome !~ /^(unknown|succeeded|failed|interrupted|cancelled)$/)
      fail(id " has invalid execution_outcome: " outcome)
    if (active_state(state) && outcome != "unknown")
      fail(id " in an in-flight estado must have execution_outcome unknown")
    if ((state == "completed" || state == "verified") && outcome != "succeeded")
      fail(id " " state " requires execution_outcome succeeded")
    if (state ~ /^(blocked|failed|partial|interrupted|cancelled)$/ && trim(task_value[i, "notas"]) == "")
      fail(id " in estado " state " requires non-empty notas with the reason")
    rt = task_value[i, "runtime_status"]
    if (!task_null[i, "runtime_status"] && rt !~ /^(idle|working|blocked|done|unknown)$/)
      fail(id " has invalid runtime_status: " rt)
    if ((state == "running" || state == "completed" || state == "verified") && task_null[i, "runtime_status"])
      fail(id " in estado " state " requires an observed runtime_status")
    if (state != "pending" && task_null[i, "pane_id"]) fail(id " in estado " state " requires pane_id")
    if (!task_null[i, "pane_id"] && task_value[i, "pane_id"] == "") fail(id " has empty pane_id; use null")
    if (active_state(state) && active_agent[agent]++) fail(agent " has more than one active task (" id ")")

    dir = task_value[i, "directory"]
    if (substr(dir, 1, 1) != "/") { fail(id " directory must be an absolute path"); TDIR[i] = "" }
    else TDIR[i] = normpath(dir)
    if (task_null[i, "worktree"]) {
      if (TDIR[i] != WS) fail(id " directory must equal run.workspace.directory when worktree is null")
    } else {
      wt = task_value[i, "worktree"]
      if (substr(wt, 1, 1) != "/") fail(id " worktree must be null or an absolute path")
      else if (normpath(wt) != TDIR[i]) fail(id " directory must equal worktree")
      else if (normpath(wt) == WS) fail(id " worktree cannot be the workspace directory")
    }

    cr = norm_time(task_value[i, "created_at"]); ls = norm_time(task_value[i, "last_state_at"])
    if (cr == "" || ls == "") fail(id " has an invalid timestamp; requires UTC YYYY-MM-DDTHH:MM:SSZ")
    else if (ls < cr) fail(id " has last_state_at earlier than created_at")

    for (k = 1; k <= task_count[i, "dependencias"]; k++) {
      d = task_list[i, "dependencias", k]
      if (d !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) fail(id " has a dependency with invalid ID: " d)
      if (dep_seen[i, d]++) fail(id " repeats dependency " d)
      dependency[i, ++deps[i]] = d
    }
    TRUN[i] = RUN_DIR "/" id
    has_run_scope = 0
    for (k = 1; k <= task_count[i, "scope_escritura"]; k++) {
      c = canon(i, task_list[i, "scope_escritura", k])
      if (c == "!OUTSIDE!") fail(id " scope_escritura escapes the workspace and the task directory: " task_list[i, "scope_escritura", k])
      else { scope[i, ++scopes[i]] = c; if (c == TRUN[i]) has_run_scope = 1 }
    }
    if (!has_run_scope) fail(id " scope_escritura must include its run directory " TRUN[i])
    outp = task_value[i, "output_path"]
    if (substr(outp, 1, 1) != "/" || normpath(outp) == TRUN[i] || !covers(TRUN[i], normpath(outp)))
      fail(id " output_path must be an absolute file path under " TRUN[i])
    if (task_count[i, "evidence_refs"] == 0) fail(id " requires at least one evidence_refs entry")
    for (k = 1; k <= task_count[i, "evidence_refs"]; k++) {
      e = task_list[i, "evidence_refs", k]
      if (evidence_seen[i, e]++) fail(id " repeats evidence_ref " e)
      if (substr(e, 1, 1) != "/" || normpath(e) == TRUN[i] || !covers(TRUN[i], normpath(e)))
        fail(id " evidence_refs entries must be absolute file paths under " TRUN[i] ": " e)
    }
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    for (k = 1; k <= deps[i]; k++) {
      d = dependency[i, k]
      if (!(d in id_index)) { fail(id " depends on nonexistent task_id: " d); continue }
      j = id_index[d]
      indeg[i]++
      successor[j] = successor[j] " " i
      adjacency[i, j] = 1
      if (needs_deps_verified(task_value[i, "estado"]) && task_value[j, "estado"] != "verified")
        fail(id " cannot be launched until dependency " d " is verified")
    }
  }
  tail = 0
  for (i = 1; i <= task_n; i++) if (indeg[i] == 0) queue[++tail] = i
  head = 1; done = 0
  while (head <= tail) {
    u = queue[head++]; done++
    m = split(successor[u], next_nodes, " ")
    for (k = 1; k <= m; k++) if (--indeg[next_nodes[k]] == 0) queue[++tail] = next_nodes[k]
  }
  if (done < task_n) fail("cycle detected in dependencias")
  else ok("all dependencias exist and the DAG is acyclic")

  for (k = 1; k <= task_n; k++) for (i = 1; i <= task_n; i++)
    if (adjacency[i, k]) for (j = 1; j <= task_n; j++) if (adjacency[k, j]) adjacency[i, j] = 1
  scope_bad = 0
  for (i = 1; i <= task_n; i++) for (j = i + 1; j <= task_n; j++) {
    # Terminal non-verified tasks release their scope (spec §5 check 5, Degraded D).
    if (releases(task_value[i, "estado"]) || releases(task_value[j, "estado"])) continue
    if (adjacency[i, j] || adjacency[j, i]) continue
    found = 0
    for (p = 1; p <= scopes[i]; p++) for (q = 1; q <= scopes[j]; q++)
      if (touches(scope[i, p], scope[j, q])) found = 1
    if (found) {
      fail(task_value[i, "task_id"] " and " task_value[j, "task_id"] " share scope without a dependency")
      scope_bad = 1
    }
  }
  if (!scope_bad) ok("scopes do not overlap between tasks without a dependency")
  if (failures == 0) ok("canonical schema, IDs, states, paths and dates valid")
  printf "TOTAL: %d passed, %d failed\n", passed, failures
  exit (failures > 0 ? 1 : 0)
}
' < "$LEDGER"
