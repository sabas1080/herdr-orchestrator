#!/bin/sh
# Check one evidence file of the herdr-orchestrator evidence format:
#   criterion: "<exactly the task criterion>"
#   result: "pass"
#   observed: "<non-empty>"
# Only these three keys are allowed, each once, as double-quoted scalars.
# observed may instead be a literal block scalar (`observed: |` or `|-`)
# followed by indented lines; blank lines inside the block are ignored.
# Usage: check_evidence.sh EVIDENCE_FILE CRITERION
# Exit: 0 pass, 1 fail (one "[FAIL] reason" line on stdout), 2 usage/environment.
set -u
LC_ALL=C
export LC_ALL
command -v awk >/dev/null 2>&1 || { printf 'ERROR: awk not available\n' >&2; exit 2; }
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -r "$SCRIPT_DIR/_validators.awk" ] || { printf 'ERROR: missing %s\n' "$SCRIPT_DIR/_validators.awk" >&2; exit 2; }
[ "$#" -eq 2 ] || { printf 'Usage: %s EVIDENCE_FILE CRITERION\n' "$0" >&2; exit 2; }
[ -f "$1" ] && [ -r "$1" ] || { printf '[FAIL] evidence file missing or unreadable: %s\n' "$1"; exit 1; }
_VAL_LIB=$(cat "$SCRIPT_DIR/_validators.awk")
CRITERION=$2 awk "$_VAL_LIB
"'
function bad(msg) { if (!reason) reason = msg }
{
  if (FNR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)
  line = $0; sub(/\r$/, "", line)
  if (index(line, "\t")) { bad("tabs not allowed"); next }
  if (inblock) {
    # indented or blank lines belong to the block; anything else ends it
    if (trim(line) == "") next
    if (line ~ /^ /) { value["observed"] = value["observed"] (value["observed"] == "" ? "" : " ") trim(line); next }
    inblock = 0
  }
  line = strip_comment(line)
  if (trim(line) == "") next
  if (line !~ /^[A-Za-z_][A-Za-z0-9_]*:/) { bad("line outside the evidence format: " line); next }
  key = line; sub(/:.*/, "", key)
  raw = line; sub(/^[A-Za-z_][A-Za-z0-9_]*:[ \t]*/, "", raw)
  if (key != "criterion" && key != "result" && key != "observed") { bad("unknown evidence key: " key); next }
  if (seen[key]++) { bad("duplicate evidence key: " key); next }
  if (key == "observed" && (trim(raw) == "|" || trim(raw) == "|-")) { inblock = 1; value[key] = ""; next }
  if (!parse_scalar(raw, 0)) { bad("evidence " key " must be a double-quoted string"); next }
  value[key] = PVAL
}
END {
  if (!seen["criterion"] || !seen["result"] || !seen["observed"]) bad("evidence requires criterion, result and observed")
  else if (value["criterion"] != ENVIRON["CRITERION"]) bad("evidence criterion differs from the task criterion")
  else if (value["result"] != "pass") bad("evidence result is \"" value["result"] "\", not \"pass\"")
  else if (trim(value["observed"]) == "") bad("evidence observed is empty")
  if (reason) { printf "[FAIL] %s\n", reason; exit 1 }
  exit 0
}' "$1"
