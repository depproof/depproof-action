# shellcheck shell=bash
# Sourced by scan.sh: turns the Action's inputs into the engine's command line, in ARGS.
#
# Each function appends in a fixed order; scan.sh calls them in that order, so the engine's argv is
# stable from run to run.

# workspace_path_arg <input> <flag> <value> <if-absolute> <if-missing>
# The scan runs in a container that sees only the workspace, so a path outside it does not exist there
# and the engine would quietly behave as if the input were never set. Accepted paths are added to ARGS;
# anything else warns, adds nothing and returns 1. Never fails the build.
workspace_path_arg() {
  case "$3" in
    /*) echo "::warning::$1 must be a path inside the workspace, not an absolute path ($3). $4"
        return 1 ;;
  esac
  if [ -e "${GITHUB_WORKSPACE}/$3" ]; then
    ARGS+=("$2" "$3")
    return 0
  fi
  echo "::warning::$5"
  return 1
}

# What to scan: one file, a list, or discovery under the workspace. Also settles OUTPUT_DIR and ROOT,
# which default to the workspace so artifacts are easy to upload as build artifacts.
build_target_args() {
  OUTPUT_DIR="${INPUT_OUTPUT_DIR}"
  OUTPUT_DIR="${OUTPUT_DIR:-${GITHUB_WORKSPACE}}"
  ROOT="${INPUT_ROOT}"
  ROOT="${ROOT:-${GITHUB_WORKSPACE}}"

  ARGS=("scan")

  FILE="${INPUT_FILE}"
  FILES="${INPUT_FILES}"

  if [ -n "$FILE" ] && [ -n "$FILES" ]; then
    echo "::error::depproof-action: 'file' and 'files' are mutually exclusive"; exit 2
  fi

  if [ -n "$FILE" ]; then
    ARGS+=("/workspace/$FILE")
  elif [ -n "$FILES" ]; then
    # Newline- or comma-separated; each entry trimmed, empty ones dropped.
    mapfile -t EXTRA < <(echo "$FILES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' | sed 's|^|/workspace/|')
    ARGS=("scan" "${EXTRA[@]}")
  else
    # Default: discovery mode.
    ARGS+=("--discover" "--root" "/workspace")
  fi
}

# The CI gate. Rules are OR-ed by the engine; fail-only-if-fix-available narrows all of them.
build_gate_args() {
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
}

# The LOADED axis. A side input: absent, nothing about this scan changes.
#
# Validated HERE rather than passed through blind, unlike --ignore-scope and --internal, because the
# failure is invisible at the other end. The workspace is mounted at /workspace, so a path outside it
# simply does not exist in the container: the engine would find no trace, turn the axis off, and
# produce a scan that looks exactly like one where the user never asked for it. A wrong scope word is
# a loud usage error; a wrong path here is silence.
#
# The missing-path warning is explicit, because "I set usage-from and got no usage output" is otherwise
# an unanswerable question. The most common cause is a test step that wrote no trace.
build_usage_args() {
  if [ -n "${INPUT_USAGE_FROM}" ] && workspace_path_arg usage-from --usage-from "${INPUT_USAGE_FROM}" \
       "The scan runs in a container where that path does not exist; the usage axis is OFF for this run." \
       "usage-from path '${INPUT_USAGE_FROM}' does not exist in the workspace. Did the test step run, and did it write the trace there? The usage axis is OFF for this run; the scan itself is unaffected."; then
    USAGE_ON=1
  fi

  # usage-tests and usage-run describe the trace above, so they mean nothing without it: passed only
  # when usage-from was accepted. Both are evidence, like the trace — neither can change the verdict.
  #
  # usage-tests: the JUnit XML reports (a file or a directory) from the SAME test run, so the LOADED
  # coverage line can say how much of the suite ran instead of "tests=unknown". Same path rules as
  # usage-from: inside the workspace, and a wrong path warns rather than fails.
  if [ -n "${INPUT_USAGE_TESTS:-}" ]; then
    if [ "${USAGE_ON:-0}" != "1" ]; then
      echo "::warning::usage-tests has no effect without a usable usage-from trace; ignored for this run."
    else
      workspace_path_arg usage-tests --usage-tests "${INPUT_USAGE_TESTS}" \
        "Test counts stay unknown for this run." \
        "usage-tests path '${INPUT_USAGE_TESTS}' does not exist in the workspace. Did the test step write JUnit XML there? Test counts stay unknown for this run." \
        || true
    fi
  fi
  # usage-run: what produced the trace — 'tests' (the default) or 'startup' for a repository with no
  # test suite, where the app was started and stopped with the recorder on. Passed through verbatim so
  # the Scanner rejects an unknown value loudly rather than this script dropping it quietly.
  if [ -n "${INPUT_USAGE_RUN:-}" ]; then
    if [ "${USAGE_ON:-0}" = "1" ]; then
      ARGS+=("--usage-run" "${INPUT_USAGE_RUN}")
    else
      echo "::warning::usage-run has no effect without a usable usage-from trace; ignored for this run."
    fi
  fi
}

# The BEHAVIOUR axis.
build_behaviour_args() {
  # fail-on-behaviour is the ONE way BEHAVIOUR can fail a build, off unless asked for. Only `alert`
  # gates; anything else (including the default) passes nothing to the engine, so the axis stays
  # evidence.
  case "$(printf '%s' "${INPUT_FAIL_ON_BEHAVIOUR:-}" | tr '[:upper:]' '[:lower:]')" in
    alert)
      if [ -z "${INPUT_BEHAVIOUR_FROM:-}" ] || [ -z "${INPUT_REPORT_TO:-}" ]; then
        echo "::warning::fail-on-behaviour needs behaviour-from and report-to (the hub decides what is new)." \
             "Not gating on behaviour this run."
      else
        ARGS+=("--fail-on-behaviour" "alert")
      fi
      ;;
  esac

  # behaviour-from: same rules as usage-from — a path INSIDE the workspace, evidence only, and a wrong
  # or empty path warns rather than failing the build. The recorder must have run in the test step and
  # written its output here.
  if [ -n "${INPUT_BEHAVIOUR_FROM}" ]; then
    workspace_path_arg behaviour-from --behaviour-from "${INPUT_BEHAVIOUR_FROM}" \
      "The scan runs in a container where that path does not exist; the BEHAVIOUR axis is OFF for this run." \
      "behaviour-from path '${INPUT_BEHAVIOUR_FROM}' does not exist in the workspace. Did the test step run with the recorder, and did it write here? The BEHAVIOUR axis is OFF for this run; the scan itself is unaffected." \
      || true
  fi
}

# The baseline, internal packages, and what the engine writes where.
build_output_args() {
  # The committed baseline. Same absolute-path trap as usage-from, and a worse failure mode if it is
  # missed: a baseline that silently does not load means the backlog fails the build again, and the
  # obvious conclusion is "the baseline does not work" rather than "the path was wrong".
  if [ -n "${INPUT_BASELINE}" ]; then
    workspace_path_arg baseline --baseline "${INPUT_BASELINE}" \
      "The scan runs in a container where that path does not exist; the baseline is NOT applied and pre-existing findings will fail the build." \
      "baseline file '${INPUT_BASELINE}' does not exist in the workspace. It is NOT applied, so findings that predate it will fail the build. Did you commit the file produced by write-baseline?" \
      || true
  fi
  # Your own packages on a private registry. Passed verbatim like --ignore-scope: the engine owns glob
  # validation, and a pattern silently dropped here would leave a caller believing their internal
  # libraries are declared when they are being screened against a public registry and reported clean.
  if [ -n "${INPUT_INTERNAL}" ]; then
    ARGS+=("--internal" "${INPUT_INTERNAL}")
  fi
  OUTPUT_DIR_IN_CONTAINER="/workspace/$(realpath --relative-to="$GITHUB_WORKSPACE" "$OUTPUT_DIR" 2>/dev/null || echo .)"
  ARGS+=("--output-dir" "$OUTPUT_DIR_IN_CONTAINER")
  if [ "${INPUT_WRITE_BASELINE}" = "true" ]; then
    # Beside the other artifacts, so the upload step the user already has carries it out. An
    # ABSOLUTE container path, not a relative one: the container runs with -w /workspace, so a bare
    # filename would land at the repository root instead and miss an upload scoped to output-dir.
    # It suppresses nothing on the run that writes it.
    ARGS+=("--write-baseline" "$OUTPUT_DIR_IN_CONTAINER/depproof-baseline.json")
  fi

  EXCLUDE="${INPUT_EXCLUDE}"
  if [ -n "$EXCLUDE" ]; then
    ARGS+=("--exclude" "$EXCLUDE")
  fi

  if [ "${INPUT_SARIF}" = "true" ]; then
    ARGS+=("--sarif")
  fi
  if [ "${INPUT_HTML}" = "true" ]; then
    ARGS+=("--html")
  fi

  # Ask the engine for the markdown summary when either surface will show it. The engine renders it,
  # not this Action: it is the component that knows the gate decision with waivers applied, and the
  # result is a file any CI can display.
  if [ "${INPUT_JOB_SUMMARY}" = "true" ] || [ "${INPUT_PR_COMMENT}" != "false" ]; then
    ARGS+=("--markdown")
  fi
}

# Gates that read what the hub calls arranged, so they are built after them.
build_dependent_gate_args() {
  # Coverage gating needs no hub and no enrichment — it is a fact about the manifest the scan just
  # read, so it is passed through unconditionally and the engine rejects an unrecognised value as a
  # usage error rather than ignoring it.
  if [ -n "${INPUT_REQUIRE_FIDELITY}" ] && [ "${INPUT_REQUIRE_FIDELITY}" != "off" ]; then
    ARGS+=("--require-fidelity=${INPUT_REQUIRE_FIDELITY}")
  fi

  # Source reachability. Passed ONLY when a value was stated: the flag is tri-state in the engine,
  # where "unstated" means "follow the findings gate" and is not the same as "off". Sending off for a
  # blank input would silently disable a control nobody switched off.
  #
  # Precedence: this repository's own input wins over the org policy. A repo may opt into something
  # STRICTER than the org requires; it can never talk itself down, because the org value only reaches
  # ORG_REQUIRE_ENRICHMENT when the hub said ENFORCE.
  REQUIRE_ENRICHMENT="${INPUT_REQUIRE_ENRICHMENT:-}"
  if [ -z "$REQUIRE_ENRICHMENT" ] && [ -n "${ORG_REQUIRE_ENRICHMENT:-}" ]; then
    REQUIRE_ENRICHMENT="${ORG_REQUIRE_ENRICHMENT}"
    echo "depproof-action: applying org policy require-enrichment=${REQUIRE_ENRICHMENT}"
  fi
  if [ -n "$REQUIRE_ENRICHMENT" ]; then
    ARGS+=("--require-enrichment=${REQUIRE_ENRICHMENT}")
  fi

  # Exploitation gating. Only passed when enrichment was actually arranged: the engine rejects these
  # flags without a source, so passing them after a failed fetch would turn a hub outage into a usage
  # error (exit 2) instead of a scan that simply could not check.
  if [ "${INPUT_FAIL_ON_KEV}" = "true" ]; then
    if [ "${ENRICH_APPLIED:-0}" = "1" ]; then
      ARGS+=("--fail-on-kev")
    else
      echo "::warning::depproof-action: fail-on-kev needs enrich-online with a reachable hub — not gating on exploitation this run."
    fi
  fi

  # EPSS needs targeted mode specifically: the bulk catalogue carries KEV only, so a bulk run would
  # pass the flag against data that can never contain a score, and every finding would silently fail
  # to match.
  if [ -n "${INPUT_FAIL_ON_EPSS}" ]; then
    if [ "${ENRICH_APPLIED:-0}" != "1" ]; then
      echo "::warning::depproof-action: fail-on-epss needs enrich-online with a reachable hub — not gating on EPSS this run."
    elif [ "${INPUT_ENRICH_MODE:-bulk}" != "targeted" ]; then
      echo "::warning::depproof-action: fail-on-epss requires enrich-mode 'targeted' (bulk carries KEV only) — not gating on EPSS this run."
    else
      ARGS+=("--fail-on-epss" "${INPUT_FAIL_ON_EPSS}")
    fi
  fi
}
