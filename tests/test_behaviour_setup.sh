#!/usr/bin/env bash
# Tests for scripts/behaviour_setup.sh — the BEHAVIOUR setup step.
#
# What matters is not that the recorders get copied; it is the two promises the step makes:
#   1. It never fails a build: every failure is a warning, exit 0.
#   2. Off is indistinguishable from not installed: each env output carries the job's EXISTING value, so a
#      workflow wiring `JAVA_TOOL_OPTIONS: ${{ steps.behaviour.outputs.java-tool-options }}` never loses a
#      setting it already had. An empty output would silently replace it — a behaviour change in the
#      customer's tests caused by a tool that promises never to cause one.
#
# `docker` is a stub on PATH: `create` prints an id, `cp` copies from a fake image directory, so the tests
# need no Docker and no network. Run: bash tests/test_behaviour_setup.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$(mktemp -d)"
trap 'rm -rf "$H"' EXIT
pass=0; fail=0
check() { if [ "$3" -eq 0 ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL %s — %s\n' "$1" "$2"; fail=$((fail+1)); fi; }

mkdir -p "$H/bin" "$H/image/java" "$H/image/node" "$H/image/python" "$H/image/dotnet"
touch "$H/image/java/behaviour-agent.jar" "$H/image/node/behaviour.cjs" "$H/image/python/sitecustomize.py" \
      "$H/image/dotnet/DepproofLoaded.dll"
# An older image: the three BEHAVIOUR recorders, no .NET LOADED hook.
mkdir -p "$H/image-nodotnet"; cp -R "$H/image/." "$H/image-nodotnet/"; rm -rf "$H/image-nodotnet/dotnet"
cat > "$H/bin/docker" <<'D'
#!/usr/bin/env bash
case "$1" in
  create) [ "${STUB_PULL_FAILS:-}" = 1 ] && exit 1; echo "cid123" ;;
  cp)     [ "${STUB_NO_RECORDERS:-}" = 1 ] && exit 1; cp -R "$STUB_IMAGE/." "$3" ;;
  rm)     : ;;
esac
D
chmod +x "$H/bin/docker"

run() { # run [VAR=value]... ; outputs in $H/out, log in $H/log, exit code in $H/rc
  rm -rf "$H/ws"; mkdir -p "$H/ws/.git/info"; : > "$H/out"
  ( export GITHUB_WORKSPACE="$H/ws" GITHUB_OUTPUT="$H/out" RUNNER_OS=Linux STUB_IMAGE="$H/image" PATH="$H/bin:$PATH"
    unset JAVA_TOOL_OPTIONS NODE_OPTIONS PYTHONPATH DOTNET_STARTUP_HOOKS INPUT_OUTPUT INPUT_SCANNER_IMAGE
    for kv in "$@"; do export "${kv?}"; done
    bash "$ROOT/scripts/behaviour_setup.sh" ) > "$H/log" 2>&1
  echo $? > "$H/rc"
}
out() { grep "^$1=" "$H/out" | head -1 | cut -d= -f2-; }

echo "behaviour setup"

run
[ "$(cat "$H/rc")" = 0 ] && [ "$(out enabled)" = true ] && [ -f "$H/ws/.depproof/recorders/java/behaviour-agent.jar" ]
check "recorders are placed and the step reports enabled" "BEHAVIOUR could never be switched on" $?
[ "$(out java-tool-options)" = "-javaagent:$H/ws/.depproof/recorders/java/behaviour-agent.jar" ] &&
  [ "$(out node-options)" = "--require $H/ws/.depproof/recorders/node/behaviour.cjs" ] &&
  [ "$(out pythonpath)" = "$H/ws/.depproof/recorders/python" ] &&
  [ "$(out dir)" = "$H/ws/.depproof/behaviour" ] && [ "$(out from)" = ".depproof/behaviour" ]
check "each output points at the placed recorder" "the test step would load nothing and report not analysed" $?
grep -qx '.depproof/' "$H/ws/.git/info/exclude"
check ".depproof/ is excluded locally" "a suite that asserts a clean git status would fail because of us" $?

run "JAVA_TOOL_OPTIONS=-Xmx2g" "NODE_OPTIONS=--max-old-space-size=4096" "PYTHONPATH=/opt/lib"
[ "$(out java-tool-options)" = "-Xmx2g -javaagent:$H/ws/.depproof/recorders/java/behaviour-agent.jar" ] &&
  [ "$(out node-options)" = "--max-old-space-size=4096 --require $H/ws/.depproof/recorders/node/behaviour.cjs" ] &&
  [ "$(out pythonpath)" = "$H/ws/.depproof/recorders/python:/opt/lib" ]
check "existing JAVA_TOOL_OPTIONS / NODE_OPTIONS / PYTHONPATH are kept, never replaced" \
      "a customer's heap size or import path would vanish from their tests" $?

# .NET LOADED — a startup hook plus its output directory, read by the scan's usage-from.
run
[ "$(out dotnet-startup-hooks)" = "$H/ws/.depproof/recorders/dotnet/DepproofLoaded.dll" ] &&
  [ "$(out loaded-dir)" = "$H/ws/.depproof/loaded" ] && [ "$(out loaded-from)" = ".depproof/loaded" ] &&
  [ -d "$H/ws/.depproof/loaded" ] && [ -f "$H/ws/.depproof/recorders/dotnet/DepproofLoaded.dll" ]
check ".NET LOADED outputs point at the placed hook and a separate loaded directory" \
      "a dotnet test step would load no hook, or write into the BEHAVIOUR directory" $?
[ "$(out javaagent)" = "-javaagent:$H/ws/.depproof/recorders/java/behaviour-agent.jar" ]
check "javaagent is the bare agent flag, for MAVEN_OPTS or org.gradle.jvmargs" \
      "a build tool's JVM would get no agent and plugins would go unseen" $?

run "DOTNET_STARTUP_HOOKS=/opt/hooks/Existing.dll"
[ "$(out dotnet-startup-hooks)" = "/opt/hooks/Existing.dll:$H/ws/.depproof/recorders/dotnet/DepproofLoaded.dll" ]
check "an existing DOTNET_STARTUP_HOOKS is kept, the hook appended with ':'" \
      "a customer's own startup hook would stop loading in their tests" $?

run "STUB_IMAGE=$H/image-nodotnet" "DOTNET_STARTUP_HOOKS=/opt/hooks/Existing.dll"
[ "$(cat "$H/rc")" = 0 ] && [ "$(out enabled)" = true ] &&
  [ "$(out dotnet-startup-hooks)" = "/opt/hooks/Existing.dll" ] && [ -z "$(out loaded-dir)" ]
check "an image without the .NET hook keeps BEHAVIOUR on and passes DOTNET_STARTUP_HOOKS through" \
      "an older image would switch BEHAVIOUR off, or point the runtime at a hook that does not exist" $?

for case in "STUB_PULL_FAILS=1|the image cannot be pulled" "STUB_NO_RECORDERS=1|the image carries no recorders" \
            "RUNNER_OS=macOS|the runner is not Linux" "INPUT_OUTPUT=/abs/path|the output is absolute" \
            "INPUT_OUTPUT=../outside|the output escapes the workspace"; do
  kv="${case%%|*}"; why="${case#*|}"
  run "$kv" "JAVA_TOOL_OPTIONS=-Xmx2g" "NODE_OPTIONS=--inspect=0" "PYTHONPATH=/opt/lib" "DOTNET_STARTUP_HOOKS=/opt/h.dll"
  [ "$(cat "$H/rc")" = 0 ] && [ "$(out enabled)" = false ] && [ -z "$(out dir)" ] &&
    [ "$(out java-tool-options)" = "-Xmx2g" ] && [ "$(out node-options)" = "--inspect=0" ] && [ "$(out pythonpath)" = "/opt/lib" ] &&
    [ "$(out dotnet-startup-hooks)" = "/opt/h.dll" ] && [ -z "$(out loaded-dir)" ] && [ -z "$(out javaagent)" ] &&
    grep -q "::warning::" "$H/log"
  check "off when $why: exit 0, a warning, and every setting passed through unchanged" \
        "a setup problem would fail the build or strip the customer's own settings" $?
done

run "PATH=/usr/bin:/bin" "RUNNER_OS=Linux"
# no docker on PATH at all (the stub dir is dropped by the PATH override above)
[ "$(cat "$H/rc")" = 0 ] && { [ "$(out enabled)" = false ] || command -v docker >/dev/null 2>&1; }
check "no docker on the runner is a warning, not a failure" "the build would fail on a runner without Docker" $?

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
