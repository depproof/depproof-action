#!/usr/bin/env bash
# Read one field out of the hub's /api/v1/policy response, on stdout. Empty output means "not set".
#
# A script rather than an inline expression for two reasons. A multi-line parser cannot live inside a
# YAML block scalar without its own indentation becoming Python's indentation, and — the real one —
# this field is legitimately JSON `null`. Any grep or sed that cannot tell `null` from the string
# "null" would turn "the org stated nothing" into a flag value, and the engine rejects an
# unrecognised --require-enrichment as a usage error. A policy fetch must never be able to fail a
# build by succeeding.
#
# Best-effort by construction: unreadable file, no python3, unexpected shape — print nothing, exit 0.
# The caller treats empty as "no org policy", which falls back to the scanner's own defaults, and
# those are already the strict ones.
#
# Usage: read_policy.sh <policy.json> <apply.requireEnrichment|policy.mode>
set -uo pipefail

FILE="${1:?policy json path required}"
FIELD="${2:?dotted field required}"

[ -s "$FILE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$FILE" "$FIELD" <<'PY' || exit 0
import json, sys

try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception:
    sys.exit(0)

node = doc
for part in sys.argv[2].split("."):
    if not isinstance(node, dict):
        sys.exit(0)
    node = node.get(part)

# Only a string is a value. null, numbers and objects all mean "nothing usable here", and printing
# any of them would hand the engine a flag it will reject.
if isinstance(node, str) and node.strip():
    print(node.strip())
PY
