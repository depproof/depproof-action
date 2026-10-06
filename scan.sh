#!/usr/bin/env bash
# The body of the composite action. The steps live in scripts/scan_*.sh; this file only orders them.
#
# WHY A FILE RATHER THAN INLINE IN action.yml. GitHub compiles a `run:` block that contains ${{ }}
# expressions as a single template expression, and caps that at 21,000 characters; a body past the cap
# makes the action fail to compile with "The template is not valid" before any line executes. A script
# file is not a template and has no such limit, so growth cannot cause that failure.
#
# Keep it that way: no ${{ }} here or in the sourced files. Inputs arrive as the INPUT_* environment
# variables action.yml exports, and the action's own directory as ACTION_PATH. An input referenced here
# but not exported there reads as EMPTY, silently -- tests/test_action_template.sh checks both
# directions.
#
# The order of the calls below is the order of the engine's arguments and of every message the step
# prints, so a new step goes where its output belongs, not at the end.

# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCAN_LIB="$(dirname "${BASH_SOURCE[0]}")/scripts"
# shellcheck source=scripts/scan_cleanup.sh
. "${SCAN_LIB}/scan_cleanup.sh"
# shellcheck source=scripts/scan_args.sh
. "${SCAN_LIB}/scan_args.sh"
# shellcheck source=scripts/scan_hub.sh
. "${SCAN_LIB}/scan_hub.sh"
# shellcheck source=scripts/scan_go.sh
. "${SCAN_LIB}/scan_go.sh"
# shellcheck source=scripts/scan_run.sh
. "${SCAN_LIB}/scan_run.sh"
# shellcheck source=scripts/scan_publish.sh
. "${SCAN_LIB}/scan_publish.sh"

install_cleanup_trap

# The engine's command line, from the inputs.
build_target_args
build_gate_args
build_usage_args
build_behaviour_args
build_output_args
build_report_args

# Work on the runner before the scan: resolve Go modules, then whatever the hub supplies.
resolve_go_modules
fetch_hub_policy
fetch_hub_waivers
build_hub_source_args
arrange_hub_enrichment
build_dependent_gate_args

run_scanner
attach_release_sbom

publish_annotations
publish_job_summary
publish_pr_comment
publish_sarif

exit $DEPPROOF_EXIT
