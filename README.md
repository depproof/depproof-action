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

> 📂 That file is [`examples/github/basic.yml`](examples/github/basic.yml), annotated. **[`examples/`](examples/)**
> has the rest — a [daily scan](examples/github/scheduled.yml) for code nobody is changing, an
> [exact Gradle graph](examples/github/gradle-exact-graph.yml), a [monorepo](examples/github/monorepo.yml)
> with one gate per team, a [self-hosted hub](examples/github/hub.yml), and
> [GitLab CI](examples/gitlab/depproof.gitlab-ci.yml).

## How this fits together

**You own the workflow. You reference the action.**

```
your repo
  .github/workflows/audit.yml        ← yours: triggers, steps, permissions, artifacts
      └─ uses: depproof/depproof-action@v1
              └─ pulls ghcr.io/depproof/depproof and runs the scan in it
```

That `uses:` line is the whole integration. There is nothing to vendor, install, or keep in sync —
no config file of ours in your repo, no runner dependencies (no local Java, Maven, Gradle or Node
needed). `@v1` is a rolling major tag that picks up fixes; pin to a full version (`@v1.4.1`) or a
commit SHA if you would rather approve every change yourself.

The scan writes its results into the workspace — SBOMs, an HTML report, `depproof-summary.md` — and
sets the exit code. Everything after that is your workflow's business: upload them, publish them,
ignore them.

### Two kinds of tuning

**Values go on the step.** `fail-on`, `require-fidelity`, `exclude`, `report-to` — see
[Configuration](#configuration) below. Most tuning is this, and it is one line.

**Shape needs a workflow.** Some of the most useful things are not inputs at all, and cannot be:

| What you want | Why it is not an input |
|---|---|
| A daily scan | A `schedule:` trigger belongs to the workflow, not to a step |
| An exact Gradle graph | Your build must run **before** ours — and an action cannot insert a step above itself |
| One gate per team in a monorepo | That is a job matrix |
| The reports kept after the run | A separate upload step, with a retention you choose |

That is what [`examples/`](examples/) is for: each file is a complete workflow you copy and edit,
rather than a snippet to splice. Take the closest one — they compose fine when you need two.

### On GitLab

There is no action to reference, so the [template](examples/gitlab/depproof.gitlab-ci.yml) *is* the
job: copy it into your repository and it runs the same container with the same arguments. It is
self-contained by design — nothing is fetched at pipeline time.

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
    ignore-scope: ''                  # e.g. 'development' — dependencies you do not ship cannot fail the build
    internal: ''                      # e.g. 'com.acme.internal:*' — YOUR packages on a private registry

    # Discovery root. Default: $GITHUB_WORKSPACE
    root: backend

    # Extra glob patterns to exclude (on top of default node_modules / target / build / etc.)
    exclude: 'fixtures/**,examples/**'

    # Where to write SBOM artifacts. Default: $GITHUB_WORKSPACE
    output-dir: reports

    # Also emit a human-readable HTML report (depproof-report.html). Default: true
    html: true

    # Go: resolve the exact graph — with test-vs-build scope — when `go` is on the runner
    # (falls back to a static go.mod parse otherwise). Default: true.
    go-online: true

    # --- Where the findings show up ---
    # Render the results onto the workflow run page. No permissions needed, works everywhere.
    job-summary: true
    # Post the same summary as one PR comment, updated in place. 'auto' = only on pull_request
    # events. Needs `pull-requests: write`; without it, warns and the build is unaffected.
    pr-comment: auto

    # --- Self-hosted hub (optional) ---
    # POST each scan report to your depproof-hub for org-wide governance; apply exploitation data
    # and central waivers at scan time. All of it, with the trade-offs, in examples/github/hub.yml.
    report-to: https://hub.example.com/api/v1/scans
    report-token: ${{ secrets.DEPPROOF_HUB_TOKEN }}
    waivers-online: true
    enrich-online: true

    # --- Coverage gating (optional) ---
    # Fail the build when a manifest could not be read as a resolved graph. Off by default; the scan
    # always says so regardless. See examples/github/gradle-exact-graph.yml.
    require-fidelity: resolved
```

## What gets scanned by default

Auto-discovery finds these manifests anywhere in your repo:
- `pom.xml` (Maven)
- `build.gradle`, `build.gradle.kts`, `gradle.lockfile`, `libs.versions.toml`, `dependencies.txt` (Gradle) — a `gradle.lockfile` or `dependencies.txt` gives the **exact** resolved graph; a bare build script is a best-effort read and dependencies whose versions come from a BOM or plugin may be missing entirely, so [produce one in a prior CI step](#getting-an-exact-gradle-graph)
- `package-lock.json` (npm), `pnpm-lock.yaml` (pnpm), `yarn.lock` (yarn) — resolved straight from the lockfile, no install
- `poetry.lock`, `pdm.lock`, `uv.lock`, `Pipfile.lock`, `requirements.txt`, `pyproject.toml` (Python) — resolved from the lockfile; a lockless `pyproject.toml` is a minimum-version fallback, so commit a lockfile (or generate one in a prior CI step) for an exact result
- `go.mod` (Go) — with `go-online: true` (default), the action runs `go list -deps -test -json ./...` on the runner for the **exact** resolved graph **including which modules only tests need** (written to `go.deps.json`, preferred over `go.mod`). If that fails — it type-checks, so a tree that does not build will — it falls back to `go list -m -json all`, which is still exact but carries no test/build split, and then to a static `go.mod` parse when `go` isn't on the runner

And **skips** these directories (build output and vendored code — nothing to audit there):
- `node_modules/`, `target/`, `build/`, `.gradle/`, `.git/`, `dist/`, `out/`, `vendor/`, `test-fixtures/`, `__fixtures__/`

Use `exclude` to add custom glob patterns on top of the defaults.

## Getting an exact Gradle graph

**Why this needs a step from you.** For Go, the action runs `go list` itself. That command resolves
and type-checks packages — more than reading metadata — but it never *executes* your code. A Gradle
build script is different in kind: it **is** code, and evaluating it to learn the dependency graph
means running untrusted code on your runner. depproof therefore never invokes Gradle. The resolved graph can only come from your own build, which already has the right JDK,
Gradle version and credentials for private repositories.

Without it, depproof reads `build.gradle` statically. Versions supplied by a BOM, a platform or a
plugin are not applied, so those dependencies — and everything beneath them — can be **absent from
the report entirely**, with no error to show for it. The scan says so: it reports coverage as
`DECLARED_ONLY` and the hub marks findings from that manifest as measured against an unresolved
graph.

Two ways to produce one. Either is picked up by auto-discovery with no extra configuration:

```bash
./gradlew -q dependencies > dependencies.txt   # a dump, committed nowhere
./gradlew dependencies --write-locks           # or locking: commit the gradle.lockfile(s) it writes
```

**→ The workflow, ready to copy: [`examples/github/gradle-exact-graph.yml`](examples/github/gradle-exact-graph.yml)** —
including `require-fidelity: resolved`, which makes the exact graph non-optional by failing the build
until one is present.

### If your build has more than one project

`dependencies` is a **per-project** task. Run at the root of a multi-module build it reports the
root project and **nothing else** — so the one-line recipe above leaves every module unread, and
leaves it unread quietly, because the file it produces is perfectly valid for the one project it
covers.

depproof matches a dump to the build script **in the same directory**, which is what makes this
visible rather than silent: a root dump satisfies the root, and each module keeps reporting
`DECLARED_ONLY` until it has a dump of its own. The scan's coverage warning names them and counts
them, so following the single-module recipe and then finding 35 modules still flagged is the
expected outcome rather than a bug.

The per-project loop is in the same example, commented out beside the single-module line. If your
`settings.gradle` points a project at some other directory with `projectDir`, write its dump there
instead — beside the build script is the rule.

Dependency locking has the same shape: `--write-locks` locks the configurations the invoked task
resolved, so it is also per project. Gradle documents a
[`resolveAndLockAll` task](https://docs.gradle.org/current/userguide/dependency_locking.html) for
doing every project in one command; that is a change to your build, and it is yours to make —
depproof will not add code to your build for you, which is the same rule that stops it running
Gradle in the first place.

## Output

### In the run itself

By default the scan's summary is written straight onto the **workflow run page** — verdict, the
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

> **The summary is produced by the scanner, not this action.** depproof writes
> `depproof-summary.md` itself, so the same output is available in any CI. This action only puts it
> where GitHub can show it. **On GitLab**, copy
> [`examples/gitlab/depproof.gitlab-ci.yml`](examples/gitlab/depproof.gitlab-ci.yml) into your repository — same scan,
> same gate, same summary, posted as a merge request comment that updates in place. It is a worked
> example to own and edit, and it fetches nothing at run time.
>
> **A note on GitHub's Security tab.** depproof writes SARIF and uploads it — set `sarif: true`, see
> below. That surface requires GitHub Code Security (formerly Advanced Security) on **private**
> repositories; it is free on public ones. The job summary and PR comment above deliberately require
> neither, so they remain the paths that always work.

### Files

After a successful run, depproof writes to the workspace (or `output-dir` if set):

| File | Contents |
|---|---|
| `depproof-summary.json` | Combined results: per-manifest counts, vuln/license totals, fail/pass per manifest |
| `depproof.sarif` | SARIF 2.1.0 for GitHub code scanning — written only with `sarif: true` |
| `depproof-summary.md` | The run-page/PR summary, written by the scanner. Present whenever `job-summary` or `pr-comment` is on. |
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
| `ignore-scope: development` | **narrows** all of the above to dependencies you ship — see below |
| `internal: <globs>` | **never a rule.** Your own private-registry packages report status unknown and cannot fail the build — see below |
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

### Gating only on what you ship (`ignore-scope`)

A test runner is not in the artifact you deploy. `ignore-scope: development` stops findings on
development dependencies failing the build, which on a project with a large toolchain can be a
substantial share of what a gate looks at. Off by default; findings are still scanned, reported,
pushed to the hub and present in the SBOM, so this changes the **gate** and nothing else — and every
scan prints its own breakdown, so you can see what it would cost on YOUR repository rather than
taking a number on trust.

Three things to know before turning it on, because this is the one control that can make a build
pass that would otherwise have failed:

- **It narrows every rule, including `fail-on-kev`** — unlike `fail-only-if-fix-available`, which
  exempts it. The two answer different questions: fix-availability is about whether a finding is
  *actionable*, and a known-exploited vulnerability is urgent either way; scope is about whether the
  code is *exposed at all*, which applies uniformly. A suppressed known-exploited finding is printed
  by name and manifest on stderr rather than counted, because a development dependency still runs on
  your build machines.
- **A dependency nobody could classify is never suppressed.** Some manifests genuinely cannot state
  a scope — a Gradle version catalogue, a bare `go.mod`. Those report *not determined*, which is not
  a scope, and they stay in the gate. `ignore-scope: undetermined` is rejected outright.
- **An unknown scope is an error, not a no-op.** `ignore-scope: dev` — what npm calls it — fails the
  run rather than quietly narrowing nothing, so you never believe a gate is scoped when it is not.
  Valid values: `development`, `optional`, `provided`, `runtime`.

Every scan prints the scope breakdown of its findings whether or not the input is set, so you can
see what this would cost before you opt in:

```
depproof — gate: severity high or above, ignoring development dependencies
  by scope:   88 development, 16 runtime
  scope:      88 vuln finding(s) excluded by --ignore-scope (88 development)
              · yarn.lock: CVE-2021-44906 critical  :minimist:1.2.0 (development)
  result:     FAIL — 8 finding(s) tripped the gate
    package.json: CVE-2019-10744 critical cvss 9.1  :lodash:4.16.2 fix 4.17.12  [severity>=high]
```

### Findings in the Security tab and on the diff (`sarif`)

**Off unless you set it. Needs `security-events: write`.**

```yaml
permissions:
  contents: read
  security-events: write
steps:
  - uses: depproof/depproof-action@v1
    with:
      sarif: true
```

Findings appear as code scanning alerts — in the Security tab, and inline on the pull request. Set
`sarif-upload: false` to write `depproof.sarif` without uploading it, if you upload from another job.

**Requires GitHub Code Security on private repositories**; free on public ones. Without the
permission the upload is refused, the step warns, and your build is unaffected — the file is still
written to the workspace.

#### Two things this does that most tools do not

**A scan that could not look does not report "clean".** If a vulnerability source could not be
reached, a manifest could not be parsed, or the dependency graph could not be fully resolved, those
are uploaded as **visible alerts saying so**. An empty Security tab is read as an assurance, and a
scan that never asked the question must not be shown as one that asked and found nothing.

**One finding is one alert.** A package with one CVE in five modules is a single alert listing five
locations, not five alerts. The count you see here matches the count everywhere else.

Alerts are uploaded even when the gate **fails** the build, which is when they matter most.

### Which dependencies actually loaded when your tests ran (`usage-from`)

**Off unless you set it, and it can never fail your build.**

A vulnerability in a dependency your code never even opens is not the same problem as one in the
library handling every request. This annotates each component with whether it was ever *loaded*
during your own test run, so you can order a triage queue by something better than severity alone.

Set one environment variable on your existing test step, then point the action at the output:

```yaml
- name: Test
  env:
    JAVA_TOOL_OPTIONS: -Xlog:class+load=info:file=traces/trace-%p.log
  run: ./mvnw verify || true      # a partial suite still yields a valid trace

- uses: depproof/depproof-action@v1
  with:
    usage-from: traces
```

| ecosystem | what to set on your test step |
|---|---|
| JVM | `JAVA_TOOL_OPTIONS: -Xlog:class+load=info:file=traces/trace-%p.log` |
| Node | `NODE_V8_COVERAGE: traces` |
| Python | a `sitecustomize.py` on `PYTHONPATH` that writes loaded distributions at exit |

The `%p` is not optional, and the same idea applies everywhere: **test runners fork.** A single
trace file for a parallel suite silently holds one worker's view of the world, which reads as a
great many dependencies that never loaded.

#### Read the result correctly, because it is easy to over-read

**"Not loaded" is not "not affected".** The evidence comes from your tests, and tests are not
production. A dependency used only on an error path, behind a feature flag, or by a code path your
suite skips will show as never loaded and is genuinely required.

**It cannot tell you to delete anything.** Measured across three ecosystems, almost every
never-loaded dependency is *transitive* — it arrives underneath something you did ask for, and is
not yours to remove. On one Spring application, every single one was.

**Which suite you run changes the answer more than you would expect.** The same application, on the
same machine, differing only in whether its integration tests ran: **11.3%** never loaded with them,
**22.0%** without — and *both runs reported 100% of their tests passing*. Nothing in a test report
distinguishes those two runs, so the coverage behind the number is reported alongside it. Integration
tests are worth far more here than unit tests, because booting a real application context loads what
reflection and dependency injection wire, and that is exactly the population unit tests never touch.

**It never suppresses a finding.** No exit code changes, no new gate flag, and nothing is filtered
or hidden. Log4Shell was reached through a logged string with no call site in user code — a tool that
filtered on this signal would have said "not affected" about it.

If the trace is missing, unreadable, or fails its own consistency checks, the axis switches **off**
for that run and says so. It does not report that nothing loaded. A tracer that failed to attach and
a project whose dependencies genuinely never load produce identical empty files, and only one of
those is good news.

### Your own packages on a private registry (`internal`)

Most companies publish shared libraries to their own Nexus, Artifactory or package index. Those
coordinates exist nowhere public, so **no advisory source has ever held a record of them** — and a
scanner that looks them up against a public registry, finds nothing, and reports them clean has not
checked anything. It has answered a question nobody asked.

```yaml
    internal: 'com.acme.internal:*,@acme/*,github.acme.internal/**'
```

Matched against `groupId:artifactId`, or the bare package name where the ecosystem has no group.
`*` matches within a segment, `**` across.

What changes when you declare them:

- They are **never screened**, and each one is reported as **status unknown** rather than counted
  clean. A row that says nothing is a row that was never checked, and it now says so.
- The **SBOM stops claiming they came from a public registry.** A purl states where a package came
  from; asserting your private library came from Maven Central is a false claim in the one document
  whose entire purpose is provenance. They carry `depproof:provenance` and `depproof:screened=false`
  instead.
- If you report to a **depproof-hub**, an internal dependency is matched against what your other
  repositories publish. It resolves either to the repo that builds it — findings one click away — or
  to *"no scanned repo publishes this"*, which is a gap you can act on by onboarding that repo. No
  public scanner can answer that question for you, because the coordinate is private.

**These never fail the build.** Not the severity rules, not `require-fidelity`, not
`require-enrichment`. No action available to you clears the condition — you cannot publish a private
library to a public registry, and this scanner cannot read your registry — so a gate that failed on
it would be a gate you had to switch off, and switching it off would cost you everything else it
catches. Status unknown is reported, never enforced.

**You do not need this for code inside the repository being scanned.** A Maven reactor sibling, a
Gradle `project(':core')`, a Go `replace` onto a local path, a Python `-e ./libs/core` and an npm
workspace member are detected automatically and marked *first-party* — another manifest in the same
scan already covers them, so there was nothing to screen rather than something that could not be.

Nothing is inferred from a name. An undeclared private package stays third-party and is screened,
which over-reports rather than going quiet:

```
depproof — scanned app/pom.xml (Maven)
  components: 3  (2 direct, 1 transitive)
  first-party: 1 in this repository — not screened, nothing to screen
  internal:   1 declared internal — status UNKNOWN, not clean; no advisory source covers these and none was asked
              · com.acme.internal:shared-auth:2.3.0
              These never fail the build. Status unknown is reported, never enforced.
```

### Gating on exploitation (requires a hub)

Severity says how bad a vulnerability *could* be. It says nothing about whether anyone is using it —
and plenty of actively-exploited vulnerabilities are rated only medium, so a `critical`-or-`high`
threshold merges them without comment.

`enrich-online` applies exploitation data from your self-hosted hub. Two signals:

- **`fail-on-kev`** — the vulnerability is on CISA's Known Exploited catalogue. Binary, and fails the
  build **regardless of severity**.
- **`fail-on-epss`** — modelled probability of exploitation in the next 30 days. Continuous, so a
  medium at 0.98 outranks a high nobody is attacking.

Both are additional rules, not replacements: `fail-on` keeps working alongside them.
**→ [`examples/github/hub.yml`](examples/github/hub.yml)** has the whole configuration.

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

Complete workflows to copy live in **[`examples/`](examples/)** — each one is the quick start plus a
single idea:

| | |
|---|---|
| [`github/basic.yml`](examples/github/basic.yml) | scan everything, fail on a critical, keep the reports |
| [`github/scheduled.yml`](examples/github/scheduled.yml) | a daily run, for code nobody is changing — where most new risk actually appears |
| [`github/gradle-exact-graph.yml`](examples/github/gradle-exact-graph.yml) | the resolved Gradle graph, single- and multi-module, then gate on it |
| [`github/monorepo.yml`](examples/github/monorepo.yml) | exclude subtrees, or one scan and one gate per team |
| [`github/hub.yml`](examples/github/hub.yml) | push to a self-hosted hub, exploitation data at scan time, central waivers |
| [`gitlab/depproof.gitlab-ci.yml`](examples/gitlab/depproof.gitlab-ci.yml) | the same scan, gate and summary on GitLab CI |

Single-input tweaks need no example — set them on the step:

| Want | Set |
|---|---|
| Fail on high-or-worse, not just critical | `fail-on: high` |
| Gate on the computed score, not the label | `fail-on: none` + `fail-on-cvss: '7.0'` |
| Only block on what can be fixed today | `fail-only-if-fix-available: true` |
| Advisory mode — never block a PR | `fail-on: none` (scan errors still exit `2`) |
| One manifest, no discovery | `file: services/api/pom.xml` |
| Refuse to report on an unresolved graph | `require-fidelity: resolved` |

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
