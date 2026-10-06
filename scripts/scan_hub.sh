# shellcheck shell=bash
# Sourced by scan.sh: everything that talks to a self-hosted depproof hub, plus the CI identity passed
# into the container. Each hub-backed input warns and is skipped without report-to and report-token;
# none of them can fail a build by being unreachable except where the input says so.

# hub_ready <input> <what-happens-instead>
# Every hub-backed input needs both the URL and the token; without them it warns and is skipped.
hub_ready() {
  if [ -z "${INPUT_REPORT_TO:-}" ] || [ -z "${DEPPROOF_REPORT_TOKEN:-}" ]; then
    echo "::warning::depproof-action: $1 needs report-to + report-token — skipping ($2)."
    return 1
  fi
}

# hub_auth_header: makes ${HUB_TMP}/auth.header for `curl -H @file`. The token goes into a file, never
# onto curl's command line, where any process on the runner can read it. The responses directory beside
# it is what the Scanner gets mounted; the header file is not in it.
hub_auth_header() {
  if [ -z "$HUB_TMP" ]; then
    HUB_TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/depproof-hub.XXXXXX" 2>/dev/null)" || { HUB_TMP=""; return 1; }
    mkdir "${HUB_TMP}/responses" 2>/dev/null || return 1
    ( umask 077; printf 'Authorization: Bearer %s\n' "${DEPPROOF_REPORT_TOKEN}" > "${HUB_TMP}/auth.header" ) 2>/dev/null
  fi
  [ -s "${HUB_TMP}/auth.header" ] && [ -d "${HUB_TMP}/responses" ]
}

build_report_args() {
  # The CI run this scan belongs to. The Scanner records which run, attempt, job and workflow produced
  # the scan, so a hub can tell a re-run from a new run, keep every job's manifests for a commit rather
  # than the last one's, and combine proof from test shards. The container does not inherit the
  # runner's environment, so each identifier is passed by NAME with a valueless -e: docker copies the
  # runner's value, an unset one stays unset, and nothing reaches argv. Identifiers only — never a
  # token, URL or other value. Passed on every run, hub or not, because the summary JSON carries them too.
  DOCKER_ENV=("-e" "GITHUB_ACTIONS" "-e" "GITHUB_RUN_ID" "-e" "GITHUB_RUN_ATTEMPT" "-e" "GITHUB_JOB" "-e" "GITHUB_WORKFLOW_REF")

  # Optional push to the hub. Metadata comes from the GitHub context so the engine stays headless; the
  # token is forwarded via a valueless -e, never on argv.
  if [ -n "${INPUT_REPORT_TO:-}" ]; then
    # Provenance describes the code that was SCANNED, which is not always the code that triggered the
    # run. $GITHUB_SHA is the triggering ref's head; a workflow that checks out a tag, a pinned branch
    # or a submodule scans something else entirely, and the Action cannot see that from the outside.
    # Reporting the wrong commit is quietly corrosive: the hub row cannot be reconciled against the
    # tree it describes, and an unchanged tree re-scanned after the workflow file moves ingests as a
    # NEW scan rather than updating the existing one, because ingest upserts on (org, repo, commit).
    ARGS+=("--report-to" "$INPUT_REPORT_TO" "--report-repo" "${GITHUB_REPOSITORY:-}" \
           "--report-commit" "${INPUT_REPORT_COMMIT:-${GITHUB_SHA:-}}" \
           "--report-branch" "${INPUT_REPORT_BRANCH:-${GITHUB_REF_NAME:-}}" \
           "--report-event" "${GITHUB_EVENT_NAME:-}")
    [ "${INPUT_REPORT_REQUIRED:-false}" = "true" ] && ARGS+=("--report-required")
    # The release this commit was built as, on a tag build only. The Scanner can read the CI's tag
    # variable itself, but it runs in a container that does not see GITHUB_REF_TYPE, so it is passed
    # here. A branch build sends none: a branch name is never reported as a release.
    if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
      ARGS+=("--report-tag" "${GITHUB_REF_NAME}")
    fi
    DOCKER_ENV+=("-e" "DEPPROOF_REPORT_TOKEN")
    if [ -z "${DEPPROOF_REPORT_TOKEN:-}" ]; then
      echo "::warning::depproof-action: report-to is set but report-token is empty — the hub upload will be skipped (set report-required: true to fail the build instead)."
    fi
  fi
}

# The org's gate policy, authored once on the hub rather than copy-pasted into every repository.
#
# FAIL-CLOSED, and the direction matters. If the fetch fails no org policy is applied, and the engine
# falls back to its own defaults — which are already the strict ones. So an outage can neither relax a
# gate nor redden an estate. That is the opposite hazard from waivers: a waiver set can only ever
# loosen, while this can tighten every pipeline at once.
#
# It reads `.apply`, not `.policy`. The server resolves WARN vs ENFORCE, so those semantics live in one
# place instead of being re-derived by every consumer — a client reading `.policy` and enforcing it
# would ignore WARN and redden the estate it was meant to survey.
fetch_hub_policy() {
  [ "${INPUT_POLICY_ONLINE:-false}" = "true" ] || return 0
  hub_ready policy-online "scanner defaults apply" || return 0
  POLICY_URL="${INPUT_REPORT_TO%/scans}/policy"
  if hub_auth_header && curl -fsS --max-time 20 \
       -H "@${HUB_TMP}/auth.header" \
       "${POLICY_URL}?repo=${GITHUB_REPOSITORY:-}" \
       -o "${HUB_TMP}/policy.json"; then
    POLICY_FILE="${HUB_TMP}/policy.json"
    # Parsed by a script rather than inline: the value can legitimately be JSON null, and a regex
    # that cannot tell null from the string "null" would turn "the org stated nothing" into a flag
    # value the engine rejects as a usage error.
    ORG_REQUIRE_ENRICHMENT="$(bash "${ACTION_PATH}/scripts/read_policy.sh" "${POLICY_FILE}" apply.requireEnrichment)"
    export ORG_REQUIRE_ENRICHMENT
    POLICY_MODE="$(bash "${ACTION_PATH}/scripts/read_policy.sh" "${POLICY_FILE}" policy.mode)"
    echo "depproof-action: org policy fetched from ${POLICY_URL} (mode=${POLICY_MODE:-unknown})"
    if [ "${POLICY_MODE}" = "WARN" ]; then
      # Precise wording, because the obvious phrasing is wrong. WARN means the ORG POLICY is not
      # applied — it does NOT mean nothing is enforced. The scanner's own defaults still run, and
      # for a control whose default is already strict (require-enrichment) a build in WARN can
      # still legitimately go red. Saying "not enforced" beside an exit 4 would send someone
      # hunting a bug that is not there.
      echo "::notice::depproof-action: the org gate policy is in WARN mode — published but not applied. The scanner's own defaults still apply, so a build can still fail."
    fi
  else
    echo "::warning::depproof-action: could not fetch the org policy from the hub — scanner defaults apply (fail-closed)."
  fi
}

# The active waiver set, so centrally-waived findings don't fail the build. FAIL-CLOSED — if the fetch
# fails no waivers are applied (the gate stays strict) and it warns, so an unreachable hub can never
# silently turn a red build green. The file lands under RUNNER_TEMP, not the workspace, so no later
# upload step can publish it, and reaches the Scanner through a read-only mount.
fetch_hub_waivers() {
  [ "${INPUT_WAIVERS_ONLINE:-false}" = "true" ] || return 0
  hub_ready waivers-online "gate stays strict" || return 0
  WAIVERS_URL="${INPUT_REPORT_TO%/scans}/waivers"
  if hub_auth_header && curl -fsS --max-time 20 \
       -H "@${HUB_TMP}/auth.header" \
       "${WAIVERS_URL}?repo=${GITHUB_REPOSITORY:-}" \
       -o "${HUB_TMP}/responses/waivers.json"; then
    ARGS+=("--waivers" "/run/depproof-hub/waivers.json")
    HUB_MOUNT=1
    echo "depproof-action: applied hub waivers from ${WAIVERS_URL}"
  else
    echo "::warning::depproof-action: could not fetch waivers from the hub — gate stays strict (fail-closed)."
  fi
}

# Detection and licences served by the hub. Each is separate from enrichment, for different reasons:
# /enrich is keyed on finding ids, which do not exist until detection has run; and the three travel
# independently — a repository can take licences from the hub while taking exploitation data from a
# prepared file, which is the common combination.
#
# Without a hub each warns and keeps its default route (OSV.dev, direct licence lookup): falling back
# is honest, pretending the hub was used is not.
build_hub_source_args() {
  if [ "${INPUT_DETECT_ONLINE:-false}" = "true" ]; then
    if hub_ready detect-online "advisories will come from OSV.dev"; then
      ADVISORIES_URL="${INPUT_REPORT_TO%/scans}/advisories"
      ARGS+=("--advisories-from" "${ADVISORIES_URL}")
      echo "depproof-action: advisories will be served by the hub at ${ADVISORIES_URL} (no call to OSV.dev)"
    fi
  fi
  if [ "${INPUT_LICENSES_ONLINE:-false}" = "true" ]; then
    if hub_ready licenses-online "licences will be fetched directly"; then
      LICENSES_URL="${INPUT_REPORT_TO%/scans}/enrich"
      ARGS+=("--licenses-from" "${LICENSES_URL}")
      echo "depproof-action: licences will be answered by the hub at ${LICENSES_URL}"
    fi
  fi
}

# Exploitation data from the hub. Unlike waivers this ADDS facts, so it flows into the SBOM and report
# too, not just the gate.
#
# Two modes, differing in privacy rather than quality:
#
#   bulk     — fetch the whole catalogue here, before the scan, and let depproof match it locally.
#              The hub never learns which CVEs this repo has. KEV only: the EPSS catalogue is
#              ~355,000 entries and cannot be shipped per run.
#   targeted — hand the URL to depproof, which asks the hub mid-scan once the finding ids exist.
#              Required for EPSS. The hub learns the findings, and in exchange records precisely
#              what this scan was told.
#
# Bulk is fetched here because the ids do not exist until after the scan, while args are built before
# it — that ordering is the whole reason the two modes exist.
arrange_hub_enrichment() {
  [ "${INPUT_ENRICH_ONLINE:-false}" = "true" ] || return 0
  hub_ready enrich-online "no exploitation data applied" || return 0
  ENRICH_URL="${INPUT_REPORT_TO%/scans}/enrich"
  if [ "${INPUT_ENRICH_MODE:-bulk}" = "targeted" ]; then
    # depproof does the request itself, and fails closed (exit 4) if the hub is unreachable AND a
    # rule depends on it. The token reaches the container via -e, never on argv.
    ARGS+=("--enrich-from" "${ENRICH_URL}")
    ENRICH_APPLIED=1
    echo "depproof-action: enrichment will be fetched during the scan from ${ENRICH_URL} (targeted)"
  # FAIL-CLOSED: on a failed fetch nothing is applied and it warns loudly. A missing snapshot must
  # never read as "nothing is being exploited".
  elif hub_auth_header && curl -fsS --max-time 30 -X POST \
       -H "@${HUB_TMP}/auth.header" \
       -H "Content-Type: application/json" \
       -d "{\"bulk\":true,\"want\":[\"kev\"],\"repo\":\"${GITHUB_REPOSITORY:-}\",\"commit\":\"${GITHUB_SHA:-}\"}" \
       "${ENRICH_URL}" \
       -o "${HUB_TMP}/responses/enrich.json"; then
    ARGS+=("--enrich" "/run/depproof-hub/enrich.json")
    # shellcheck disable=SC2034  # read by run_scanner and build_dependent_gate_args
    HUB_MOUNT=1
    # shellcheck disable=SC2034
    ENRICH_APPLIED=1
    echo "depproof-action: applied hub enrichment from ${ENRICH_URL} (bulk)"
  else
    echo "::warning::depproof-action: could not fetch enrichment from the hub — no exploitation data applied (fail-closed)."
  fi
}
