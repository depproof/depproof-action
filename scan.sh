#!/usr/bin/env bash
# The body of the composite action.
#
# WHY IT LIVES IN A FILE RATHER THAN INLINE IN action.yml. GitHub compiles a `run:` block that
# contains ${{ }} expressions as a single template expression, and caps that at 21,000 characters.
# This body exceeded it, which made the action fail to compile with "The template is not valid" --
# before any line executed. A script file is not a template and has no such limit, so the failure
# cannot recur by growth.
#
# Keep it that way: do NOT reintroduce ${{ }} here. Inputs arrive as the INPUT_* environment
# variables action.yml exports, and the action's own directory as ACTION_PATH. An input referenced
# here but not exported there reads as EMPTY, silently -- tests/test_action_template.sh checks both
# directions.

set -euo pipefail

# Default outputs to the workspace so artifacts are easy to upload as build artifacts.
OUTPUT_DIR="${INPUT_OUTPUT_DIR}"
OUTPUT_DIR="${OUTPUT_DIR:-${GITHUB_WORKSPACE}}"
ROOT="${INPUT_ROOT}"
ROOT="${ROOT:-${GITHUB_WORKSPACE}}"

# Build the depproof args based on which input was provided.
ARGS=("scan")

FILE="${INPUT_FILE}"
FILES="${INPUT_FILES}"
DISCOVER="${INPUT_DISCOVER}"

if [ -n "$FILE" ] && [ -n "$FILES" ]; then
  echo "::error::depproof-action: 'file' and 'files' are mutually exclusive"; exit 2
fi

if [ -n "$FILE" ]; then
  ARGS+=("/workspace/$FILE")
elif [ -n "$FILES" ]; then
  # Accept either newline- or comma-separated.
  echo "$FILES" | tr ',' '\n' | while IFS= read -r line; do
    line="$(echo "$line" | xargs)"  # trim whitespace
    [ -z "$line" ] && continue
    ARGS+=("/workspace/$line")
  done
  # NOTE: the while-loop above runs in a subshell — to actually keep the ARGS list,
  # rebuild it here using process substitution-free expansion.
  mapfile -t EXTRA < <(echo "$FILES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' | sed 's|^|/workspace/|')
  ARGS=("scan" "${EXTRA[@]}")
else
  # Default: discovery mode.
  ARGS+=("--discover" "--root" "/workspace")
fi

# CI gate. Rules are OR-ed by the engine; fail-only-if-fix-available narrows all of them.
ARGS+=("--fail-on" "${INPUT_FAIL_ON}")
if [ -n "${INPUT_FAIL_ON_CVSS}" ]; then
  ARGS+=("--fail-on-cvss" "${INPUT_FAIL_ON_CVSS}")
fi
if [ "${INPUT_FAIL_ON_UNKNOWN}" = "true" ]; then
  ARGS+=("--fail-on-unknown")
fi
if [ "${INPUT_FAIL_ONLY_IF_FIX_AVAILABLE}" = "true" ]; then
  ARGS+=("--fail-only-if-fix-available")
fi
# Narrows every rule including KEV, unlike the flag above — see the input's description.
# Passed through verbatim so the engine validates it: a scope word it does not know is a
# usage error there, which is the right place for it. Silently dropping a typo here would
# leave a gate the caller believes is scoped and is not.
if [ -n "${INPUT_IGNORE_SCOPE}" ]; then
  ARGS+=("--ignore-scope" "${INPUT_IGNORE_SCOPE}")
fi
# Your own packages on a private registry. Passed verbatim for the same reason as the flag
# above: the engine owns glob validation, and a pattern silently dropped here would leave a
# caller believing their internal libraries are declared when they are being screened
# against a public registry and reported clean.
# The LOADED axis. A side input: absent, nothing about this scan changes.
#
# Validated HERE rather than passed through blind, unlike --ignore-scope and --internal above,
# because the failure is invisible at the other end. The scan runs in a container with the
# workspace mounted at /workspace, so a path outside the workspace simply does not exist there:
# the engine would find no trace, turn the axis off, and produce a scan that looks exactly like
# one where the user never asked for it. A wrong scope word is a loud usage error; a wrong path
# here is silence.
if [ -n "${INPUT_USAGE_FROM}" ]; then
  case "${INPUT_USAGE_FROM}" in
    /*) echo "::warning::usage-from must be a path inside the workspace, not an absolute path" \
             "(${INPUT_USAGE_FROM}). The scan runs in a container where that path does not exist;" \
             "the usage axis is OFF for this run." ;;
    *)
      if [ -e "${GITHUB_WORKSPACE}/${INPUT_USAGE_FROM}" ]; then
        ARGS+=("--usage-from" "${INPUT_USAGE_FROM}")
      else
        # Named explicitly, because "I set usage-from and got no usage output" is otherwise an
        # unanswerable question. The most common cause by far is a test step that wrote no trace.
        echo "::warning::usage-from path '${INPUT_USAGE_FROM}' does not exist in the workspace." \
             "Did the test step run, and did it write the trace there? The usage axis is OFF" \
             "for this run; the scan itself is unaffected."
      fi
      ;;
  esac
fi
if [ -n "${INPUT_INTERNAL}" ]; then
  ARGS+=("--internal" "${INPUT_INTERNAL}")
fi
ARGS+=("--output-dir" "/workspace/$(realpath --relative-to="$GITHUB_WORKSPACE" "$OUTPUT_DIR" 2>/dev/null || echo .)")

EXCLUDE="${INPUT_EXCLUDE}"
if [ -n "$EXCLUDE" ]; then
  ARGS+=("--exclude" "$EXCLUDE")
fi

# Emit the human-readable HTML report unless explicitly disabled.
if [ "${INPUT_HTML}" = "true" ]; then
  ARGS+=("--html")
fi

# Ask the engine for the markdown summary when either surface will show it. The engine
# renders it, not this Action: it is the component that knows the gate decision with waivers
# applied, and the result is a file any CI can display.
if [ "${INPUT_JOB_SUMMARY}" = "true" ] || [ "${INPUT_PR_COMMENT}" != "false" ]; then
  ARGS+=("--markdown")
fi

# Optional push to a self-hosted depproof-hub. Metadata comes from the GitHub context
# (engine stays headless); the token is forwarded via a valueless -e, never on argv.
DOCKER_ENV=()
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
  DOCKER_ENV=("-e" "DEPPROOF_REPORT_TOKEN")
  if [ -z "${DEPPROOF_REPORT_TOKEN:-}" ]; then
    echo "::warning::depproof-action: report-to is set but report-token is empty — the hub upload will be skipped (set report-required: true to fail the build instead)."
  fi
fi

# Go online resolution: when `go` is on the runner, produce the resolved graph as
# `go.deps.json` next to each `go.mod`. Discovery then prefers `go.deps.json` over `go.mod`.
#
# TWO FILES, because neither can be the other:
#
#   `go.deps.json` <- `go list -m -json all` — the COMPONENT SET. The exact build list, every
#      module the build requires, with direct/indirect and `replace` already resolved by Go.
#   `go.pkgs.json` <- `go list -deps -test -json ./...` — the SCOPE. One object per package,
#      including the ones pulled in only to compile tests, which is the only place Go records
#      what ships: `go.mod` does not mark test requirements and `go list -m` lists modules,
#      not packages, so neither can answer it.
#
# BOTH, rather than preferring the package one, because they are not nested. The package
# stream covers only modules supplying a package the build actually LOADS, and omits every
# module that is required but never imported from — on a large module graph that can be most
# of them. It is GOOS-specific besides, since `go list` resolves build constraints, so a Linux
# runner and a macOS runner do not agree on it. Preferring it would buy scope and silently
# pay coverage; emitting both keeps the full component set and scopes what it can.
#
# The engine merges them: modules the package stream never mentions report no scope rather
# than a guess. `go.pkgs.json` is a sidecar, not a manifest — nothing scans it on its own.
#
# The package command type-checks, so it fails on a tree that does not compile while the
# module graph still resolves. That is why it is emitted best-effort and separately: a
# repository that cannot build should lose the scope, not the whole dependency graph.
#
# Tier 1 is tried first and is the more fragile of the two: it type-checks the packages, so it
# fails on a tree that does not build, where tier 2 succeeds from the module graph alone. That
# is why it falls back rather than replacing — a repository that cannot compile should lose
# the scope, not the whole dependency graph.
if [ "${INPUT_GO_ONLINE:-true}" = "true" ]; then
  if command -v go >/dev/null 2>&1; then
    while IFS= read -r gomod; do
      gdir="$(dirname "$gomod")"
      if ( cd "$gdir" && GOFLAGS=-mod=mod go list -m -json all > go.deps.json 2>/dev/null ) \
         && [ -s "${gdir}/go.deps.json" ]; then
        # The scope sidecar is best-effort ON TOP, never instead: it type-checks, so it fails
        # on a tree that does not compile, and losing it must not cost the dependency graph.
        if ( cd "$gdir" && GOFLAGS=-mod=mod go list -deps -test -json ./... > go.pkgs.json 2>/dev/null ) \
           && [ -s "${gdir}/go.pkgs.json" ]; then
          echo "depproof-action: resolved ${gdir}/go.mod — full module list, with scope"
        else
          rm -f "${gdir}/go.pkgs.json"
          echo "depproof-action: resolved ${gdir}/go.mod — full module list, no scope ('go list -deps' failed; does the tree build?)"
        fi
      else
        rm -f "${gdir}/go.deps.json" "${gdir}/go.pkgs.json"
        echo "::warning::depproof-action: 'go list' failed in ${gdir} — using the static go.mod parse"
      fi
    done < <(find "${ROOT}" -name go.mod -not -path '*/vendor/*' 2>/dev/null)
  else
    echo "depproof-action: 'go' not on the runner — Go modules use the static go.mod parse"
  fi
fi

# Online-mode policy: fetch the org's gate policy from the hub (ADR-0002's reverse arrow) so
# gating is authored once centrally rather than copy-pasted into every repository.
#
# FAIL-CLOSED, and the direction matters. If the fetch fails we apply NO org policy, and the
# engine falls back to its own defaults — which are already the strict ones. So an outage can
# neither relax a gate nor redden an estate. That is the opposite hazard from waivers-online
# below: a waiver set can only ever loosen, while this can tighten every pipeline at once.
#
# We read `.apply`, not `.policy`. The server resolves WARN vs ENFORCE, so those semantics
# live in one place instead of being re-derived by every consumer — a client reading
# `.policy` and enforcing it would ignore WARN and redden the estate it was meant to survey.
if [ "${INPUT_POLICY_ONLINE:-false}" = "true" ]; then
  if [ -z "${INPUT_REPORT_TO:-}" ] || [ -z "${DEPPROOF_REPORT_TOKEN:-}" ]; then
    echo "::warning::depproof-action: policy-online needs report-to + report-token — skipping (scanner defaults apply)."
  else
    POLICY_URL="${INPUT_REPORT_TO%/scans}/policy"
    POLICY_FILE="${RUNNER_TEMP:-/tmp}/.depproof-policy.json"
    if curl -fsS --max-time 20 \
         -H "Authorization: Bearer ${DEPPROOF_REPORT_TOKEN}" \
         "${POLICY_URL}?repo=${GITHUB_REPOSITORY:-}" \
         -o "${POLICY_FILE}"; then
      # Parsed by a script rather than inline: the value can legitimately be JSON null, and
      # a regex that cannot tell null from the string "null" would turn "the org stated
      # nothing" into a flag value the engine rejects as a usage error.
      ORG_REQUIRE_ENRICHMENT="$(bash "${ACTION_PATH}/scripts/read_policy.sh" "${POLICY_FILE}" apply.requireEnrichment)"
      export ORG_REQUIRE_ENRICHMENT
      POLICY_MODE="$(bash "${ACTION_PATH}/scripts/read_policy.sh" "${POLICY_FILE}" policy.mode)"
      echo "depproof-action: org policy fetched from ${POLICY_URL} (mode=${POLICY_MODE:-unknown})"
      if [ "${POLICY_MODE}" = "WARN" ]; then
        # Precise wording, because the obvious phrasing is wrong. WARN means the ORG POLICY is
        # not applied — it does NOT mean nothing is enforced. The scanner's own defaults still
        # run, and for a control whose default is already strict (require-enrichment) a build
        # in WARN can still legitimately go red. Saying "not enforced" beside an exit 4 would
        # send someone hunting a bug that is not there.
        echo "::notice::depproof-action: the org gate policy is in WARN mode — published but not applied. The scanner's own defaults still apply, so a build can still fail."
      fi
    else
      echo "::warning::depproof-action: could not fetch the org policy from the hub — scanner defaults apply (fail-closed)."
    fi
  fi
fi

# Online-mode waivers: fetch the active waiver set from the hub and pass it to the gate so
# centrally-waived findings don't fail the build. FAIL-CLOSED — if the fetch fails we do NOT
# apply waivers (the gate stays strict) and warn, so an unreachable hub can never silently
# turn a red build green. The file lands in the workspace so it's visible inside the container.
if [ "${INPUT_WAIVERS_ONLINE:-false}" = "true" ]; then
  if [ -z "${INPUT_REPORT_TO:-}" ] || [ -z "${DEPPROOF_REPORT_TOKEN:-}" ]; then
    echo "::warning::depproof-action: waivers-online needs report-to + report-token — skipping (gate stays strict)."
  else
    WAIVERS_URL="${INPUT_REPORT_TO%/scans}/waivers"
    if curl -fsS --max-time 20 \
         -H "Authorization: Bearer ${DEPPROOF_REPORT_TOKEN}" \
         "${WAIVERS_URL}?repo=${GITHUB_REPOSITORY:-}" \
         -o "${GITHUB_WORKSPACE}/.depproof-waivers.json"; then
      ARGS+=("--waivers" "/workspace/.depproof-waivers.json")
      echo "depproof-action: applied hub waivers from ${WAIVERS_URL}"
    else
      echo "::warning::depproof-action: could not fetch waivers from the hub — gate stays strict (fail-closed)."
    fi
  fi
fi

# In-perimeter detection: the hub serves the advisories, the scanner matches versions.
# Separate from enrichment below, and the order is why: /enrich is keyed on the finding ids,
# and those do not exist until detection has run.
if [ "${INPUT_DETECT_ONLINE:-false}" = "true" ]; then
  if [ -z "${INPUT_REPORT_TO:-}" ] || [ -z "${DEPPROOF_REPORT_TOKEN:-}" ]; then
    # A warning and the default path, not a silent one: without a hub there is still a working
    # detection route (OSV.dev), so falling back is honest — pretending we used the hub is not.
    echo "::warning::depproof-action: detect-online needs report-to + report-token — skipping (advisories will come from OSV.dev)."
  else
    ADVISORIES_URL="${INPUT_REPORT_TO%/scans}/advisories"
    ARGS+=("--advisories-from" "${ADVISORIES_URL}")
    echo "depproof-action: advisories will be served by the hub at ${ADVISORIES_URL} (no call to OSV.dev)"
  fi
fi

# Licences answered by the hub. Separate from enrichment below and from detection above,
# because the three travel independently: a repository can take licences from the hub while
# taking exploitation data from a prepared file, which is the common combination.
if [ "${INPUT_LICENSES_ONLINE:-false}" = "true" ]; then
  if [ -z "${INPUT_REPORT_TO:-}" ] || [ -z "${DEPPROOF_REPORT_TOKEN:-}" ]; then
    # Warn and carry on with the default route: licences still resolve, just not via the hub.
    # Silently pretending otherwise would be worse than the slower path.
    echo "::warning::depproof-action: licenses-online needs report-to + report-token — skipping (licences will be fetched directly)."
  else
    LICENSES_URL="${INPUT_REPORT_TO%/scans}/enrich"
    ARGS+=("--licenses-from" "${LICENSES_URL}")
    echo "depproof-action: licences will be answered by the hub at ${LICENSES_URL}"
  fi
fi

# Online-mode enrichment: apply exploitation data from the hub. Unlike waivers this ADDS facts,
# so it flows into the SBOM and report too, not just the gate.
#
# Two modes, differing in privacy rather than quality:
#
#   bulk     — fetch the whole catalogue here, before the scan, and let depproof match it
#              locally. The hub never learns which CVEs this repo has. KEV only: the EPSS
#              catalogue is ~355,000 entries and cannot be shipped per run.
#   targeted — hand the URL to depproof, which asks the hub mid-scan once the finding ids
#              exist. Required for EPSS. The hub learns the findings, and in exchange records
#              precisely what this scan was told.
#
# Bulk is fetched here because the ids do not exist until after the scan, while args are built
# before it — that ordering is the whole reason the two modes exist.
if [ "${INPUT_ENRICH_ONLINE:-false}" = "true" ]; then
  if [ -z "${INPUT_REPORT_TO:-}" ] || [ -z "${DEPPROOF_REPORT_TOKEN:-}" ]; then
    echo "::warning::depproof-action: enrich-online needs report-to + report-token — skipping (no exploitation data applied)."
  else
    ENRICH_URL="${INPUT_REPORT_TO%/scans}/enrich"
    if [ "${INPUT_ENRICH_MODE:-bulk}" = "targeted" ]; then
      # depproof does the request itself, and fails closed (exit 4) if the hub is unreachable
      # AND a rule depends on it. The token reaches the container via -e, never on argv.
      ARGS+=("--enrich-from" "${ENRICH_URL}")
      ENRICH_APPLIED=1
      echo "depproof-action: enrichment will be fetched during the scan from ${ENRICH_URL} (targeted)"
    else
      # FAIL-CLOSED: on a failed fetch we apply nothing and warn loudly. A missing snapshot
      # must never read as "nothing is being exploited".
      if curl -fsS --max-time 30 -X POST \
           -H "Authorization: Bearer ${DEPPROOF_REPORT_TOKEN}" \
           -H "Content-Type: application/json" \
           -d "{\"bulk\":true,\"want\":[\"kev\"],\"repo\":\"${GITHUB_REPOSITORY:-}\",\"commit\":\"${GITHUB_SHA:-}\"}" \
           "${ENRICH_URL}" \
           -o "${GITHUB_WORKSPACE}/.depproof-enrich.json"; then
        ARGS+=("--enrich" "/workspace/.depproof-enrich.json")
        ENRICH_APPLIED=1
        echo "depproof-action: applied hub enrichment from ${ENRICH_URL} (bulk)"
      else
        echo "::warning::depproof-action: could not fetch enrichment from the hub — no exploitation data applied (fail-closed)."
      fi
    fi
  fi
fi

# Coverage gating. Unlike the exploitation flags below, this needs no hub and no enrichment —
# it is a fact about the manifest the scan just read, so it is passed through unconditionally
# and the engine rejects an unrecognised value as a usage error rather than ignoring it.
if [ -n "${INPUT_REQUIRE_FIDELITY}" ] && [ "${INPUT_REQUIRE_FIDELITY}" != "off" ]; then
  ARGS+=("--require-fidelity=${INPUT_REQUIRE_FIDELITY}")
fi

# Source reachability. Passed ONLY when a value was stated: the flag is tri-state in the
# engine, where "unstated" means "follow the findings gate" and is not the same as "off".
# Sending off for a blank input would silently disable a control nobody switched off.
#
# Precedence: this repository's own input wins over the org policy fetched above. A repo may
# opt into something STRICTER than the org requires; it can never talk itself down, because
# the org value only reaches ORG_REQUIRE_ENRICHMENT when the hub said ENFORCE.
REQUIRE_ENRICHMENT="${INPUT_REQUIRE_ENRICHMENT:-}"
if [ -z "$REQUIRE_ENRICHMENT" ] && [ -n "${ORG_REQUIRE_ENRICHMENT:-}" ]; then
  REQUIRE_ENRICHMENT="${ORG_REQUIRE_ENRICHMENT}"
  echo "depproof-action: applying org policy require-enrichment=${REQUIRE_ENRICHMENT}"
fi
if [ -n "$REQUIRE_ENRICHMENT" ]; then
  ARGS+=("--require-enrichment=${REQUIRE_ENRICHMENT}")
fi

# Exploitation gating. Only passed when enrichment was actually arranged: the engine rejects
# these flags without a source, so passing them after a failed fetch would turn a hub outage
# into a usage error (exit 2) instead of a scan that simply could not check.
if [ "${INPUT_FAIL_ON_KEV}" = "true" ]; then
  if [ "${ENRICH_APPLIED:-0}" = "1" ]; then
    ARGS+=("--fail-on-kev")
  else
    echo "::warning::depproof-action: fail-on-kev needs enrich-online with a reachable hub — not gating on exploitation this run."
  fi
fi

# EPSS needs targeted mode specifically: the bulk catalogue carries KEV only, so a bulk run
# would pass the flag against data that can never contain a score, and every finding would
# silently fail to match.
if [ -n "${INPUT_FAIL_ON_EPSS}" ]; then
  if [ "${ENRICH_APPLIED:-0}" != "1" ]; then
    echo "::warning::depproof-action: fail-on-epss needs enrich-online with a reachable hub — not gating on EPSS this run."
  elif [ "${INPUT_ENRICH_MODE:-bulk}" != "targeted" ]; then
    echo "::warning::depproof-action: fail-on-epss requires enrich-mode 'targeted' (bulk carries KEV only) — not gating on EPSS this run."
  else
    ARGS+=("--fail-on-epss" "${INPUT_FAIL_ON_EPSS}")
  fi
fi

# Pull + run. The image is a multi-arch manifest at ghcr.io/depproof/depproof:v0.
# `--rm` removes the container after exit. We mount the workspace read-write so SBOMs can
# be written back; depproof doesn't modify the source itself.
# The exit code is captured rather than allowed to propagate, because the surfaces below
# matter MOST when the scan fails — letting `set -e` abort here would mean a failing build
# renders nothing, which is the exact situation this exists to fix. Re-raised verbatim at
# the end, so exit codes 1/2/3/4 keep their distinct meanings.
set +e
docker run --rm \
  "${DOCKER_ENV[@]}" \
  -v "${GITHUB_WORKSPACE}":/workspace \
  -w /workspace \
  ghcr.io/depproof/depproof:v0 \
  "${ARGS[@]}"
DEPPROOF_EXIT=$?
set -e

# ---------------------------------------------------------------------------------------
# Visibility. Everything below is best-effort: a rendering or API problem must never change
# the verdict of a scan that already ran.
# ---------------------------------------------------------------------------------------
# The engine rendered the summary; this Action only decides where to put it. Everything the
# display used to reason about — which verdict is authoritative, how findings rank, whether
# absent data reads as clean — now lives in the engine, where the gate decision actually is,
# and reaches every CI rather than this one.
BODY_SH="${ACTION_PATH}/scripts/summary_body.sh"
SUMMARY_MD="${OUTPUT_DIR}/depproof-summary.md"

# Coverage, on the run page rather than only inside a page someone opens. The engine decides
# whether there is a gap and what to do about it; this only lifts that decision to the one
# surface a green build is actually looked at on. Never fails the step — the gate input
# `require-fidelity` remains the only thing that can fail a build over coverage.
bash "${ACTION_PATH}/scripts/coverage_annotation.sh" \
  "${OUTPUT_DIR}/depproof-summary.json" "${INPUT_REQUIRE_FIDELITY}" || true

# Source reachability, on the same surface and for a sharper version of the same reason. A
# coverage gap means the findings came from part of the graph; an unreached source means they
# came from no screen at all, and that is indistinguishable from a clean project unless
# something says so where the green tick is. Never fails the step: the engine already decided
# the verdict and exited 4 if it mattered.
bash "${ACTION_PATH}/scripts/sources_annotation.sh" \
  "${OUTPUT_DIR}/depproof-summary.json" || true

if [ "${INPUT_JOB_SUMMARY}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  bash "$BODY_SH" "$SUMMARY_MD" "$DEPPROOF_EXIT" >> "$GITHUB_STEP_SUMMARY" \
    || echo "::warning::depproof-action: could not write the job summary"
fi

# PR number comes from the event payload; empty for every non-PR trigger, which is what
# keeps 'auto' from trying to comment on a push or a schedule.
PR_NUM="$(python3 -c 'import json,os; p=os.environ.get("GITHUB_EVENT_PATH",""); d=json.load(open(p)) if p and os.path.exists(p) else {}; print((d.get("pull_request") or {}).get("number") or "")' 2>/dev/null || true)"

if [ "${INPUT_PR_COMMENT}" != "false" ] && [ -n "$PR_NUM" ]; then
  BODY="$(mktemp)"
  if bash "$BODY_SH" "$SUMMARY_MD" "$DEPPROOF_EXIT" '<!-- depproof-action -->' \
       "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" > "$BODY"; then
    # One comment per PR, updated in place. Without the marker lookup every push would add
    # another copy, and the action would become the thing everyone mutes.
    EXISTING="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUM}/comments" --paginate \
                  --jq '.[] | select(.body | contains("<!-- depproof-action -->")) | .id' \
                  2>/dev/null | head -1 || true)"
    if [ -n "$EXISTING" ]; then
      gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING}" \
        -F body=@"$BODY" >/dev/null 2>&1 \
        || echo "::warning::depproof-action: could not update the PR comment — grant 'pull-requests: write' to enable it."
    else
      gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUM}/comments" \
        -F body=@"$BODY" >/dev/null 2>&1 \
        || echo "::warning::depproof-action: could not post the PR comment — grant 'pull-requests: write' to enable it."
    fi
  fi
  rm -f "$BODY"
fi

exit $DEPPROOF_EXIT

