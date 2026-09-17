#!/usr/bin/env bash
# The BEHAVIOUR setup step: copy the recorders out of the Scanner image and hand back the environment for the
# customer's TEST STEP ONLY (see behaviour-setup/action.yml for why not job-wide).
#
# Two rules, the same as the recorders keep:
#   1. It never fails the build. Every problem is a ::warning:: and "BEHAVIOUR is off for this run".
#   2. Off must be indistinguishable from not installed. Every env output then carries the value the job
#      ALREADY had, so a workflow that sets `JAVA_TOOL_OPTIONS: ${{ steps.behaviour.outputs.java-tool-options }}`
#      never loses a setting because setup could not run. An empty output would silently replace it.
set -uo pipefail

IMAGE="${INPUT_SCANNER_IMAGE:-}"
IMAGE="${IMAGE:-ghcr.io/depproof/depproof:v0}"
OUT_REL="${INPUT_OUTPUT:-.depproof/behaviour}"
WS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
GH_OUT="${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

emit() { # emit <enabled> <dir> <java> <node> <pythonpath>
  {
    echo "enabled=$1"
    echo "dir=$2"
    echo "from=$OUT_REL"
    echo "java-tool-options=$3"
    echo "node-options=$4"
    echo "pythonpath=$5"
  } >> "$GH_OUT"
}
off() { # off <reason>
  echo "::warning::depproof BEHAVIOUR setup: $1 BEHAVIOUR is off for this run; your tests run exactly as they would without it."
  emit false "" "${JAVA_TOOL_OPTIONS:-}" "${NODE_OPTIONS:-}" "${PYTHONPATH:-}"
  exit 0
}

case "$OUT_REL" in
  /*|*..*|"") off "output must be a relative path inside the workspace (got '$OUT_REL')." ;;
esac
[ "${RUNNER_OS:-Linux}" = "Linux" ] || off "the recorders are copied out of a Linux container image, and this runner is ${RUNNER_OS}."
command -v docker >/dev/null 2>&1 || off "docker is not available on this runner."

REC="$WS/.depproof/recorders"
OUT="$WS/$OUT_REL"
rm -rf "$REC" && mkdir -p "$REC" "$OUT" || off "could not create $REC or $OUT."

cid="$(docker create "$IMAGE" 2>/dev/null)" || off "could not pull $IMAGE."
docker cp "$cid:/app/recorders/." "$REC/" >/dev/null 2>&1
copied=$?
docker rm "$cid" >/dev/null 2>&1 || true
if [ "$copied" -ne 0 ] || [ ! -f "$REC/java/behaviour-agent.jar" ] || [ ! -f "$REC/node/behaviour.cjs" ] || [ ! -f "$REC/python/sitecustomize.py" ]; then
  off "$IMAGE carries no recorders (they ship from Scanner 0.1.25)."
fi

# Keep `git status` clean for suites that assert on it; .git/info/exclude is local and never committed.
if [ -d "$WS/.git/info" ] && ! grep -qx '.depproof/' "$WS/.git/info/exclude" 2>/dev/null; then
  echo '.depproof/' >> "$WS/.git/info/exclude"
fi

# APPEND, never replace: whatever the job already set keeps working.
emit true "$OUT" \
  "${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-javaagent:$REC/java/behaviour-agent.jar" \
  "${NODE_OPTIONS:+$NODE_OPTIONS }--require $REC/node/behaviour.cjs" \
  "$REC/python${PYTHONPATH:+:$PYTHONPATH}"
echo "depproof BEHAVIOUR: recorders from $IMAGE placed in .depproof/recorders; set the outputs on your test step."
