#!/usr/bin/env bash
# Invariants about the action's own shape. Each of these has been violated in a released version.
#
# 1. NO run: BLOCK MAY EXCEED GITHUB'S EXPRESSION LIMIT.
#    GitHub compiles a run: block containing ${{ }} as ONE template expression, capped at 21,000
#    characters. Exceeding it makes the action fail to compile for every consumer with "The template
#    is not valid" -- before a single line runs. A passing unit test suite does not catch this,
#    because the failure is in the action definition rather than in anything it executes.
#
# 2. EVERY INPUT_* scan.sh READS MUST BE EXPORTED BY action.yml.
#    scan.sh is a script, not a template: it cannot see the `inputs` context. An input referenced
#    there and not exported here reads as EMPTY, silently -- so a flag goes missing and the scan
#    still reports success.
#
# 3. NO ${{ }} IN scan.sh's EXECUTABLE CODE.
#    They never expand in a script. Same silent-empty failure as (2).
#
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0
say() { printf '  %-6s %s\n' "$1" "$2"; }

# --- 1. expression length -------------------------------------------------------------------
LIMIT=21000
over=$(python3 - <<'PY'
import re, sys
lines = open('action.yml').read().split('\n')
bad = []
for i, l in enumerate(lines):
    if not l.strip().startswith('run:'): continue
    if l.strip() != 'run: |':
        if len(l) > 21000: bad.append((i+1, len(l)))
        continue
    ind = len(l) - len(l.lstrip()); body, j = [], i+1
    while j < len(lines) and (lines[j].strip()=='' or len(lines[j])-len(lines[j].lstrip()) > ind):
        body.append(lines[j]); j += 1
    blob = '\n'.join(body)
    if '${{' in blob and len(blob) > 21000: bad.append((i+1, len(blob)))
for ln, n in bad: print("%d %d" % (ln, n))
PY
)
if [ -n "$over" ]; then
  while read -r ln n; do say FAIL "run: block at line $ln is $n chars, over the 21,000 expression limit"; done <<< "$over"
  say ""     "move the body into a script file; a script is not a template and has no limit"
  fail=1
else
  say ok "no run: block exceeds the 21,000-character expression limit"
fi

# --- 2. the scan.sh <-> action.yml env contract ---------------------------------------------
if [ -f scan.sh ]; then
  miss=$(python3 - <<'PY'
import re
sh, yml = open('scan.sh').read(), open('action.yml').read()
used = set(re.findall(r'\$\{?(INPUT_[A-Z0-9_]+)', sh)) | set(re.findall(r'\$\{?(ACTION_PATH)\b', sh))
exported = set(re.findall(r'^\s+(INPUT_[A-Z0-9_]+|ACTION_PATH):', yml, re.M))
print('\n'.join(sorted(used - exported)))
PY
)
  if [ -n "$miss" ]; then
    while read -r v; do [ -n "$v" ] && say FAIL "scan.sh reads \$$v but action.yml never exports it (reads as EMPTY)"; done <<< "$miss"
    fail=1
  else
    say ok "every INPUT_* read by scan.sh is exported by action.yml"
  fi
  # and the inverse: no ${{ }} may creep back into the script
  # Comments are excluded deliberately: the header explains the rule and would match itself.
  if grep -v '^[[:space:]]*#' scan.sh | grep -q '\${{'; then
    say FAIL "scan.sh has \${{ }} in executable code -- it is a script, not a template"
    grep -vn '^[[:space:]]*#' scan.sh | grep '\${{' | head -5 | sed 's/^/         /'
    fail=1
  else
    say ok "scan.sh has no template expressions in executable code"
  fi
fi

exit $fail
