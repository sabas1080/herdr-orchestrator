#!/bin/sh
# Structural checks for the SKILL/ package: frontmatter, size, links, no OpenCode leftovers.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
S=$ROOT/SKILL
FAILS=0
LINKS_OUT=$(mktemp "${TMPDIR:-/tmp}/check_links.XXXXXX") || exit 2
trap 'rm -f "$LINKS_OUT"' EXIT
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
ok() { printf 'ok   %s\n' "$1"; }
head -n 1 "$S/SKILL.md" | grep -qx -- '---' && ok frontmatter-start || fail frontmatter-start
grep -q '^name: herdr-orchestrator$' "$S/SKILL.md" && ok name || fail name
desc=$(sed -n 's/^description: //p' "$S/SKILL.md")
[ -n "$desc" ] && [ "${#desc}" -le 1024 ] && ok "description (${#desc} chars)" || fail description
words=$(wc -w < "$S/SKILL.md" | tr -d ' ')
[ "$words" -le 5000 ] && ok "SKILL.md words ($words)" || fail "SKILL.md too long ($words words)"
# Every relative markdown link in SKILL/ resolves to a file.
for f in "$S/SKILL.md" "$S"/references/*.md "$S"/scripts/prompt-templates/*.md; do
  d=$(dirname "$f")
  grep -o '](\([^)#]*\)[^)]*)' "$f" | sed -e 's/^](//' -e 's/[#)].*$//' | while IFS= read -r l; do
    case "$l" in ''|http*|mailto:*) continue ;; esac
    [ -e "$d/$l" ] || printf 'FAIL broken link in %s: %s\n' "${f#$ROOT/}" "$l"
  done
done > "$LINKS_OUT"
if [ -s "$LINKS_OUT" ]; then cat "$LINKS_OUT"; FAILS=$((FAILS + 1)); else ok links; fi
# No OpenCode plumbing left in the package.
if grep -rIl -E 'orchestrate\.sh|/openapi\.json|tabs\.json|parentID|sessionID|service\.json' "$S" >/dev/null; then
  grep -rIn -E 'orchestrate\.sh|/openapi\.json|tabs\.json|parentID|sessionID|service\.json' "$S" | head -20
  fail opencode-leftovers
else ok no-opencode-leftovers; fi
for f in orch.sh validate_dag.sh validate_ledger_closed.sh check_evidence.sh _validators.awk dragon_name.sh \
         lib/orch_common.sh lib/orch_ledger.sh lib/orch_herdr.sh prompt-templates/task-header.md \
         prompt-templates/router-orchestrator.md; do
  [ -f "$S/scripts/$f" ] || fail "missing scripts/$f"
done
printf '\n%d failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
