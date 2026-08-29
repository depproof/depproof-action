#!/usr/bin/env bash
# Tests that an Action input actually reaches the engine's command line.
#
# CI already parses `action.yml` and runs `bash -n` over scan.sh, which
# catches a broken heredoc or a typo. It cannot catch the failure that matters more: an input wired
# to nothing. `ignore-scope: development` that never becomes `--ignore-scope development` produces a
# build that fails when the user expected it to pass, with no error anywhere to explain why — the
# YAML is valid, the shell is valid, and the flag simply is not there.
#
# HOW IT WORKS. The composite step's body is extracted from action.yml and every `${{ inputs.x }}`
# is rewritten to `${IN_X:-}`, so the test drives real inputs from the environment instead of
# stubbing them to a constant. `docker` is replaced on PATH by a script that records its arguments
# and exits 0, so what is asserted is exactly what would have been handed to the engine. `curl` is
# stubbed to fail, which is the state of a runner with no hub — the paths that need one must not be
# required to reach the scan.
#
# WHY IT MAY RUN IN A CONTAINER. GitHub runners use bash 5, where expanding an empty array under
# `set -u` is legal; macOS ships bash 3.2, where it is an error and `"${DOCKER_ENV[@]}"` aborts the
# step for a reason no consumer will ever meet. Rather than weaken the action for a shell it does
# not run on, the harness uses the host bash when it is new enough and falls back to `bash:5` in
# Docker when it is not. CI takes the first path, a macOS laptop the second, and both test the same
# script under the same interpreter the Action really gets.
#
# Run: bash tests/test_action_args.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$(mktemp -d)"
trap 'rm -rf "$H"' EXIT

pass=0; fail=0
check() { # check <name> <why-it-matters> <0|1 result>
  if [ "$3" -eq 0 ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %s — %s\n' "$1" "$2"; fail=$((fail+1)); fi
}

python3 -c "import yaml" 2>/dev/null || pip install --quiet pyyaml

python3 - "$ROOT/action.yml" "$H/step.sh" "$H/env.sh" <<'PY'
import os, re, sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))
step = spec["runs"]["steps"][0]

def sub(m):
    expr = m.group(1).strip()
    if expr.startswith("inputs."):
        return "${IN_" + expr[len("inputs."):].strip().replace("-", "_").upper() + ":-}"
    return ""

# The body lives in scan.sh, not inline -- see that file's header. The step's own `run:` is a
# one-line invocation, so read the script instead, and refuse to run if action.yml stops invoking
# it: silently testing one line while believing it tested four hundred is worse than failing.
run = step["run"]
if "scan.sh" not in run:
    sys.exit("action.yml no longer invokes scan.sh -- this test extracts the wrong thing")
import os
body = open(os.path.join(os.path.dirname(sys.argv[1]), "scan.sh")).read()
open(sys.argv[2], "w").write(re.sub(r"\$\{\{([^}]*)\}\}", sub, body))
with open(sys.argv[3], "w") as f:
    for k, v in (step.get("env") or {}).items():
        m = re.match(r"\$\{\{\s*inputs\.([\w-]+)\s*\}\}", v) if isinstance(v, str) else None
        if m:
            f.write('export %s="${IN_%s:-}"\n' % (k, m.group(1).replace("-", "_").upper()))
    # scan.sh reads ACTION_PATH; without it every helper path resolves to /scan.sh
    f.write('export ACTION_PATH="%s"\n' % os.path.dirname(os.path.abspath(sys.argv[1])))
PY

mkdir -p "$H/bin" "$H/ws"
touch "$H/ws/package.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$DOCKER_ARGS_FILE"\nexit 0\n' > "$H/bin/docker"
printf '#!/usr/bin/env bash\nexit 7\n' > "$H/bin/curl"
chmod +x "$H/bin/docker" "$H/bin/curl"

# bash 4.4+ expands an empty array under `set -u` without erroring; older shells cannot run the step.
host_ok=0
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
  host_ok=1
fi
if [ "$host_ok" -eq 0 ] && ! command -v docker >/dev/null 2>&1; then
  echo "  SKIP — needs bash >= 4.4 or docker (host bash is ${BASH_VERSION})"
  exit 0
fi
[ "$host_ok" -eq 1 ] && echo "  (running under host bash ${BASH_VERSION})" || echo "  (host bash ${BASH_VERSION} is too old; running the step in bash:5 via docker)"

run() { # run <IN_VAR=value>... ; leaves the engine's argv in $H/docker.args
  : > "$H/docker.args"; : > "$H/summary.md"; : > "$H/out.txt"; : > "$H/env.txt"
  if [ "$host_ok" -eq 1 ]; then
    ( export DOCKER_ARGS_FILE="$H/docker.args" GITHUB_WORKSPACE="$H/ws" \
             GITHUB_STEP_SUMMARY="$H/summary.md" GITHUB_OUTPUT="$H/out.txt" GITHUB_ENV="$H/env.txt" \
             PATH="$H/bin:$PATH"
      for kv in "$@"; do export "${kv?}"; done
      # shellcheck disable=SC1090
      . "$H/env.sh"; bash "$H/step.sh" ) > "$H/run.log" 2>&1
  else
    local envs=(); for kv in "$@"; do envs+=(-e "$kv"); done
    docker run --rm -v "$H:/h" \
      -e DOCKER_ARGS_FILE=/h/docker.args -e GITHUB_WORKSPACE=/h/ws \
      -e GITHUB_STEP_SUMMARY=/h/summary.md -e GITHUB_OUTPUT=/h/out.txt -e GITHUB_ENV=/h/env.txt \
      "${envs[@]}" bash:5 \
      bash -c 'export PATH=/h/bin:$PATH; . /h/env.sh; bash /h/step.sh' > "$H/run.log" 2>&1
  fi
}

argv() { tr ' ' '\n' < "$H/docker.args"; }
BASE=(IN_FAIL_ON=critical IN_DISCOVER=true IN_HTML=false IN_JOB_SUMMARY=false)

echo "action args"

run "${BASE[@]}" IN_IGNORE_SCOPE=development
argv | grep -qx -- "--ignore-scope" && argv | grep -qx -- "development"
check "ignore-scope reaches the engine" "the input is wired to nothing; the gate is never narrowed" $?

run "${BASE[@]}"
argv | grep -qx -- "--ignore-scope"
[ $? -ne 0 ]
check "an unset ignore-scope passes no flag" \
      "an empty value would become --ignore-scope '' and the engine rejects that as a usage error" $?

run "${BASE[@]}" IN_IGNORE_SCOPE="development,optional"
argv | grep -qx -- "development,optional"
check "a comma-separated value survives as one argument" \
      "split across two argv entries the engine sees a stray positional and fails" $?

# `internal` — the failure here is the quietest of any input in this file. Wired to nothing, the
# scan screens the caller's private libraries against a public registry, matches nothing, and reports
# them CLEAN, which is indistinguishable from a genuinely clean result. No error, no warning, and a
# security team believing a question was asked that never was.
run "${BASE[@]}" IN_INTERNAL='com.acme.internal:*'
argv | grep -qxF -- "--internal" && argv | grep -qxF -- "com.acme.internal:*"
check "internal reaches the engine" \
      "private packages are screened against a public registry and reported clean" $?

run "${BASE[@]}"
argv | grep -qxF -- "--internal"
[ $? -ne 0 ]
check "an unset internal passes no flag" \
      "an empty value would become --internal '' and declare nothing while looking configured" $?

run "${BASE[@]}" IN_INTERNAL='com.acme.internal:*,@acme/*'
argv | grep -qxF -- "com.acme.internal:*,@acme/*"
check "a comma-separated glob list survives as one argument" \
      "split across two argv entries the engine sees a stray positional and fails" $?

# A glob must reach the engine as a LITERAL. Unquoted, the shell expands `*` against the working
# directory, so `com.acme.internal:*` becomes whatever files happen to sit beside the checkout —
# declaring nothing internal, on a runner whose contents nobody controls.
mkdir -p "$H/globtest" && : > "$H/globtest/com.acme.internal:decoy"
( cd "$H/globtest" && run "${BASE[@]}" IN_INTERNAL='com.acme.internal:*' )
argv | grep -qxF -- "com.acme.internal:*"
check "a glob is not expanded by the shell before it reaches the engine" \
      "the pattern becomes a filename from the runner and declares nothing" $?

run "${BASE[@]}" IN_FAIL_ON=high
argv | grep -qx -- "high"
check "fail-on reaches the engine" "the gate threshold silently reverts to the engine default" $?

run "${BASE[@]}" IN_FAIL_ONLY_IF_FIX_AVAILABLE=true
argv | grep -qx -- "--fail-only-if-fix-available"
check "fail-only-if-fix-available reaches the engine" "a narrowing input that narrows nothing" $?

run "${BASE[@]}" IN_FAIL_ONLY_IF_FIX_AVAILABLE=false
argv | grep -qx -- "--fail-only-if-fix-available"
[ $? -ne 0 ]
check "a false boolean passes no flag" "'false' as a string is truthy in shell if tested carelessly" $?

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
