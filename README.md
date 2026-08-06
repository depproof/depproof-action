# depproof — dependency vulnerability & license audit for Maven, Gradle, npm, Python & Go

Catch vulnerable and non-compliant dependencies in your pull request — the scan runs entirely inside your CI runner, and **your source and manifests never leave it**.

depproof scans your Maven, Gradle, npm/pnpm/yarn, Python, and Go dependency manifests against [OSV.dev](https://osv.dev) for known vulnerabilities and public [SPDX](https://spdx.org/licenses/) license data for licensing, emits CycloneDX 1.6 SBOMs, and sets a pass/fail exit code that gates your PR.

> 📖 **Full docs, guides & license explainers: [depproof.com](https://depproof.com).**

## Why depproof

- **Privacy-first.** The scan runs inside your GitHub Actions runner. Your `pom.xml` / `build.gradle.kts` / `package-lock.json` never leave it — only individual package coordinates are checked against public registries and vulnerability/license databases. No source uploaded, no account, no telemetry.
- **Monorepo-aware.** Auto-discovers every manifest in your repo by default (Maven, Gradle & npm/pnpm/yarn, in any subdirectory). Multi-module Maven projects are handled correctly so child modules build on their parent.
- **Accurate transitive resolution.** Resolves the full transitive dependency tree so it matches what your build actually ships — Spring Boot / Kotlin / Quarkus managed versions included — so you don't get false-positive CVEs against versions you've already patched.
- **Free for small businesses.** No cost for organizations under $1M annual revenue — no signup, no API key, no quota. (Larger orgs: commercial license — licensing@depproof.com.)

## Quick start

Add a single workflow file to your repo:

```yaml
# .github/workflows/audit.yml
name: Dependency Audit
on:
  push:
    branches: [main]
  pull_request:

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: depproof/depproof-action@v1
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: depproof-reports
          path: |
            depproof-*.json
            depproof-report*.html
```

That's it. On every PR + push to main, depproof scans your repo and fails the build if any CRITICAL vulnerability is present.

## Configuration

All inputs are optional. The defaults handle most repos.

```yaml
- uses: depproof/depproof-action@v1
  with:
    # Single file mode (skip auto-discovery)
    file: backend/pom.xml

    # OR multiple explicit files (newline or comma-separated)
    files: |
      backend/pom.xml
      services/api/pom.xml

    # Auto-discover manifests under root (default: true). Set false to require file/files.
    discover: true

    # Severity threshold for failure: critical (default) | high | medium | low | none
    fail-on: critical

    # Additional gate rules, OR-ed with fail-on (see "CI gate" below). All optional.
    fail-on-cvss: '7.5'               # fail on computed CVSS base score >= 7.5
    fail-on-unknown: false            # fail on findings that could not be graded at all
    fail-only-if-fix-available: false # only findings with a known fix can fail the build

    # Discovery root. Default: $GITHUB_WORKSPACE
    root: backend

    # Extra glob patterns to exclude (on top of default node_modules / target / build / etc.)
    exclude: 'fixtures/**,examples/**'

    # Where to write SBOM artifacts. Default: $GITHUB_WORKSPACE
    output-dir: reports

    # Also emit a human-readable HTML report (depproof-report.html). Default: true
    html: true

    # Go: resolve the exact module graph with `go list -m -json all` when `go` is on the runner
    # (falls back to a static go.mod parse otherwise). Default: true.
    go-online: true

    # --- Where the findings show up ---
    # Render the results onto the workflow run page. No permissions needed, works everywhere.
    job-summary: true
    # Post the same summary as one PR comment, updated in place. 'auto' = only on pull_request
    # events. Needs `pull-requests: write`; without it, warns and the build is unaffected.
    pr-comment: auto

    # --- Self-hosted hub (optional) ---
    # POST each scan report to your depproof-hub for org-wide governance.
    report-to: https://hub.example.com/api/v1/scans
    report-token: ${{ secrets.DEPPROOF_HUB_TOKEN }}

    # Online-mode CI gate: fetch the active waiver set from the hub at scan time and suppress
    # centrally-waived findings from the gate (the SBOM/report stay raw). Requires report-to +
    # report-token. Fail-closed: if the hub is unreachable, no waivers are applied and the gate
    # stays strict — so an unreachable hub can never silently turn a red build green.
    waivers-online: true
```

## What gets scanned by default

Auto-discovery finds these manifests anywhere in your repo:
- `pom.xml` (Maven)
- `build.gradle`, `build.gradle.kts`, `gradle.lockfile`, `libs.versions.toml`, `dependencies.txt` (Gradle)
- `package-lock.json` (npm), `pnpm-lock.yaml` (pnpm), `yarn.lock` (yarn) — resolved straight from the lockfile, no install
- `poetry.lock`, `pdm.lock`, `uv.lock`, `Pipfile.lock`, `requirements.txt`, `pyproject.toml` (Python) — resolved from the lockfile; a lockless `pyproject.toml` is a minimum-version fallback, so commit a lockfile (or generate one in a prior CI step) for an exact result
- `go.mod` (Go) — with `go-online: true` (default), the action runs `go list -m -json all` on the runner for the **exact** resolved module graph (written to `go.deps.json`, preferred over `go.mod`); it falls back to a static `go.mod` parse (direct + `// indirect` requires, `replace` applied) when `go` isn't on the runner

And **skips** these directories (build output and vendored code — nothing to audit there):
- `node_modules/`, `target/`, `build/`, `.gradle/`, `.git/`, `dist/`, `out/`, `vendor/`, `test-fixtures/`, `__fixtures__/`

Use `exclude` to add custom glob patterns on top of the defaults.

## Output

### In the run itself

By default the action renders the findings straight onto the **workflow run page** — verdict, the
rule that fired, severity counts, and the findings ranked with known-exploited first. It needs no
permissions and works on every repository, public or private.

On a pull request it also posts the same summary as a **single comment, updated in place** on each
run rather than appended. That one needs `pull-requests: write`:

```yaml
permissions:
  contents: read
  pull-requests: write     # only needed for the PR comment
```

Without that permission the comment is skipped with a warning and **the build is unaffected** — a
comment is never worth failing a build over. Set `pr-comment: false` to turn it off, or
`job-summary: false` for the run-page summary.

Both surfaces render even when the scan fails, which is when they matter most.

> **A note on GitHub's Security tab.** depproof does not upload SARIF yet, so findings do not appear
> there. When it does, that surface will require GitHub Advanced Security on private repositories —
> the two above deliberately do not.

### Files

After a successful run, depproof writes to the workspace (or `output-dir` if set):

| File | Contents |
|---|---|
| `depproof-summary.json` | Combined results: per-manifest counts, vuln/license totals, fail/pass per manifest |
| `depproof-sbom-<path>.json` | CycloneDX 1.6 SBOM for each scanned manifest. Slashes in path replaced with `--`. |
| `depproof-report.html` | Human-readable report (vulnerabilities + dependencies + license policy). Self-contained — opens offline, no network or JS. On multi-manifest scans this is an index linking one `depproof-report-<path>.html` per manifest. Set `html: false` to skip. |

> ⚠️ **These files land in the runner's workspace, which GitHub discards when the job ends.** The
> action does **not** upload them for you. The run-page summary above covers the common case; to make
> the full HTML report and SBOMs **downloadable from the run**, add an
> [`actions/upload-artifact`](https://github.com/actions/upload-artifact) step (as in
> [Quick start](#quick-start)):
>
> ```yaml
>       - uses: actions/upload-artifact@v4
>         if: always()   # upload even when the scan exits non-zero on findings
>         with:
>           name: depproof-reports
>           path: |
>             depproof-*.json
>             depproof-report*.html
> ```
>
> Pushing to a self-hosted hub (the `report-to` input) is a **separate** channel: it sends the summary
> to your hub for org-wide dashboards and does **not** create downloadable run artifacts. Use the
> `upload-artifact` step, `report-to`, or both — they're independent.

The `depproof-summary.json` schema is stable for v1 — safe to consume from downstream steps:

```json
{
  "schemaVersion": 1,
  "depproofVersion": "<version>",
  "scannedAt": "2026-06-12T14:53:25Z",
  "rootDir": "/github/workspace",
  "manifests": [
    {
      "path": "backend/pom.xml",
      "ecosystem": "Maven",
      "components": 132,
      "direct": 29,
      "transitive": 103,
      "vulns": { "critical": 0, "high": 4, "medium": 5, "low": 4 },
      "licenses": { "forbidden": 0, "review": 15, "allowed": 117, "unknown": 0 },
      "sbomFile": "depproof-sbom-backend--pom.xml.json",
      "fail": false,
      "isParentPom": false,
      "unresolvedCount": 0
    }
  ],
  "totals": { "critical": 0, "high": 4, "medium": 5, "low": 4 },
  "fail": false
}
```

## CI gate

The gate decides which findings turn a scan into a failed build. Rules are **OR-ed** — a finding
matching *any* active rule fails the build:

| Input | Rule |
|---|---|
| `fail-on: <sev>` | severity at or above `critical` \| `high` \| `medium` \| `low`, or `none` to disable |
| `fail-on-cvss: <n>` | computed CVSS base score >= `n` (0.0–10.0) |
| `fail-on-unknown: true` | the finding could not be graded at all |
| `fail-only-if-fix-available: true` | **narrows** all of the above to findings with a known fix |
| `fail-on-kev: true` | the finding is listed as known-exploited (requires `enrich-online`) |

Two details worth knowing:

- **`fail-on` never matches ungraded findings.** An advisory with no scoreable CVSS vector and no
  severity word is not silently treated as low or as critical — gate it explicitly with
  `fail-on-unknown`.
- **`fail-on-cvss` never matches a finding with no score.** An absent score is not a low score.
  Combine it with `fail-on-unknown` if you want both covered.

Waived findings (`waivers-online`) are dropped before any rule runs. The log always says which
finding tripped which rule, and reports what was suppressed even when the build passes:

```
depproof — gate: severity high or above or CVSS score 7.0 or above
  waivers:    2 vuln finding(s) suppressed from the gate by --waivers
  result:     FAIL — 1 finding(s) tripped the gate
    package-lock.json: CVE-2026-14257 high cvss 7.5  :brace-expansion:5.0.7 fix 5.0.8  [severity>=high, cvss>=7.0]
```

CVSS scores come from the advisory's CVSS vector, which is also recorded in the CycloneDX SBOM.

### Gating on exploitation (requires a hub)

Severity says how bad a vulnerability *could* be. It says nothing about whether anyone is using it —
and plenty of actively-exploited vulnerabilities are rated only medium, so a `critical`-or-`high`
threshold merges them without comment.

`enrich-online` applies exploitation data from your self-hosted hub. Two signals:

- **`fail-on-kev`** — the vulnerability is on CISA's Known Exploited catalogue. Binary, and fails the
  build **regardless of severity**.
- **`fail-on-epss`** — modelled probability of exploitation in the next 30 days. Continuous, so a
  medium at 0.98 outranks a high nobody is attacking.

```yaml
- uses: depproof/depproof-action@v1
  with:
    report-to: https://hub.example.com/api/v1/scans
    report-token: ${{ secrets.DEPPROOF_HUB_TOKEN }}
    enrich-online: true
    enrich-mode: targeted    # required for fail-on-epss
    fail-on-kev: true
    fail-on-epss: '0.9'
    fail-on: critical        # unchanged — these are additional rules, not replacements
```

Findings carry a KEV badge in the HTML report and `depproof:kev` / `depproof:epss` properties in the
SBOM.

#### Choosing a mode

| | `bulk` (default) | `targeted` |
|---|---|---|
| What travels | the hub sends its whole catalogue | your finding ids go to the hub |
| Does the hub learn your findings? | **no** | yes |
| Covers | KEV | KEV + EPSS |
| `fail-on-epss` | not available | ✅ |

They differ in privacy, not quality. `bulk` keeps your vulnerabilities on the runner — the hub is
never told which CVEs you have — and it is the default for that reason. `targeted` is required for
EPSS, whose catalogue is roughly 355,000 entries and cannot be shipped on every run; in exchange, the
hub records precisely what each scan was told, which is what an auditor asks for.

#### Behaviours worth knowing

- **`fail-only-if-fix-available` does not narrow `fail-on-kev`.** A known-exploited finding with no
  released fix is the most urgent thing in the report, not the one to suppress.
- **Fail-closed, but only when it changes the answer.** If the hub is unreachable and a rule depends
  on it, the run stops with **exit 4** — a distinct code, so an infrastructure problem is never
  mistaken for a findings failure. If no such rule is active, the missing data cannot alter the
  verdict, so the log warns and the scan continues.
- **`fail-on-epss` with `enrich-mode: bulk` is refused, with a warning.** The bulk catalogue carries
  KEV only, so the rule would silently match nothing — quietly passing instead of quietly failing,
  which is the worse of the two.

## Exit codes

- `0` — scan clean (no finding tripped the gate)
- `1` — one or more findings tripped the gate
- `2` — scan error (bad arguments, or a manifest that could not be parsed)
- `3` — `report-required` was set and the report was not delivered to the hub
- `4` — a gate rule depends on enrichment the hub could not supply

The codes above `1` are deliberately distinct so a failed build can be told apart from a broken one.
`3` and `4` mean the scan never reached a trustworthy verdict — an infrastructure problem, not a
finding — and a workflow that treats "non-zero" as "vulnerable" will misreport both. `3` is only
raised when the scan itself passed, so an upload problem can never mask a real failure.

## Examples

### Monorepo / multi-module project

```yaml
- uses: depproof/depproof-action@v1
  # Discovery default — scans every Maven/Gradle/npm/Python manifest under repo root.
  # Multi-module Maven projects: parent + child POMs are auto-detected and bundled,
  # so child modules build on their parent locally (no Maven Central round-trip).
```

### Only scan one specific manifest

```yaml
- uses: depproof/depproof-action@v1
  with:
    file: services/api/pom.xml
```

### Fail on HIGH-or-worse (not just CRITICAL)

```yaml
- uses: depproof/depproof-action@v1
  with:
    fail-on: high
```

### Gate on exploitability score rather than the severity label

```yaml
- uses: depproof/depproof-action@v1
  with:
    fail-on: none          # turn off the severity rule
    fail-on-cvss: '7.0'    # ...and gate on the computed CVSS base score instead
```

### Gate only on what your team can actually fix today

```yaml
- uses: depproof/depproof-action@v1
  with:
    fail-on: high
    fail-only-if-fix-available: true  # a vuln with no released fix won't block the PR
```

### Use depproof in a non-blocking advisory mode

```yaml
- uses: depproof/depproof-action@v1
  with:
    fail-on: none  # never fails on findings (scan errors still exit 2); results still in artifacts
```

## License

depproof is proprietary software, **free to use** for organizations with under $1M USD annual revenue. Larger organizations require a commercial license (contact licensing@depproof.com). See [LICENSE](LICENSE).

## Privacy

depproof makes outbound calls only to these public services:

- `repo.maven.apache.org` — Maven Central (public package metadata)
- `api.osv.dev` — OSV.dev (public vulnerability data)
- `api.clearlydefined.io` — ClearlyDefined.io (public license metadata)

No telemetry. No phone-home. No API keys.

depproof runs as a self-contained Docker image (`ghcr.io/depproof/depproof`) — no local Java, Maven, or Gradle install required on your runner. See [action.yml](./action.yml) for the exact invocation.

---

📖 License explainers, SBOM & SCA guides, and full documentation → **[depproof.com](https://depproof.com)**
