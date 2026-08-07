#!/usr/bin/env bash
# Tests for scripts/summary_body.sh.
#
# Almost all of the display logic moved into the engine with the summary itself (ADR-0006, amended),
# where the gate decision lives and where it benefits every CI rather than this one. What is left
# here is the part the engine cannot cover: what this Action does when the engine produced no summary
# at all.
#
# That is the whole reason this file exists. A scan that dies before writing its summary is the case
# where a wrapper is most tempted to do nothing — and doing nothing leaves a blank run page, which
# reads as "nothing to report" when in fact nothing was checked.
#
# Run: bash tests/test_summary_body.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/summary_body.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # check <name> <condition-description> <0|1 result>
  if [ "$3" -eq 0 ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %s — %s\n' "$1" "$2"; fail=$((fail+1)); fi
}

# ---------------------------------------------------------------------------------------------
printf '\nengine produced a summary\n'

cat > "$TMP/summary.md" <<'EOF'
## depproof — ❌ Failed

Gate rule(s) **severity>=critical** matched.
EOF

out="$(bash "$SCRIPT" "$TMP/summary.md" 1)"
grep -q "❌ Failed" <<<"$out"; check "passes the engine's summary through unchanged" "verdict missing" $?
grep -q "severity>=critical" <<<"$out"; check "keeps the rule that fired" "rule missing" $?
grep -q "No summary produced" <<<"$out" && r=1 || r=0
check "does not add a fallback when one is not needed" "fallback leaked in" $r

# ---------------------------------------------------------------------------------------------
printf '\nengine produced NO summary — the case this script exists for\n'

out="$(bash "$SCRIPT" "$TMP/missing.md" 2)"
[ -n "$out" ]; check "says something rather than leaving the page blank" "empty output reads as nothing-to-report" $?
grep -q "No summary produced" <<<"$out"; check "names the situation" "no explanation" $?
grep -q "not a clean result" <<<"$out"; check "states that this is NOT clean" "absence could read as safe" $?
grep -qi "passed\|✅" <<<"$out" && r=1 || r=0
check "never reads as a pass" "a failed scan must not look green" $r
grep -q "exited 2" <<<"$out"; check "reports the exit code so the log can be matched up" "exit code missing" $?

# An empty file is the same failure as a missing one: the engine got far enough to create it but not
# to write a verdict. Treating it as valid would print an empty summary, which reads as clean.
: > "$TMP/empty.md"
out="$(bash "$SCRIPT" "$TMP/empty.md" 2)"
grep -q "No summary produced" <<<"$out"; check "treats an empty file as no summary" "empty file rendered as clean" $?

# ---------------------------------------------------------------------------------------------
printf '\nPR comment extras\n'

out="$(bash "$SCRIPT" "$TMP/summary.md" 1 '<!-- depproof-action -->' 'https://example.com/run/1')"
[ "$(head -1 <<<"$out")" = "<!-- depproof-action -->" ]
check "marker is the FIRST line so the comment can find itself next run" "marker misplaced — comments would accumulate" $?
grep -q "https://example.com/run/1" <<<"$out"; check "links back to the run" "run url missing" $?

out="$(bash "$SCRIPT" "$TMP/summary.md" 1)"
grep -q "depproof-action -->" <<<"$out" && r=1 || r=0
check "job summary carries no marker" "marker leaked into the run page" $r

# The comment must still be posted when the scan died — that is when a reviewer most needs to know.
out="$(bash "$SCRIPT" "$TMP/missing.md" 2 '<!-- depproof-action -->')"
grep -q "No summary produced" <<<"$out"; check "fallback still applies to the PR comment" "reviewer told nothing" $?

# ---------------------------------------------------------------------------------------------
printf '\nexit status\n'

bash "$SCRIPT" "$TMP/missing.md" 2 >/dev/null 2>&1
check "returns 0 even with no summary" "a display problem must never change the build verdict" $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
