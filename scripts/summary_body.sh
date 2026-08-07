#!/usr/bin/env bash
# Print the scan summary for a CI surface to display, on stdout.
#
# The summary itself is rendered by the ENGINE (`--markdown` writes depproof-summary.md). This script
# exists only for the case the engine cannot cover: the file not being there.
#
# That case matters more than its size suggests. The engine writes the summary once a scan completes,
# so an absent file means the scan did not get that far — bad arguments, an unreadable manifest, a
# crash. Reacting by printing nothing would leave the run page blank, and a blank run page reads as
# "nothing to report", which is the opposite of what happened. Printing a raw `cat: No such file`
# would be noise nobody can act on. So the absence is reported as what it is.
#
# Usage: summary_body.sh <summary.md path> <depproof exit code> [marker] [run-url]
set -euo pipefail

SUMMARY_MD="${1:?path to depproof-summary.md required}"
EXIT_CODE="${2:?depproof exit code required}"
MARKER="${3:-}"     # prepended so the PR comment can find and update itself next run
RUN_URL="${4:-}"    # appended for the PR comment, which is read away from the run page

[ -n "$MARKER" ] && printf '%s\n' "$MARKER"

if [ -s "$SUMMARY_MD" ]; then
  cat "$SUMMARY_MD"
else
  # Deliberately not silent, and deliberately not "passed". Exit 0 here would be odd but is still
  # reported honestly rather than dressed up as a clean run.
  printf '## depproof — ⚠️ No summary produced\n\n'
  printf 'depproof exited %s without writing a summary, so the scan did not complete. ' "$EXIT_CODE"
  printf 'This is not a clean result — check the step log above.\n'
fi

[ -n "$RUN_URL" ] && printf '\n<sub><a href="%s">workflow run</a></sub>\n' "$RUN_URL"

exit 0
