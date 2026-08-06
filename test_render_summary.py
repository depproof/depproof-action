#!/usr/bin/env python3
"""Tests for the summary renderer.

The failure mode that matters here is not a crash — it is confidently rendering something wrong.
A summary that says "Passed" on a broken scan, or shows "0%" for a real EPSS score, is worse than
no summary at all, because a green wall is exactly what people stop reading.

Run: python3 test_render_summary.py
"""
import json
import os
import tempfile
import unittest

from render_summary import load_findings, pretty_component, pretty_epss, render, verdict

SBOM = {
    "vulnerabilities": [
        {"id": "CVE-LOW-BUT-EXPLOITED", "ratings": [{"severity": "medium", "score": 5.3}],
         "affects": [{"ref": "pkg:maven/g/a@1.0"}],
         "properties": [{"name": "depproof:kev", "value": "true"},
                        {"name": "depproof:epss", "value": "0.97"}]},
        {"id": "CVE-CRITICAL", "ratings": [{"severity": "critical", "score": 9.8}],
         "affects": [{"ref": "pkg:maven/g/b@2.0"}], "properties": []},
    ]
}

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


class Verdict(unittest.TestCase):
    def test_each_exit_code_reads_as_what_it_means(self):
        # 2/3/4 are infrastructure, not findings. Showing them as "Failed" would tell a developer
        # they have a vulnerability when they have an outage.
        self.assertIn("Passed", verdict(0, {})[0])
        self.assertIn("Failed", verdict(1, {})[0])
        self.assertIn("Scan error", verdict(2, {})[0])
        self.assertIn("Report not delivered", verdict(3, {})[0])
        self.assertIn("No verdict", verdict(4, {})[0])

    def test_failure_names_the_rule_that_fired(self):
        self.assertIn("severity>=critical", verdict(1, SUMMARY)[1])

    def test_unknown_exit_code_is_not_silently_a_pass(self):
        head, _ = verdict(99, {})
        self.assertNotIn("Passed", head)


class Rendering(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        with open(os.path.join(self.dir, "sbom.json"), "w") as fh:
            json.dump(SBOM, fh)
        self.findings = load_findings(self.dir, SUMMARY)

    def test_known_exploited_outranks_a_higher_cvss(self):
        # The entire prioritisation argument in one assertion: a medium being exploited today is
        # more urgent than a critical nobody is attacking. Ordering by severity would invert it.
        self.assertEqual("CVE-LOW-BUT-EXPLOITED", self.findings[0]["id"])
        self.assertTrue(self.findings[0]["kev"])

    def test_a_waived_pass_explains_why_the_counts_disagree_with_the_check(self):
        # summary["fail"] is computed WITHOUT waivers, so it stays true while the build exits 0.
        # Rendering "Failed" here would contradict the green check beside it.
        out = render(SUMMARY, self.findings, 0, "summary", None)
        self.assertIn("Passed", out)
        self.assertIn("covered by active waivers", out)

    def test_no_waiver_note_when_nothing_was_waived(self):
        clean = dict(SUMMARY, fail=False)
        self.assertNotIn("waivers", render(clean, [], 0, "summary", None))

    def test_unenriched_scan_says_so_rather_than_implying_it_was_checked(self):
        # "no KEV findings" and "KEV was never checked" must not look identical.
        bare = {k: v for k, v in SUMMARY.items() if k != "enrichment"}
        self.assertIn("no enrichment applied", render(bare, [], 0, "summary", None))

    def test_degraded_provider_is_surfaced(self):
        degraded = dict(SUMMARY, enrichment={"snapshotId": "s", "providers": {"epss": "degraded"}})
        self.assertIn("degraded", render(degraded, [], 0, "summary", None))

    def test_parse_errors_are_not_reported_as_clean(self):
        broken = dict(SUMMARY, parseErrors=[{"path": "bad/pom.xml", "error": "malformed"}])
        out = render(broken, [], 0, "summary", None)
        self.assertIn("could not be scanned", out)
        self.assertIn("bad/pom.xml", out)

    def test_fix_column_is_absent_until_the_sbom_carries_one(self):
        out = render(SUMMARY, self.findings, 1, "summary", None)
        self.assertNotIn("Fix", out)
        withfix = [dict(f, fix="2.15.0") for f in self.findings]
        self.assertIn("Fix", render(SUMMARY, withfix, 1, "summary", None))

    def test_comment_carries_the_marker_and_the_summary_does_not(self):
        # The marker is what makes the comment update in place instead of accumulating.
        self.assertIn("<!-- depproof-action -->", render(SUMMARY, self.findings, 1, "comment", None))
        self.assertNotIn("<!-- depproof-action -->", render(SUMMARY, self.findings, 1, "summary", None))

    def test_missing_sbom_costs_detail_but_not_the_summary(self):
        self.assertEqual([], load_findings("/nonexistent", SUMMARY))
        self.assertIn("Failed", render(SUMMARY, [], 1, "summary", None))


class Formatting(unittest.TestCase):
    def test_epss_extremes_report_as_bounds(self):
        # Matches HtmlReport.epssPercent (engine) and Epss.percent (hub). "100%" claims a certainty
        # no model asserts; "0%" reads as no-risk for a real score.
        self.assertEqual(">99.9%", pretty_epss(0.99999))
        self.assertEqual("<0.01%", pretty_epss(0.00001))
        self.assertEqual("97.00%", pretty_epss(0.97))
        self.assertEqual("0.00%", pretty_epss(0.0))

    def test_purls_render_as_coordinates(self):
        self.assertEqual("org.apache.logging.log4j:log4j-core 2.14.1",
                         pretty_component("pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1"))
        self.assertEqual("lodash 4.17.11", pretty_component("pkg:npm/lodash@4.17.11"))
        self.assertEqual("—", pretty_component(""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
