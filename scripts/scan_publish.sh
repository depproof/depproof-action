# shellcheck shell=bash
# Sourced by scan.sh: puts the finished scan where GitHub shows it — run-page annotations, the job
# summary, a pull request comment and code scanning.
#
# Everything here is best-effort: a rendering or API problem must never change the verdict of a scan
# that already ran. The engine renders the summary and owns every judgement in it — which verdict is
# authoritative, how findings rank, whether absent data reads as clean — because it is where the gate
# decision is made, and so the same summary reaches every CI. This only decides where to put it.

# Coverage and source reachability, on the run page rather than only inside a page someone opens.
publish_annotations() {
  BODY_SH="${ACTION_PATH}/scripts/summary_body.sh"
  SUMMARY_MD="${OUTPUT_DIR}/depproof-summary.md"

  # The engine decides whether there is a coverage gap and what to do about it; this only lifts that
  # decision to the one surface a green build is actually looked at on. Never fails the step — the
  # gate input `require-fidelity` remains the only thing that can fail a build over coverage.
  bash "${ACTION_PATH}/scripts/coverage_annotation.sh" \
    "${OUTPUT_DIR}/depproof-summary.json" "${INPUT_REQUIRE_FIDELITY}" || true

  # Source reachability, for a sharper version of the same reason. A coverage gap means the findings
  # came from part of the graph; an unreached source means they came from no screen at all, and that
  # is indistinguishable from a clean project unless something says so where the green tick is. Never
  # fails the step: the engine already decided the verdict and exited 4 if it mattered.
  bash "${ACTION_PATH}/scripts/sources_annotation.sh" \
    "${OUTPUT_DIR}/depproof-summary.json" || true
}

publish_job_summary() {
  if [ "${INPUT_JOB_SUMMARY}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    bash "$BODY_SH" "$SUMMARY_MD" "$DEPPROOF_EXIT" >> "$GITHUB_STEP_SUMMARY" \
      || echo "::warning::depproof-action: could not write the job summary"
  fi
}

publish_pr_comment() {
  # PR number comes from the event payload; empty for every non-PR trigger, which is what keeps 'auto'
  # from trying to comment on a push or a schedule.
  PR_NUM="$(python3 -c 'import json,os; p=os.environ.get("GITHUB_EVENT_PATH",""); d=json.load(open(p)) if p and os.path.exists(p) else {}; print((d.get("pull_request") or {}).get("number") or "")' 2>/dev/null || true)"

  if [ "${INPUT_PR_COMMENT}" != "false" ] && [ -n "$PR_NUM" ]; then
    BODY="$(mktemp)"
    if bash "$BODY_SH" "$SUMMARY_MD" "$DEPPROOF_EXIT" '<!-- depproof-action -->' \
         "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" > "$BODY"; then
      # One comment per PR, updated in place. Without the marker lookup every push would add another
      # copy, and the action would become the thing everyone mutes.
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
}

# SARIF upload. In this step, before the exit, and not as a second composite step: this runs on a
# FAILING build too, and a failing build is when the alerts matter most. A step placed after the scan
# would be skipped exactly then.
#
# Uploaded through the API rather than github/codeql-action/upload-sarif for the same reason the PR
# comment is: a composite action cannot reliably swallow a failing step, so a missing permission would
# fail somebody's build over an artifact. This warns instead, like the comment does.
#
# GITHUB_SHA and GITHUB_REF are already the right pair on both event types — on pull_request they are
# the merge commit and refs/pull/N/merge, which is what code scanning wants for PR alerts.
publish_sarif() {
  if [ "${INPUT_SARIF}" = "true" ] && [ "${INPUT_SARIF_UPLOAD}" != "false" ]; then
    SARIF_FILE="${OUTPUT_DIR}/depproof.sarif"
    if [ ! -f "$SARIF_FILE" ]; then
      echo "::warning::depproof-action: sarif was requested but $SARIF_FILE was not written."
    else
      SARIF_PAYLOAD="$(mktemp)"
      # Built as a file, not an argv string: the payload is gzipped+base64 SARIF and a large
      # repository's easily runs past the command-line length limit.
      if python3 - "$SARIF_FILE" "$GITHUB_SHA" "$GITHUB_REF" > "$SARIF_PAYLOAD" <<'PY'
import base64, gzip, json, sys
with open(sys.argv[1], "rb") as fh:
    blob = base64.b64encode(gzip.compress(fh.read())).decode()
json.dump({"commit_sha": sys.argv[2], "ref": sys.argv[3], "sarif": blob}, sys.stdout)
PY
      then
        if gh api -X POST "repos/${GITHUB_REPOSITORY}/code-scanning/sarifs" \
             --input "$SARIF_PAYLOAD" >/dev/null 2>&1; then
          echo "depproof-action: SARIF uploaded — findings are in the Security tab."
        else
          echo "::warning::depproof-action: could not upload SARIF — grant 'security-events: write'" \
               "to enable it. depproof.sarif is still in the workspace."
        fi
      else
        echo "::warning::depproof-action: could not package depproof.sarif for upload."
      fi
      rm -f "$SARIF_PAYLOAD"
    fi
  fi
}
