#!/usr/bin/env bash
# Tests for scripts/coverage_annotation.sh.
#
# Same division of labour as test_summary_body.sh: the engine decides what a coverage gap IS and
# what to do about it, and these tests do not re-litigate that. What is tested here is the part
# only this Action can get wrong — whether the decision reaches the run page, whether a manifest
# the engine already excused stays quiet, and whether a display problem can take a build down.
#
# The quiet cases matter as much as the loud one. An annotation that fires on every Node repo with
# a lockfile is muted within a week, and then it is not there on the day a bare build.gradle ships
# an unresolved graph.
#
# Run: bash tests/test_coverage_annotation.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/coverage_annotation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # check <name> <condition-description> <0|1 result>
  if [ "$3" -eq 0 ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %s — %s\n' "$1" "$2"; fail=$((fail+1)); fi
}

summary() { # summary <file> <manifests-json>
  printf '{"schemaVersion":1,"depproofVersion":"0.1.21","manifests":%s}\n' "$2" > "$TMP/$1"
}

DECLARED='{"path":"build.gradle","ecosystem":"Gradle","fidelity":"DECLARED_ONLY","fidelityReported":true,
  "superseded":false,"fidelityRemediation":"commit a gradle.lockfile"}'
RESOLVED='{"path":"pom.xml","ecosystem":"Maven","fidelity":"RESOLVED","fidelityReported":true,"superseded":false}'
SUPERSEDED='{"path":"package.json","ecosystem":"npm","fidelity":"DECLARED_ONLY","fidelityReported":true,
  "superseded":true,"fidelityRemediation":"commit and scan the lockfile"}'
LOCKFILE='{"path":"package-lock.json","ecosystem":"npm","fidelity":"RESOLVED","fidelityReported":true,"superseded":false}'

# ---------------------------------------------------------------------------------------------
printf '\na real gap reaches the run page\n'

summary gap.json "[$DECLARED,$RESOLVED]"
out="$(bash "$SCRIPT" "$TMP/gap.json")"
grep -q '^::warning ' <<<"$out"; check "emits a workflow-command warning" "not an annotation — nothing appears on the run page" $?
grep -q '1 of 2 manifest' <<<"$out"; check "counts the gaps against the whole scan" "a bare count says nothing about proportion" $?
grep -q 'build.gradle' <<<"$out"; check "names the manifest" "a warning you cannot locate is not actionable" $?
grep -q 'DECLARED_ONLY' <<<"$out"; check "states the level" "level is the difference between missing and unknown" $?
grep -q 'commit a gradle.lockfile' <<<"$out"; check "carries the engine's remedy" "the remedy is the point, not the complaint" $?
[ "$(wc -l <<<"$out")" -eq 1 ]; check "one line" "GitHub truncates a multi-line annotation at the first newline" $?

# ---------------------------------------------------------------------------------------------
printf '\nsilence when nothing is wrong\n'

summary clean.json "[$RESOLVED]"
out="$(bash "$SCRIPT" "$TMP/clean.json")"
[ -z "$out" ]; check "a fully resolved scan says nothing" "noise on the common case is how this gets muted" $?

summary lock.json "[$SUPERSEDED,$LOCKFILE]"
out="$(bash "$SCRIPT" "$TMP/lock.json")"
[ -z "$out" ]; check "a manifest beside its own lockfile is not a gap" "every Node repo on earth would be warned" $?

# An engine that predates the fidelity fields defaults them to RESOLVED, and `fidelityReported`
# is the only thing separating "looked and found everything" from "never looked". Neither a
# warning nor a clean bill of health is honest about a scan that made no claim.
summary old.json '[{"path":"pom.xml","ecosystem":"Maven"}]'
out="$(bash "$SCRIPT" "$TMP/old.json")"
[ -z "$out" ]; check "says nothing about a scan that never reported fidelity" "inventing a claim the engine did not make" $?

# This Action rolls on @v1 while the engine ships as an image, so a new Action WILL meet an older
# engine. One that reports fidelity but not supersession cannot be filtered honestly — annotating
# anyway would name every package.json beside its own lockfile.
summary nosup.json '[{"path":"package.json","ecosystem":"npm","fidelity":"DECLARED_ONLY","fidelityReported":true,
  "fidelityRemediation":"commit and scan the lockfile"},
  {"path":"package-lock.json","ecosystem":"npm","fidelity":"RESOLVED","fidelityReported":true}]'
out="$(bash "$SCRIPT" "$TMP/nosup.json")"
[ -z "$out" ]; check "stays quiet when the engine never stated supersession" "would cry wolf on every lockfile'd repo" $?

# ---------------------------------------------------------------------------------------------
printf '\ngrouping and caps\n'

many="$(python3 -c '
import json
print(json.dumps([{"path": f"mod{i}/build.gradle.kts", "ecosystem": "Gradle", "fidelity": "DECLARED_ONLY",
                   "fidelityReported": True, "superseded": False,
                   "fidelityRemediation": "dump each module"} for i in range(1, 37)]))')"
summary many.json "$many"
out="$(bash "$SCRIPT" "$TMP/many.json")"
grep -q '36 x DECLARED_ONLY' <<<"$out"; check "groups identical levels into a count" "36 paths in one line is unreadable" $?
grep -q '(+31 more)' <<<"$out"; check "caps the path list at five" "the cap must actually cap" $?

# Two different remedies cannot both be a one-line instruction. Naming one of them would tell half
# the repo to do something that does not apply to it.
summary mixed.json "[$DECLARED,{\"path\":\"pyproject.toml\",\"ecosystem\":\"Python\",\"fidelity\":\"DECLARED_ONLY\",
  \"fidelityReported\":true,\"superseded\":false,\"fidelityRemediation\":\"commit a lockfile\"}]"
out="$(bash "$SCRIPT" "$TMP/mixed.json")"
grep -q 'See the job summary' <<<"$out"; check "defers when the gaps need different fixes" "one remedy stated for two problems" $?
grep -q 'commit a gradle.lockfile' <<<"$out" && r=1 || r=0
check "does not pick one remedy arbitrarily" "half the repo told to do the wrong thing" $r

# ---------------------------------------------------------------------------------------------
printf '\nthe flag suggestion\n'

summary gap2.json "[$DECLARED]"
out="$(bash "$SCRIPT" "$TMP/gap2.json")"
grep -q 'Set require-fidelity' <<<"$out"; check "offers the gate to someone who has not set it" "the control stays discoverable only via --help" $?

out="$(bash "$SCRIPT" "$TMP/gap2.json" resolved)"
grep -q 'Set require-fidelity' <<<"$out" && r=1 || r=0
check "does not suggest a flag already set" "noise on a screen that already carries the verdict" $r
grep -q 'not read as a resolved graph' <<<"$out"; check "still states the gap when the flag is set" "the gap is a fact, not a consequence of the flag" $?

# 'off' is the action's own way of spelling unset, and must read as unset.
out="$(bash "$SCRIPT" "$TMP/gap2.json" off)"
grep -q 'Set require-fidelity' <<<"$out"; check "'off' counts as not set" "the input's own default would silence the advice" $?

# ---------------------------------------------------------------------------------------------
printf '\nnever changes the verdict\n'

bash "$SCRIPT" "$TMP/missing.json" >/dev/null 2>&1
check "exits 0 when there is no summary at all" "a dead scan would be reported as an annotation failure" $?

printf 'not json at all' > "$TMP/broken.json"
out="$(bash "$SCRIPT" "$TMP/broken.json" 2>/dev/null)"; r=$?
[ "$r" -eq 0 ] && [ -z "$out" ]; check "exits 0 and stays quiet on unreadable JSON" "a parse error must not become a build failure" $?

: > "$TMP/empty.json"
bash "$SCRIPT" "$TMP/empty.json" >/dev/null 2>&1
check "exits 0 on an empty summary" "an empty file is not an error worth failing over" $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
