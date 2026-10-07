#!/usr/bin/env bash
# shellcheck disable=SC2319  # `[ cond ]; check ... $?` passes the condition's result on purpose
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
# scan.sh sources its steps from scripts/ beside itself, so they go beside the copy too.
import glob
os.makedirs(os.path.join(os.path.dirname(sys.argv[2]), "scripts"), exist_ok=True)
for lib in glob.glob(os.path.join(os.path.dirname(sys.argv[1]), "scripts", "scan_*.sh")):
    dst = os.path.join(os.path.dirname(sys.argv[2]), "scripts", os.path.basename(lib))
    open(dst, "w").write(re.sub(r"\$\{\{([^}]*)\}\}", sub, open(lib).read()))
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
# docker: records its argv, and which go.* files exist in the workspace at scan time. With
# DOCKER_STUB_SIGNAL set it signals the step while the "scan" runs, which is what a cancelled job does.
cat > "$H/bin/docker" <<'STUB'
#!/usr/bin/env bash
# `docker info` answers from DOCKER_STUB_INFO and is not recorded: it is a question, not the scan.
if [ "${1:-}" = "info" ]; then printf '%s\n' "${DOCKER_STUB_INFO:-}"; exit 0; fi
printf "%s\n" "$*" >> "$DOCKER_ARGS_FILE"
echo "$(id -u):$(id -g)" > "$(dirname "$DOCKER_ARGS_FILE")/runner.ids"
( cd "$GITHUB_WORKSPACE" && find . -name 'go.*' | sort ) > "$(dirname "$DOCKER_ARGS_FILE")/go.snapshot"
if [ -n "${DOCKER_STUB_SIGNAL:-}" ]; then kill -s "$DOCKER_STUB_SIGNAL" "$PPID"; fi
exit 0
STUB
# curl: fails (exit 7, a runner with no hub) unless CURL_STUB_EXIT=0, in which case it writes '{}' to
# its -o target. It records its argv and the content of any `-H @file` header file, so the tests can
# tell what reached the command line from what reached curl another way.
cat > "$H/bin/curl" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$DOCKER_ARGS_FILE")"
printf "%s\n" "$*" >> "$d/curl.args"
out=""; prev=""
for a in "$@"; do
  case "$prev" in
    -H) case "$a" in @*) cat "${a#@}" >> "$d/curl.headers" 2>/dev/null ;; esac ;;
    -o) out="$a" ;;
  esac
  prev="$a"
done
[ "${CURL_STUB_EXIT:-7}" = "0" ] && [ -n "$out" ] && echo '{}' > "$out"
exit "${CURL_STUB_EXIT:-7}"
STUB
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
  : > "$H/curl.args"; : > "$H/curl.headers"; : > "$H/go.snapshot"
  if [ "$host_ok" -eq 1 ]; then
    ( export DOCKER_ARGS_FILE="$H/docker.args" GITHUB_WORKSPACE="$H/ws" \
             GITHUB_STEP_SUMMARY="$H/summary.md" GITHUB_OUTPUT="$H/out.txt" GITHUB_ENV="$H/env.txt" \
             PATH="$H/bin:$PATH"
      for kv in "$@"; do export "${kv?}"; done
      # shellcheck disable=SC1090
      . "$H/env.sh"; bash "$H/step.sh" ) > "$H/run.log" 2>&1
    echo $? > "$H/exit.txt"
  else
    local envs=(); for kv in "$@"; do envs+=(-e "$kv"); done
    # The action is mounted at its host path too, so ACTION_PATH and its helper scripts resolve.
    docker run --rm -v "$H:/h" -v "$ROOT:$ROOT:ro" \
      -e DOCKER_ARGS_FILE=/h/docker.args -e GITHUB_WORKSPACE=/h/ws \
      -e GITHUB_STEP_SUMMARY=/h/summary.md -e GITHUB_OUTPUT=/h/out.txt -e GITHUB_ENV=/h/env.txt \
      "${envs[@]}" bash:5 \
      bash -c 'export PATH=/h/bin:$PATH; . /h/env.sh; bash /h/step.sh' > "$H/run.log" 2>&1
    echo $? > "$H/exit.txt"
  fi
}

argv() { tr ' ' '\n' < "$H/docker.args"; }
BASE=(IN_FAIL_ON=critical IN_DISCOVER=true IN_HTML=false IN_JOB_SUMMARY=false)

echo "action args"

# report-commit / report-branch — provenance for the code that was SCANNED.
#
# $GITHUB_SHA is the head of the ref that TRIGGERED the run. A workflow that checks out a tag, a
# pinned branch or a submodule scans something else, and the Action cannot tell from the outside.
# The failure is quiet in both directions: the hub row describes a tree that was never read, and
# because ingest upserts on (org, repo, commit), an unchanged tree re-scanned after the workflow
# file moves arrives as a NEW scan instead of updating the old one. A corpus pinned for
# comparability then cannot be reconciled against its own published numbers.

run "${BASE[@]}" IN_REPORT_TO=https://hub.example/api/v1/scans IN_REPORT_COMMIT=deadbeefcafe
argv | grep -qx -- "deadbeefcafe"
check "report-commit reaches the engine" \
      "provenance silently describes the triggering ref instead of the scanned tree" $?

run "${BASE[@]}" IN_REPORT_TO=https://hub.example/api/v1/scans IN_REPORT_BRANCH=depproof-pinned
argv | grep -qx -- "depproof-pinned"
check "report-branch reaches the engine" "same, for the ref name" $?

# Unset must keep the existing behaviour exactly: this input is additive, and every consumer that
# scans what triggered it must see no change at all.
run "${BASE[@]}" IN_REPORT_TO=https://hub.example/api/v1/scans GITHUB_SHA=trigger-sha GITHUB_REF_NAME=trigger-ref
argv | grep -qx -- "trigger-sha" && argv | grep -qx -- "trigger-ref"
check "unset report-commit/branch still report the triggering ref" \
      "these inputs are additive; defaulting elsewhere would change provenance for every existing consumer" $?

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

# `baseline` — the failure mode is worse than usage-from's. A baseline that silently does not load
# means the backlog fails the build again, and the obvious conclusion is "baselines do not work"
# rather than "the path was wrong", so the path handling is pinned here rather than trusted.
mkdir -p "$H/ws" && : > "$H/ws/depproof-baseline.json"
run "${BASE[@]}" IN_BASELINE=depproof-baseline.json
argv | grep -qx -- "--baseline" && argv | grep -qx -- "depproof-baseline.json"
check "baseline reaches the engine" \
      "the backlog fails the build and the baseline looks broken when the path was simply wrong" $?

run "${BASE[@]}"
argv | grep -qx -- "--baseline"
[ $? -ne 0 ]
check "an unset baseline passes no flag" \
      "suppressing anything a user did not ask to suppress is the one unforgivable direction" $?

run "${BASE[@]}" IN_BASELINE=/etc/passwd
argv | grep -qx -- "--baseline"
[ $? -ne 0 ]
check "an absolute baseline path is refused" \
      "it does not exist inside the container, and applying nothing quietly is the failure" $?

run "${BASE[@]}" IN_BASELINE=not-committed.json
argv | grep -qx -- "--baseline"
[ $? -ne 0 ]
check "a baseline that is not in the workspace passes no flag" \
      "a missing file must warn, never silently behave as an empty baseline" $?

run "${BASE[@]}" IN_WRITE_BASELINE=true
argv | grep -q -- "--write-baseline"
check "write-baseline reaches the engine" \
      "the one-time adoption step produces nothing and the user has no file to commit" $?

run "${BASE[@]}" IN_WRITE_BASELINE=true
argv | grep -A1 -- "--write-baseline" | grep -q "^/workspace/"
check "write-baseline is an absolute container path" \
      "-w /workspace means a bare filename lands at the repo root and misses the artifact upload" $?

# `sarif` — the flag has to reach the engine, and must cost nothing when unset. The upload half is
# not exercised here (it needs `gh` and a repository); what this pins is the half that silently
# does nothing if it breaks: an input wired to no flag produces a run with no file to upload and no
# error anywhere, which looks exactly like a working scan.
run "${BASE[@]}" IN_SARIF=true
argv | grep -qx -- "--sarif"
check "sarif reaches the engine" \
      "no file is written, the upload finds nothing, and the Security tab stays empty" $?

run "${BASE[@]}"
argv | grep -qx -- "--sarif"
[ $? -ne 0 ]
check "an unset sarif passes no flag" \
      "code scanning must stay opt-in — an upload needs a permission consumers have not granted" $?

run "${BASE[@]}" IN_SARIF=false
argv | grep -qx -- "--sarif"
[ $? -ne 0 ]
check "sarif=false passes no flag" \
      "the documented default must actually be the behaviour" $?

# `fail-on-behaviour` — the only way BEHAVIOUR can fail a build. Off by default, and it must NOT gate when the hub
# or the trace is missing: the hub decides what is new, so without one there is nothing to gate on.
run "${BASE[@]}" IN_BEHAVIOUR_FROM=traces IN_REPORT_TO=https://hub.example/api/v1/scans IN_FAIL_ON_BEHAVIOUR=alert
argv | grep -qx -- "--fail-on-behaviour" && argv | grep -qx -- "alert"
check "fail-on-behaviour=alert reaches the engine" \
      "the gate a customer switched on would silently do nothing" $?

run "${BASE[@]}" IN_BEHAVIOUR_FROM=traces IN_REPORT_TO=https://hub.example/api/v1/scans
argv | grep -qx -- "--fail-on-behaviour"
[ $? -ne 0 ]
check "unset passes no flag" "BEHAVIOUR must stay evidence for everyone who did not ask" $?

run "${BASE[@]}" IN_BEHAVIOUR_FROM=traces IN_REPORT_TO=https://hub.example/api/v1/scans IN_FAIL_ON_BEHAVIOUR=none
argv | grep -qx -- "--fail-on-behaviour"
[ $? -ne 0 ]
check "none passes no flag" "a pipeline must be able to neutralise an inherited setting" $?

run "${BASE[@]}" IN_BEHAVIOUR_FROM=traces IN_FAIL_ON_BEHAVIOUR=alert
argv | grep -qx -- "--fail-on-behaviour"
[ $? -ne 0 ]
check "no hub, no gate" \
      "a build would fail on evidence nothing could judge — the hub is what decides new" $?

# `scanner-image` — which Scanner runs. Unset must stay exactly `:v1`, because Action @v1 always runs Scanner
# :v1 and every consumer relies on that; set, it must be what runs, or a digest pin or an internal mirror is
# silently ignored.
run "${BASE[@]}"
grep -q -- "ghcr.io/depproof/depproof:v1 " "$H/docker.args"
check "an unset scanner-image runs ghcr.io/depproof/depproof:v1" \
      "every existing consumer would silently change Scanner" $?

run "${BASE[@]}" IN_SCANNER_IMAGE=registry.internal/mirror/depproof@sha256:abc123
grep -q -- "registry.internal/mirror/depproof@sha256:abc123 " "$H/docker.args" && ! grep -q -- "depproof:v1" "$H/docker.args"
check "scanner-image is exactly what runs" \
      "a digest pin or an air-gapped mirror would be ignored and the public tag pulled instead" $?

# The container's user. As root it writes root-owned reports into the runner's workspace, which a reused
# runner's next checkout cannot clean. HOME must be writable by that uid in every image, including the
# published ones that predate the Scanner's own non-root user.
user_arg() { argv | grep -A1 -x -- "--user" | tail -n 1; }
run "${BASE[@]}"
[ "$(user_arg)" = "$(cat "$H/runner.ids")" ] && argv | grep -qx -- "HOME=/tmp" \
  && [ "$(argv | grep -n -x -- "--user" | cut -d: -f1)" -lt "$(argv | grep -n -- "depproof:v1" | cut -d: -f1)" ]
check "the Scanner runs as the runner's own user, with a HOME it can write" \
      "reports land root-owned in the workspace, or the Scanner cannot write its caches" $?

run "${BASE[@]}" DOCKER_STUB_INFO="$(printf 'Security Options:\n  seccomp\n   Profile: builtin\n  rootless\n  cgroupns')"
[ "$(user_arg)" = "0:0" ] && argv | grep -qx -- "HOME=/tmp"
check "under rootless Docker the container's uid 0, the runner's own user on the host, is used" \
      "any other uid maps to one that cannot write the workspace, and the scan cannot save its reports" $?

# `usage-from` — the LOADED axis. Its failure mode is unique among the inputs here: a wrong PATH
# produces a scan indistinguishable from one where the user never set the input at all. Every other
# input in this file fails loudly at the engine; this one fails as silence, so the script validates
# it before the container starts and these tests pin that it does.
mkdir -p "$H/ws/traces" && echo "x" > "$H/ws/traces/trace-1.log"

run "${BASE[@]}" IN_USAGE_FROM=traces
argv | grep -qx -- "--usage-from" && argv | grep -qx -- "traces"
check "usage-from reaches the engine" \
      "the axis is silently off and the scan looks identical to one that never asked for it" $?

run "${BASE[@]}"
argv | grep -qx -- "--usage-from"
[ $? -ne 0 ]
check "an unset usage-from passes no flag" \
      "the axis must cost nothing for the overwhelming majority who never enable it" $?

run "${BASE[@]}" IN_USAGE_FROM=does-not-exist
argv | grep -qx -- "--usage-from"
[ $? -ne 0 ]
check "a usage-from path that does not exist passes no flag" \
      "the engine would find no trace and quietly report nothing, with no way to tell why" $?

run "${BASE[@]}" IN_USAGE_FROM=/tmp/outside
argv | grep -qx -- "--usage-from"
[ $? -ne 0 ]
check "an absolute usage-from path is refused" \
      "the scan runs in a container with only the workspace mounted, so the path is not there" $?

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

# ---- release tag, SBOM author and signing, release SBOM ------------------------------------------
#
# The Scanner runs in a container that does not see GITHUB_REF_TYPE, so on a tag build the Action
# must pass the tag itself — and on a branch build it must not, or a branch name is filed as a release.

run "${BASE[@]}" IN_REPORT_TO=https://hub.example/api/v1/scans GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2.3.0
argv | grep -qx -- "--report-tag" && argv | grep -qx -- "v2.3.0"
check "a tag build reports its release tag" "the hub never learns which scan is a release" $?

run "${BASE[@]}" IN_REPORT_TO=https://hub.example/api/v1/scans GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main
argv | grep -qx -- "--report-tag"
[ $? -ne 0 ]
check "a branch build reports no release tag" "a branch name would be filed as a release" $?

run "${BASE[@]}" IN_SBOM_AUTHOR=Acme
argv | grep -qx -- "--sbom-author" && argv | grep -qx -- "Acme"
check "sbom-author reaches the engine" "the SBOM says its author is unknown" $?

KEYPEM=$'-----BEGIN PRIVATE KEY-----\nSECRETKEYMATERIAL\n-----END PRIVATE KEY-----'
mkdir -p "$H/rt"
# RUNNER_TEMP as the step sees it: the host path, or the same directory mounted at /h in bash:5.
RT="$H/rt"; [ "$host_ok" -eq 1 ] || RT="/h/rt"
run "${BASE[@]}" IN_SIGN_KEY="$KEYPEM" RUNNER_TEMP="$RT"
argv | grep -qx -- "--sign-key" && argv | grep -qx -- "/run/depproof-keys/sign-key.pem" && grep -q ":/run/depproof-keys:ro" "$H/docker.args"
check "sign-key is mounted read-only and passed by path" "the SBOM is not signed" $?
grep -q "SECRETKEYMATERIAL" "$H/docker.args" "$H/run.log"
[ $? -ne 0 ]
check "the private key never appears on the command line or in the log" "a signing key leaks into CI logs" $?
[ -z "$(ls -A "$H/rt" 2>/dev/null)" ]
check "the key file is deleted after the scan" "a private key is left on the runner" $?
[ -z "$(find "$H/ws" -name 'sign-key.pem' 2>/dev/null)" ]
check "the key is never written into the workspace" "a later upload step could publish the key" $?

run "${BASE[@]}" IN_SIGN_KEY="$KEYPEM" RUNNER_TEMP="/nonexistent/runner-temp"
argv | grep -qx -- "--sign-key"
[ $? -ne 0 ] && grep -q "will not be signed" "$H/run.log"
check "no private directory means no signing, never a key written elsewhere" "the key lands in a shared path" $?

# Written beside the docker log, wherever the step runs (host, or /h in bash:5).
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$(dirname "$DOCKER_ARGS_FILE")/gh.args"\nexit 0\n' > "$H/bin/gh"; chmod +x "$H/bin/gh"
touch "$H/ws/depproof-sbom.json"
: > "$H/gh.args"
run "${BASE[@]}" IN_RELEASE_SBOM=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2.3.0 GITHUB_REPOSITORY=acme/api
grep -q "release upload v2.3.0" "$H/gh.args" && grep -q "depproof-sbom.json" "$H/gh.args"
check "release-sbom attaches the SBOM to the tag's release" "the original does not travel with the release" $?
: > "$H/gh.args"
run "${BASE[@]}" IN_RELEASE_SBOM=true GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main
[ ! -s "$H/gh.args" ] || ! grep -q "release upload" "$H/gh.args"
check "release-sbom uploads nothing on a branch build" "a branch build would try to publish to a release" $?

# Failure paths: attaching the SBOM is best-effort and must never change the scan's result.
: > "$H/gh.args"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$(dirname "$DOCKER_ARGS_FILE")/gh.args"\nexit 1\n' > "$H/bin/gh"; chmod +x "$H/bin/gh"
run "${BASE[@]}" IN_RELEASE_SBOM=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2.3.0 GITHUB_REPOSITORY=acme/api
grep -q "could not attach the SBOM to release v2.3.0" "$H/run.log" && [ "$(cat "$H/exit.txt")" = "0" ]
check "a failed release upload warns and leaves the scan's result alone" "a GitHub permission would fail a clean build" $?

rm -f "$H/ws"/depproof-sbom*.json
run "${BASE[@]}" IN_RELEASE_SBOM=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2.3.0
grep -q "wrote no SBOM file to attach" "$H/run.log" && [ "$(cat "$H/exit.txt")" = "0" ]
check "release-sbom with no SBOM file warns instead of failing" "a missing file would fail the build" $?

run "${BASE[@]}" IN_SIGN_PUBLIC_KEY=$'-----BEGIN PUBLIC KEY-----\nX\n-----END PUBLIC KEY-----'
grep -q "sign-public-key is set without sign-key" "$H/run.log" && ! argv | grep -qx -- "--sign-public-key"
check "a public key without a private key warns and passes neither" "the Scanner would refuse the flag and fail the scan" $?

# ---- CI identity, usage-tests, usage-run ---------------------------------------------------------
#
# The container does not inherit the runner's environment. Without these the Scanner cannot tell a re-run
# from a new run, or one CI job from another, and a hub keeps only the last job's manifests for a commit.
# Passed by NAME (valueless -e) so docker copies the runner's value and nothing reaches argv.
run "${BASE[@]}" GITHUB_ACTIONS=true GITHUB_RUN_ID=987654321 GITHUB_RUN_ATTEMPT=2 GITHUB_JOB=scan \
    GITHUB_WORKFLOW_REF=acme/api/.github/workflows/ci.yml@refs/heads/main
ok=0
for v in GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_JOB GITHUB_WORKFLOW_REF; do
  grep -q -- "-e $v " "$H/docker.args" || ok=1
done
check "the CI run, attempt, job and workflow are passed into the container" \
      "every scan looks like the same run, and a hub cannot keep each job's manifests" $ok
grep -q -- "987654321\|refs/heads/main" "$H/docker.args"
[ $? -ne 0 ]
check "CI identity is passed by name, never as a value on the command line" \
      "values on argv drift from what the runner set, and argv is where values leak" $?

run "${BASE[@]}" GITHUB_RUN_ID=1 IN_REPORT_TO=https://hub.example/api/v1/scans IN_REPORT_TOKEN=s3cr3t-token
grep -q -- "-e DEPPROOF_REPORT_TOKEN " "$H/docker.args" && grep -q -- "-e GITHUB_RUN_ID " "$H/docker.args" \
  && ! grep -q "s3cr3t-token" "$H/docker.args"
check "the report token is still passed alongside CI identity, by name only" \
      "adding CI identity must not drop the hub credential, or put it on argv" $?

mkdir -p "$H/ws/test-results" && echo '<testsuite tests="1"/>' > "$H/ws/test-results/TEST-a.xml"
run "${BASE[@]}" IN_USAGE_FROM=traces IN_USAGE_TESTS=test-results
argv | grep -qx -- "--usage-tests" && argv | grep -qx -- "test-results"
check "usage-tests reaches the engine" "the LOADED coverage line says tests=unknown when reports exist" $?

run "${BASE[@]}" IN_USAGE_TESTS=test-results
argv | grep -qx -- "--usage-tests"
[ $? -ne 0 ] && grep -q "usage-tests has no effect without" "$H/run.log"
check "usage-tests without usage-from passes no flag and says why" \
      "test counts describe a trace; alone they describe nothing" $?

run "${BASE[@]}" IN_USAGE_FROM=traces IN_USAGE_TESTS=/tmp/reports
argv | grep -qx -- "--usage-tests"
[ $? -ne 0 ]
check "an absolute usage-tests path is refused" "it does not exist inside the container" $?

run "${BASE[@]}" IN_USAGE_FROM=traces IN_USAGE_TESTS=no-such-reports
argv | grep -qx -- "--usage-tests"
[ $? -ne 0 ] && [ "$(cat "$H/exit.txt")" = "0" ]
check "a usage-tests path that does not exist passes no flag and does not fail" \
      "evidence must never fail a build" $?

run "${BASE[@]}" IN_USAGE_FROM=traces IN_USAGE_RUN=startup
argv | grep -qx -- "--usage-run" && argv | grep -qx -- "startup"
check "usage-run reaches the engine" \
      "a startup trace is judged as a test run, and its absences read as never loaded" $?

run "${BASE[@]}" IN_USAGE_FROM=traces
argv | grep -qx -- "--usage-run"
[ $? -ne 0 ]
check "an unset usage-run passes no flag" "the Scanner's default (tests) must stay the default" $?

run "${BASE[@]}" IN_USAGE_RUN=startup
argv | grep -qx -- "--usage-run"
[ $? -ne 0 ]
check "usage-run without usage-from passes no flag" "it describes a trace that is not there" $?

# ---- temporary material: removed on every exit, including a cancelled job -------------------------
#
# A cancelled job is signalled while the scan runs. Without a trap the key, the hub credential and the
# hub's responses outlive the step on a runner that may be shared or reused.
rm -rf "${H:?}/rt"/*
run "${BASE[@]}" IN_SIGN_KEY="$KEYPEM" RUNNER_TEMP="$RT" DOCKER_STUB_SIGNAL=TERM
[ -z "$(ls -A "$H/rt" 2>/dev/null)" ] && [ "$(cat "$H/exit.txt")" != "0" ]
check "the signing key is removed when the job is cancelled (TERM)" "a private key is left on the runner" $?

rm -rf "${H:?}/rt"/*
run "${BASE[@]}" IN_SIGN_KEY="$KEYPEM" RUNNER_TEMP="$RT" DOCKER_STUB_SIGNAL=INT
[ -z "$(ls -A "$H/rt" 2>/dev/null)" ] && [ "$(cat "$H/exit.txt")" != "0" ]
check "the signing key is removed when the job is interrupted (INT)" "a private key is left on the runner" $?

# ---- the hub token never reaches a command line ------------------------------------------------------
#
# Any process on the runner can read another's argv. The token travels in a private header file that curl
# reads with `-H @file`, and that file is gone when the step ends.
HUB=(IN_REPORT_TO=https://hub.example/api/v1/scans IN_REPORT_TOKEN=s3cr3t-token RUNNER_TEMP="$RT")
rm -rf "${H:?}/rt"/*
run "${BASE[@]}" "${HUB[@]}" IN_POLICY_ONLINE=true IN_WAIVERS_ONLINE=true IN_ENRICH_ONLINE=true CURL_STUB_EXIT=0
[ "$(grep -c -- '-H @' "$H/curl.args")" = "3" ]
check "policy, waivers and bulk enrichment each send the token from a header file" \
      "a hub call goes out without credentials and every online feature fails closed" $?
! grep -q "s3cr3t-token" "$H/curl.args" "$H/docker.args" "$H/run.log"
check "the hub token never appears in curl's or docker's argv, or the log" \
      "the credential is readable by every process on the runner" $?
[ "$(grep -c "^Authorization: Bearer s3cr3t-token$" "$H/curl.headers")" = "3" ]
check "the header file carries the token to curl" "the hub sees an unauthenticated request" $?
[ -z "$(ls -A "$H/rt" 2>/dev/null)" ]
check "the header file and hub responses are removed after the scan" "the token is left on the runner" $?

rm -rf "${H:?}/rt"/*
run "${BASE[@]}" "${HUB[@]}" IN_WAIVERS_ONLINE=true CURL_STUB_EXIT=0 DOCKER_STUB_SIGNAL=TERM
[ -z "$(ls -A "$H/rt" 2>/dev/null)" ]
check "the header file is removed when the job is cancelled" "the token is left on the runner" $?

# ---- hub responses stay out of the workspace -------------------------------------------------------
#
# Anything written into the workspace can be swept up by a later upload or cache step. The responses live
# under RUNNER_TEMP and reach the Scanner through a read-only mount that does not include the header file.
rm -rf "${H:?}/rt"/*
run "${BASE[@]}" "${HUB[@]}" IN_WAIVERS_ONLINE=true IN_ENRICH_ONLINE=true CURL_STUB_EXIT=0
argv | grep -qx -- "/run/depproof-hub/waivers.json" && argv | grep -qx -- "/run/depproof-hub/enrich.json"
check "waivers and enrichment are passed by their in-container path" "the gate runs without them" $?
grep -q -- "/responses:/run/depproof-hub:ro " "$H/docker.args"
check "the responses directory is mounted read-only" "the Scanner cannot read the waivers" $?
grep -q -- "-o $RT/depproof-hub\.[^/ ]*/responses/waivers.json" "$H/curl.args" \
  && grep -q -- "-o $RT/depproof-hub\.[^/ ]*/responses/enrich.json" "$H/curl.args" \
  && grep -q -- "-H @$RT/depproof-hub\.[^/ ]*/auth.header" "$H/curl.args"
check "responses land under RUNNER_TEMP, the header file outside the mounted directory" \
      "the credential would be mounted into the Scanner" $?
[ -z "$(find "$H/ws" -name '.depproof-*' 2>/dev/null)" ]
check "no hub response is written into the workspace" "a later upload step could publish it" $?

rm -rf "${H:?}/rt"/*
run "${BASE[@]}" "${HUB[@]}" IN_WAIVERS_ONLINE=true
! argv | grep -qx -- "--waivers" && ! grep -q -- "/run/depproof-hub" "$H/docker.args" \
  && grep -q "could not fetch waivers" "$H/run.log" && [ "$(cat "$H/exit.txt")" = "0" ]
check "a failed waiver fetch mounts nothing, passes no flag and does not fail the step" \
      "an unreachable hub would turn into a usage error" $?

# ---- Go resolution leaves the checkout as it found it ----------------------------------------------
#
# `go list` with -mod=mod may rewrite go.mod and go.sum, and resolution writes go.deps.json beside each
# module. A later step that commits, diffs or caches the tree must not see any of it. The stub rewrites
# go.mod and go.sum the way Go can.
cat > "$H/bin/go" <<'STUB'
#!/usr/bin/env bash
echo "require example.com/added v1.0.0" >> go.mod
echo "example.com/added v1.0.0 h1:x" > go.sum
case "$*" in *-deps*) echo '{"ImportPath":"example.com/svc"}' ;; *) echo '{"Path":"example.com/svc"}' ;; esac
STUB
chmod +x "$H/bin/go"
go_tree() { # a module without go.sum, and one with go.sum and a committed go.deps.json
  rm -rf "$H/ws/svc" "$H/ws/lib"; mkdir -p "$H/ws/svc" "$H/ws/lib"
  printf 'module example.com/svc\n' > "$H/ws/svc/go.mod"
  printf 'module example.com/lib\n' > "$H/ws/lib/go.mod"
  printf 'example.com/dep v1 h1:orig\n' > "$H/ws/lib/go.sum"
  printf 'COMMITTED\n' > "$H/ws/lib/go.deps.json"
}
go_untouched() {
  [ "$(cat "$H/ws/svc/go.mod")" = "module example.com/svc" ] && [ ! -e "$H/ws/svc/go.sum" ] \
    && [ ! -e "$H/ws/svc/go.deps.json" ] && [ ! -e "$H/ws/svc/go.pkgs.json" ] \
    && [ "$(cat "$H/ws/lib/go.mod")" = "module example.com/lib" ] \
    && [ "$(cat "$H/ws/lib/go.sum")" = "example.com/dep v1 h1:orig" ] \
    && [ "$(cat "$H/ws/lib/go.deps.json")" = "COMMITTED" ] && [ ! -e "$H/ws/lib/go.pkgs.json" ]
}
WSROOT="$H/ws"; [ "$host_ok" -eq 1 ] || WSROOT="/h/ws"

go_tree; rm -rf "${H:?}/rt"/*
run "${BASE[@]}" RUNNER_TEMP="$RT" IN_ROOT="$WSROOT"
grep -qx "./svc/go.deps.json" "$H/go.snapshot" && grep -qx "./svc/go.pkgs.json" "$H/go.snapshot" \
  && grep -q "resolved .*/svc/go.mod — full module list, with scope" "$H/run.log"
check "the resolved graph is in place while the scan runs" "Go modules fall back to the static parse" $?
go_untouched
check "go.mod, go.sum and go.deps.json are restored or removed after the scan" \
      "the action leaves edits in the customer's checkout" $?
[ -z "$(ls -A "$H/rt" 2>/dev/null)" ]
check "the Go backups are removed after the scan" "copies of the tree accumulate on the runner" $?

go_tree
run "${BASE[@]}" RUNNER_TEMP="$RT" IN_ROOT="$WSROOT" DOCKER_STUB_SIGNAL=TERM
go_untouched
check "the checkout is restored when the job is cancelled mid-scan" "a cancelled job leaves edits behind" $?

go_tree
run "${BASE[@]}" RUNNER_TEMP="/nonexistent/runner-temp" IN_ROOT="$WSROOT"
go_untouched && grep -q "could not back up" "$H/run.log" && [ "$(cat "$H/exit.txt")" = "0" ]
check "no backup means no resolution, never an unrestorable edit" \
      "the tree is rewritten with no way back" $?
rm -rf "$H/ws/svc" "$H/ws/lib" "$H/bin/go"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
