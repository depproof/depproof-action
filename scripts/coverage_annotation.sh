#!/usr/bin/env bash
# Turn the scan's coverage gaps into a GitHub `::warning::` annotation, on stdout.
#
# The engine already renders a coverage caveat into depproof-summary.md, which becomes the job
# summary and the PR comment. Both are pages someone has to open. An annotation is the one surface
# that appears on the run page itself, beside the step — which is where a green build gets its
# single glance, and a green build over an unresolved graph is exactly what this warns about.
#
# Read from depproof-summary.json, never from stdout. The engine's stdout wording is prose for a
# human and changes when the prose improves; the JSON has the fields — `fidelity`, `superseded`,
# `fidelityRemediation` — and is an additive-only wire format. Grepping the log would have coupled
# this Action to sentences.
#
# `superseded` is why this is a filter and not a judgement: a package.json beside its lockfile is
# DECLARED_ONLY and completely fine, and the engine says so per manifest. Without that field this
# script would have to re-derive the rule from paths — a third copy of it, after the engine's and
# the hub's — and the failure mode of a drifting copy is warning about manifests that are fine,
# which is how an advisory gets muted before the day it matters.
#
# Best-effort by construction: no summary, no python3, unreadable JSON — print nothing, exit 0. A
# missing annotation is a display gap; a failed step here would be this script changing a verdict
# it has no business changing.
#
# Usage: coverage_annotation.sh <depproof-summary.json path> [require-fidelity value]
set -uo pipefail

SUMMARY_JSON="${1:?path to depproof-summary.json required}"
REQUIRE_FIDELITY="${2:-}"   # the action's input, so the advice is not "set a flag you have set"

[ -s "$SUMMARY_JSON" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

REQUIRE_FIDELITY="$REQUIRE_FIDELITY" python3 - "$SUMMARY_JSON" <<'PY' || exit 0
import json, os, sys

try:
    with open(sys.argv[1]) as fh:
        summary = json.load(fh)
    manifests = summary.get("manifests") or []
except Exception:
    sys.exit(0)

# A manifest that predates the fidelity fields reports RESOLVED by default, and `fidelityReported`
# is how we tell "looked and found everything" from "this engine never looked". Say nothing about a
# scan that never made the claim, rather than inventing a clean bill of health or a false alarm.
#
# `superseded` has to be PRESENT, not merely falsy. This Action ships on a rolling `@v1` tag while
# the engine ships as an image, so a runner can pair a new Action with an older engine — and an
# engine that never stated supersession cannot be filtered honestly. Deriving it here from the paths
# instead would be a third copy of that rule; annotating without it would name every package.json
# that sits beside its own lockfile. Staying quiet costs a display surface for one image bump and
# never claims something is fine when it is not.
if not all("superseded" in m for m in manifests):
    sys.exit(0)

gaps = [
    m for m in manifests
    if m.get("fidelityReported") and m.get("fidelity", "RESOLVED") != "RESOLVED" and not m["superseded"]
]
if not gaps:
    sys.exit(0)

# Grouped by level, worst first, so the count that matters leads. DECLARED_ONLY is the one that can
# hide dependencies entirely; PARTIAL names what it missed.
order = {"DECLARED_ONLY": 0, "PARTIAL": 1}
levels = sorted({m.get("fidelity") for m in gaps}, key=lambda l: order.get(l, 9))
counts = ", ".join(f"{sum(1 for m in gaps if m.get('fidelity') == l)} x {l}" for l in levels)

PATH_LIMIT = 5   # matches the engine's cap on the same list, so the two surfaces agree
paths = [m.get("path", "?") for m in gaps]
shown = ", ".join(paths[:PATH_LIMIT])
if len(paths) > PATH_LIMIT:
    shown += f" (+{len(paths) - PATH_LIMIT} more)"

parts = [
    f"{len(gaps)} of {len(manifests)} manifest(s) were not read as a resolved graph ({counts}): {shown}.",
    "The findings are what depproof could see, not everything your build has.",
]

# One remedy, and only when every gap shares it. Two different fixes in a one-line annotation is a
# sentence nobody can act on; the summary lists them per group, which is what it is for.
remedies = {m.get("fidelityRemediation") for m in gaps if m.get("fidelityRemediation")}
if len(remedies) == 1:
    parts.append("Fix: " + remedies.pop())
else:
    parts.append("See the job summary for the fix for each.")

if not os.environ.get("REQUIRE_FIDELITY") or os.environ["REQUIRE_FIDELITY"] == "off":
    parts.append("Set require-fidelity to fail the build on this instead of warning.")

# GitHub reads the annotation as a workflow command: %, CR and LF have to be escaped or the message
# is truncated at the first newline and any literal % eats the next two characters.
message = " ".join(parts).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print(f"::warning title=depproof coverage::{message}")
PY
