#!/usr/bin/env bash
# Turn a scan's unreachable vulnerability sources into a GitHub annotation, on stdout.
#
# Sibling of coverage_annotation.sh, and the distinction between them is the whole point. Coverage
# says "the findings are drawn from part of your graph". This says "the findings are drawn from no
# screen at all" — the graph may be perfect and the count still means nothing, because the question
# was never asked. A zero from a blocked source and a zero from a clean project are the same two
# characters on the run page, and that is exactly what ADR-0013 exists to separate.
#
# `::error::` for a structural block, `::warning::` for a transient one, and the split is deliberate:
# a proxy denying egress will still be denying it tomorrow, while a rate limit clears on its own.
# Telling someone to re-run a firewall rule wastes their afternoon and teaches them to ignore the
# next annotation.
#
# Read from depproof-summary.json, never from stdout — same reason as the coverage script: the JSON
# has `enrichmentReach`, `enrichmentReachReported` and `uncheckedSubjects` and is additive-only,
# while stdout is prose that changes when the prose improves.
#
# Best-effort by construction: no summary, no python3, unreadable JSON — print nothing, exit 0. The
# engine's exit code is what fails a build; a missing annotation is a display gap, and a failure here
# would be this script changing a verdict it has no business changing.
#
# Usage: sources_annotation.sh <depproof-summary.json path>
set -uo pipefail

SUMMARY_JSON="${1:?path to depproof-summary.json required}"

[ -s "$SUMMARY_JSON" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$SUMMARY_JSON" <<'PY' || exit 0
import json, sys

try:
    with open(sys.argv[1]) as fh:
        summary = json.load(fh)
    manifests = summary.get("manifests") or []
except Exception:
    sys.exit(0)

# `enrichmentReachReported` has to be PRESENT and true. This Action ships on a rolling @v1 tag while
# the engine ships as an image, so a runner can pair a new Action with an older engine — and that
# engine defaults enrichmentReach to REACHED simply so its payload parses. Treating the default as
# an assertion would print "all sources reached" for a scanner that never checked, which is the
# precise failure this annotation was added to prevent, reintroduced by version skew.
reporting = [m for m in manifests if m.get("enrichmentReachReported")]
if not reporting:
    sys.exit(0)

blocked = [m for m in reporting if m.get("enrichmentReach") == "BLOCKED"]
degraded = [m for m in reporting if m.get("enrichmentReach") == "DEGRADED"]
if not blocked and not degraded:
    sys.exit(0)

PATH_LIMIT = 5   # matches the engine's cap on the same list, so the two surfaces agree


def named(manifests_subset):
    paths = [m.get("path", "?") for m in manifests_subset]
    shown = ", ".join(paths[:PATH_LIMIT])
    if len(paths) > PATH_LIMIT:
        shown += f" (+{len(paths) - PATH_LIMIT} more)"
    return shown


def subjects(manifests_subset):
    return sum(len(m.get("uncheckedSubjects") or []) for m in manifests_subset)


# Structural first and on its own line: it is the one that means the number below it is not a result.
if blocked:
    parts = [
        f"{len(blocked)} of {len(reporting)} manifest(s) could not be screened for vulnerabilities "
        f"({subjects(blocked)} component(s) never checked): {named(blocked)}.",
        "The findings count is not a clean result — it is an unasked question.",
    ]
    # One remedy, and only when every blocked manifest shares it. Two different fixes in a one-line
    # annotation is a puzzle rather than an instruction.
    fixes = {m.get("enrichmentRemediation") for m in blocked if m.get("enrichmentRemediation")}
    if len(fixes) == 1:
        parts.append(fixes.pop())
    print(f"::error::depproof: {' '.join(parts)}")

if degraded:
    # Never an error. Retries already ran inside the engine, and waiting is the correct response —
    # but the number is a floor and the reader has to know that before acting on it.
    print(
        f"::warning::depproof: a vulnerability source degraded after retries — "
        f"{subjects(degraded)} item(s) went unchecked across {len(degraded)} manifest(s): "
        f"{named(degraded)}. The findings count is a lower bound; re-running may raise it."
    )
PY
