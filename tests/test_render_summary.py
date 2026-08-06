#!/usr/bin/env python3
"""Tests for scripts/render_summary.py — what a developer sees after a scan.

Run from the repo root:  python3 -m unittest discover -s tests -v

The failure mode these guard against is not a crash. It is the renderer confidently printing
something *wrong*: a green headline over a broken scan, "0%" for a real exploitation score, or an
empty table where data was simply never collected. A crash gets noticed and fixed. A wrong summary
gets believed, and it is believed at exactly the moment someone is deciding whether to merge.

The classes below are grouped by the property being protected, not by the function under test:

  VerdictSelection      the headline matches the build's real outcome
  AbsenceIsNotSafety    missing / unchecked / unscanned never render as clean
  FindingOrder          the most urgent finding is the one people read first
  CommentIdentity       the PR comment updates in place instead of accumulating
  Formatting            numbers and coordinates are legible and not misleading
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

from render_summary import (  # noqa: E402
    load_findings,
    pretty_component,
    pretty_epss,
    render,
    verdict,
)

# A CycloneDX SBOM as the engine writes it: a medium that is being actively exploited, and a
# critical that is not. The pair exists to make ordering testable — see FindingOrder.
SBOM = {
    "vulnerabilities": [
        {"id": "CVE-MEDIUM-BUT-EXPLOITED", "ratings": [{"severity": "medium", "score": 5.3}],
         "affects": [{"ref": "pkg:maven/g/a@1.0"}],
         "properties": [{"name": "depproof:kev", "value": "true"},
                        {"name": "depproof:epss", "value": "0.97"}]},
        {"id": "CVE-CRITICAL-NOT-EXPLOITED", "ratings": [{"severity": "critical", "score": 9.8}],
         "affects": [{"ref": "pkg:maven/g/b@2.0"}], "properties": []},
    ]
}

# depproof-summary.json as the engine writes it alongside those SBOMs.
SUMMARY = {
    "depproofVersion": "0.1.15", "fail": True,
    "failReason": "gate rule(s) severity>=critical matched in pom.xml",
    "totals": {"critical": 1, "high": 0, "medium": 1, "low": 0},
    "manifests": [{"path": "pom.xml", "ecosystem": "Maven", "components": 2,
                   "vulns": {"critical": 1, "high": 0, "medium": 1, "low": 0},
                   "sbomFile": "sbom.json", "fail": True}],
    "parseErrors": [],
    "enrichment": {"snapshotId": "kev:2026-08-05", "providers": {"kev": "ok"}},
}


class ScanFixture(unittest.TestCase):
    """Writes the SBOM to a temp dir so load_findings reads it the way the action does."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        with open(os.path.join(self.dir, "sbom.json"), "w") as fh:
            json.dump(SBOM, fh)
        self.findings = load_findings(self.dir, SUMMARY)


class VerdictSelection(ScanFixture):
    """The headline must match what actually happened to the build.

    The engine emits TWO signals that legitimately disagree, and picking the wrong one puts a
    contradiction on screen:

      exit code            — the gate WITH waivers applied. This is the build's real outcome.
      summary.json "fail"  — the gate WITHOUT waivers, kept raw so the hub sees unsuppressed truth.

    A centrally-waived finding leaves fail=true on disk while the build exits 0.
    """

    def test_each_exit_code_reads_as_the_thing_it_means(self):
        # 2/3/4 are infrastructure outcomes, not findings. Rendering them as "Failed" tells a
        # developer they have a vulnerability when what they have is an outage — which is the whole
        # reason the engine spends distinct exit codes on them.
        self.assertIn("Passed", verdict(0, {})[0])
        self.assertIn("Failed", verdict(1, {})[0])
        self.assertIn("Scan error", verdict(2, {})[0])
        self.assertIn("Report not delivered", verdict(3, {})[0])
        self.assertIn("No verdict", verdict(4, {})[0])

    def test_a_failure_names_the_rule_that_fired(self):
        # "the gate failed" is not actionable; "severity>=critical fired" tells you what to change.
        self.assertIn("severity>=critical", verdict(1, SUMMARY)[1])

    def test_an_unrecognised_exit_code_is_never_reported_as_a_pass(self):
        # Fail safe: an exit code we do not understand must not default to reassurance.
        self.assertNotIn("Passed", verdict(99, {})[0])

    def test_a_waived_pass_explains_why_the_counts_disagree_with_the_check(self):
        # exit 0 (waiver applied) but summary.fail=true. Rendering the file's verdict would print
        # "Failed" directly beside a green check.
        out = render(SUMMARY, self.findings, 0, "summary", None)
        self.assertIn("Passed", out)
        self.assertIn("covered by active waivers", out)

    def test_no_waiver_note_appears_when_nothing_was_waived(self):
        self.assertNotIn("waivers", render(dict(SUMMARY, fail=False), [], 0, "summary", None))


class AbsenceIsNotSafety(ScanFixture):
    """Not-checked, not-scanned and no-data must never render as clean.

    This is the recurring defect class across the whole product — the same shape as the engine
    recording kev=false for Log4Shell when it meant "not checked", and the hub coercing a null EPSS
    to zero. In a summary it is worse, because a reassuring green block is the thing people stop
    reading.
    """

    def test_an_unenriched_scan_says_so_instead_of_implying_it_was_checked(self):
        # No enrichment means KEV and EPSS were never consulted. "No KEV findings" and "KEV was
        # never checked" must not look identical to the reader.
        bare = {k: v for k, v in SUMMARY.items() if k != "enrichment"}
        self.assertIn("no enrichment applied", render(bare, [], 0, "summary", None))

    def test_a_degraded_provider_is_surfaced_rather_than_swallowed(self):
        # The hub answered but could not supply data. Silently rendering a normal summary would
        # present partial evidence as complete.
        degraded = dict(SUMMARY, enrichment={"snapshotId": "s", "providers": {"epss": "degraded"}})
        self.assertIn("degraded", render(degraded, [], 0, "summary", None))

    def test_unparseable_manifests_are_reported_as_unscanned_not_clean(self):
        broken = dict(SUMMARY, parseErrors=[{"path": "bad/pom.xml", "error": "malformed"}])
        out = render(broken, [], 0, "summary", None)
        self.assertIn("could not be scanned", out)
        self.assertIn("bad/pom.xml", out)

    def test_a_missing_sbom_costs_detail_but_never_the_verdict(self):
        # The detail table degrades; the headline must still tell the truth about the build.
        self.assertEqual([], load_findings("/nonexistent", SUMMARY))
        self.assertIn("Failed", render(SUMMARY, [], 1, "summary", None))


class FindingOrder(ScanFixture):
    """The first row is the one that gets read. It has to be the most urgent one."""

    def test_known_exploited_outranks_a_higher_severity_that_is_not(self):
        # The product's entire prioritisation argument, in one assertion: a medium being exploited
        # today matters more than a critical nobody is attacking. Sorting by severity inverts it.
        # The gate already encodes this (fail-on-kev is not narrowed by fail-only-if-fix-available);
        # the renderer must not contradict the gate.
        self.assertEqual("CVE-MEDIUM-BUT-EXPLOITED", self.findings[0]["id"])
        self.assertTrue(self.findings[0]["kev"])
        self.assertEqual("CVE-CRITICAL-NOT-EXPLOITED", self.findings[1]["id"])

    def test_the_fix_column_is_absent_until_the_sbom_actually_carries_one(self):
        # The CycloneDX SBOM has no fix version today, so a Fix column would be a row of dashes
        # that reads as "no fix exists" rather than "not recorded". It appears on its own once the
        # engine emits it.
        self.assertNotIn("Fix", render(SUMMARY, self.findings, 1, "summary", None))
        withfix = [dict(f, fix="2.15.0") for f in self.findings]
        self.assertIn("Fix", render(SUMMARY, withfix, 1, "summary", None))


class CommentIdentity(ScanFixture):
    """One PR comment, updated per run — not one per push."""

    def test_the_comment_carries_the_marker_and_the_job_summary_does_not(self):
        # The marker is how the action finds its own previous comment to update. Without it every
        # push appends another copy, and depproof becomes the bot everyone mutes.
        self.assertIn("<!-- depproof-action -->", render(SUMMARY, self.findings, 1, "comment", None))
        self.assertNotIn("<!-- depproof-action -->", render(SUMMARY, self.findings, 1, "summary", None))


class Formatting(unittest.TestCase):
    """Numbers that mislead are worse than numbers that are missing."""

    def test_epss_extremes_report_as_bounds_rather_than_rounding_through(self):
        # Mirrors HtmlReport.epssPercent (engine) and Epss.percent (hub) — three renderers, one
        # contract. "100%" claims a certainty no probabilistic model asserts; "0%" reads as no-risk
        # for a finding that has a real score, and EPSS is skewed enough that most CVEs would land
        # in that second bucket and become indistinguishable from having no score at all.
        self.assertEqual(">99.9%", pretty_epss(0.99999))
        self.assertEqual("<0.01%", pretty_epss(0.00001))
        self.assertEqual("97.00%", pretty_epss(0.97))
        self.assertEqual("0.00%", pretty_epss(0.0))

    def test_purls_render_as_the_coordinates_people_recognise(self):
        # Nobody greps their pom.xml for "pkg:maven/...".
        self.assertEqual("org.apache.logging.log4j:log4j-core 2.14.1",
                         pretty_component("pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1"))
        self.assertEqual("lodash 4.17.11", pretty_component("pkg:npm/lodash@4.17.11"))
        self.assertEqual("—", pretty_component(""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
