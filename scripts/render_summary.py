#!/usr/bin/env python3
"""Render a depproof scan into GitHub-flavoured markdown.

Two consumers, one renderer: the job summary ($GITHUB_STEP_SUMMARY, always available, no
permissions) and the PR comment (needs pull-requests: write). They differ only in length.

Why this exists: the action writes SBOMs and an HTML report into the workspace and the job ends.
Unless the consumer wires up upload-artifact themselves, all of it is discarded when the runner is
torn down — so the findings a scan worked to produce are invisible at the moment someone would act
on them.

Input is the engine's own output, unmodified:
  - depproof-summary.json — verdict, totals, per-manifest rollup, parse errors, provenance
  - the per-manifest CycloneDX SBOMs it names — per-finding detail (the summary stays lean on disk
    and carries no `findings` block; that is only populated for the hub-push wire payload)

The exit code is the authority on the verdict, NOT summary["fail"] — see verdict().
"""
from __future__ import annotations

import argparse
import json
import os
import sys

SEVERITY_RANK = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "UNKNOWN": 4, "NONE": 4}
SEVERITY_ICON = {"CRITICAL": "🔴", "HIGH": "🟠", "MEDIUM": "🟡", "LOW": "⚪"}

# Job summaries are capped at 1 MiB by GitHub; a PR comment at 65,536 characters. Neither is
# reachable with these limits, which are set for readability rather than to avoid the ceiling.
LIMITS = {"summary": 25, "comment": 10}

MARKER = "<!-- depproof-action -->"


def pretty_epss(score: float) -> str:
    pct = score * 100
    if pct >= 99.95:
        return ">99.9%"
    if 0.0 < pct < 0.01:
        return "<0.01%"
    return f"{pct:.2f}%"


def pretty_component(purl: str) -> str:
    """pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1 -> org.apache.logging.log4j:log4j-core 2.14.1"""
    if not purl:
        return "—"
    s = purl.split("?")[0]
    if s.startswith("pkg:"):
        s = s.split("/", 1)[-1] if "/" in s else s[4:]
    name, _, version = s.rpartition("@")
    if not name:
        name, version = s, ""
    return f"{name.replace('/', ':')}{' ' + version if version else ''}"


def load_findings(out_dir: str, summary: dict) -> list[dict]:
    """Per-finding detail, read from the CycloneDX SBOMs the summary names."""
    findings = []
    for manifest in summary.get("manifests", []):
        sbom_path = os.path.join(out_dir, manifest.get("sbomFile", ""))
        try:
            with open(sbom_path) as fh:
                sbom = json.load(fh)
        except (OSError, ValueError):
            continue  # a missing or malformed SBOM must not cost us the whole summary
        for vuln in sbom.get("vulnerabilities", []):
            ratings = vuln.get("ratings") or [{}]
            props = {p.get("name"): p.get("value") for p in vuln.get("properties", [])}
            affects = vuln.get("affects") or [{}]
            epss_raw = props.get("depproof:epss")
            findings.append({
                "manifest": manifest.get("path", "?"),
                "id": vuln.get("id", "?"),
                "severity": (ratings[0].get("severity") or "unknown").upper(),
                "cvss": ratings[0].get("score"),
                "component": pretty_component(affects[0].get("ref", "")),
                "fix": props.get("depproof:fixVersion") or vuln.get("recommendation") or "",
                "kev": props.get("depproof:kev") == "true",
                "epss": float(epss_raw) if epss_raw not in (None, "") else None,
            })
    findings.sort(key=lambda f: (
        not f["kev"],                                   # known-exploited first, always
        SEVERITY_RANK.get(f["severity"], 9),
        -(f["cvss"] or 0),
        -(f["epss"] or 0),
    ))
    return findings


def verdict(exit_code: int, summary: dict) -> tuple[str, str]:
    """Headline and explanation, keyed on the EXIT CODE rather than summary["fail"].

    They can disagree, legitimately: summary["fail"] is evaluated without the waiver set, so a
    centrally-waived finding leaves fail=true on disk while the build exits 0. Rendering the file's
    verdict would contradict the green check right next to it. The file is the detail; the exit code
    is the verdict.

    Codes 2/3/4 are not findings failures and must not be shown as though a vulnerability broke the
    build — that is the whole reason the engine spends distinct codes on them.
    """
    reason = summary.get("failReason")
    return {
        0: ("✅ Passed", "No finding tripped the gate."),
        1: ("❌ Failed", reason or "A finding tripped the gate."),
        2: ("⚠️ Scan error", "depproof could not complete the scan — this is not a findings result."),
        3: ("⚠️ Report not delivered", "The scan ran, but the report could not be pushed to the hub."),
        4: ("⚠️ No verdict", "A gate rule depends on exploitation data the hub could not supply, "
                             "so depproof refused to report a verdict rather than guess."),
    }.get(exit_code, (f"⚠️ Exit {exit_code}", "Unrecognised exit code."))


def render(summary: dict, findings: list[dict], exit_code: int, mode: str, run_url: str | None) -> str:
    head, explanation = verdict(exit_code, summary)
    totals = summary.get("totals", {})
    out: list[str] = []

    if mode == "comment":
        out.append(MARKER)
    out.append(f"## depproof — {head}\n")
    out.append(f"{explanation}\n")

    # A gate that matched but was waived: say so, or the numbers below look like they contradict
    # the green check.
    if exit_code == 0 and summary.get("fail"):
        out.append("> Findings matched the gate but are covered by active waivers, so the build "
                   "passed. The counts below are unsuppressed.\n")

    counts = " · ".join(
        f"**{totals.get(k, 0)}** {k}" for k in ("critical", "high", "medium", "low")
        if totals.get(k, 0)
    ) or "no vulnerabilities found"
    out.append(f"{counts}\n")

    limit = LIMITS[mode]
    if findings:
        shown = findings[:limit]
        # The CycloneDX SBOM carries no fix version today (the engine has it, but only emits it to
        # stdout and the hub payload), so the column is conditional rather than a row of dashes. It
        # lights up on its own once the SBOM carries `recommendation`.
        with_fix = any(f["fix"] for f in shown)
        fix_head, fix_sep = ("Fix | ", "---|") if with_fix else ("", "")
        out.append(f"| | Advisory | Component | {fix_head}Exploitation |")
        out.append(f"|---|---|---|{fix_sep}---|")
        for f in shown:
            icon = SEVERITY_ICON.get(f["severity"], "⚪")
            cvss = f" {f['cvss']}" if f.get("cvss") is not None else ""
            exploit = []
            if f["kev"]:
                exploit.append("**KEV**")
            if f["epss"] is not None:
                exploit.append(f"EPSS {pretty_epss(f['epss'])}")
            fix_cell = f"{f['fix'] or '—'} | " if with_fix else ""
            out.append(
                f"| {icon}{cvss} | `{f['id']}` | {f['component']} | "
                f"{fix_cell}{' · '.join(exploit) or '—'} |"
            )
        if len(findings) > limit:
            rest = len(findings) - limit
            where = "the job summary" if mode == "comment" else "the HTML report"
            out.append(f"\n_…and {rest} more — see {where}._")
        out.append("")

    manifests = summary.get("manifests", [])
    if len(manifests) > 1 and mode == "summary":
        out.append("<details><summary>Per-manifest breakdown</summary>\n")
        out.append("| Manifest | Ecosystem | Components | Critical | High | Medium | Low |")
        out.append("|---|---|---|---|---|---|---|")
        for m in manifests:
            v = m.get("vulns", {})
            out.append(
                f"| `{m.get('path')}` | {m.get('ecosystem', '?')} | {m.get('components', 0)} | "
                f"{v.get('critical', 0)} | {v.get('high', 0)} | {v.get('medium', 0)} | {v.get('low', 0)} |"
            )
        out.append("\n</details>\n")

    errors = summary.get("parseErrors") or []
    if errors:
        out.append(f"**{len(errors)} manifest(s) could not be scanned** — "
                   "these are unscanned, not clean:\n")
        for e in errors[:5]:
            out.append(f"- `{e.get('path', '?')}` — {e.get('error', 'unknown error')}")
        out.append("")

    # Provenance last: absent means the scan was never enriched, which is materially different from
    # "checked and found nothing exploited", and the footer is where that distinction belongs.
    enrichment = summary.get("enrichment")
    bits = [f"depproof {summary.get('depproofVersion', '?')}"]
    if enrichment:
        bits.append(f"enrichment `{enrichment.get('snapshotId')}`")
        degraded = [k for k, v in (enrichment.get("providers") or {}).items() if v != "ok"]
        if degraded:
            bits.append(f"⚠️ degraded: {', '.join(degraded)}")
    else:
        bits.append("no enrichment applied (KEV/EPSS not checked)")
    if run_url and mode == "comment":
        bits.append(f"[run]({run_url})")
    out.append(f"<sub>{' · '.join(bits)}</sub>")

    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary-file", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--exit-code", type=int, required=True)
    ap.add_argument("--mode", choices=["summary", "comment"], default="summary")
    ap.add_argument("--run-url", default=None)
    args = ap.parse_args()

    try:
        with open(args.summary_file) as fh:
            summary = json.load(fh)
    except (OSError, ValueError) as e:
        # No summary means the scan died before writing one. Say that plainly rather than
        # rendering an empty table that reads like a clean result.
        head, explanation = verdict(args.exit_code, {})
        print(f"## depproof — {head}\n\n{explanation}\n\n"
              f"<sub>No scan summary was produced ({e.__class__.__name__}).</sub>")
        return 0

    findings = load_findings(args.out_dir, summary)
    print(render(summary, findings, args.exit_code, args.mode, args.run_url))
    return 0


if __name__ == "__main__":
    sys.exit(main())
