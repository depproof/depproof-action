# depproof — dependency vulnerability & license audit for Maven, Gradle, npm & Python

Catch vulnerable and non-compliant dependencies in your pull request — the scan runs entirely inside your CI runner, and **your source and manifests never leave it**.

depproof scans your Maven, Gradle, npm/pnpm/yarn, and Python dependency manifests against [OSV.dev](https://osv.dev) for known vulnerabilities and public [SPDX](https://spdx.org/licenses/) license data for licensing, emits CycloneDX 1.6 SBOMs, and sets a pass/fail exit code that gates your PR.

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

    # Discovery root. Default: $GITHUB_WORKSPACE
    root: backend

    # Extra glob patterns to exclude (on top of default node_modules / target / build / etc.)
    exclude: 'fixtures/**,examples/**'

    # Where to write SBOM artifacts. Default: $GITHUB_WORKSPACE
    output-dir: reports

    # Also emit a human-readable HTML report (depproof-report.html). Default: true
    html: true
```

## What gets scanned by default

Auto-discovery finds these manifests anywhere in your repo:
- `pom.xml` (Maven)
- `build.gradle`, `build.gradle.kts`, `gradle.lockfile`, `libs.versions.toml`, `dependencies.txt` (Gradle)
- `package-lock.json` (npm), `pnpm-lock.yaml` (pnpm), `yarn.lock` (yarn) — resolved straight from the lockfile, no install
- `poetry.lock`, `pdm.lock`, `uv.lock`, `Pipfile.lock`, `requirements.txt`, `pyproject.toml` (Python) — resolved from the lockfile; a lockless `pyproject.toml` is a minimum-version fallback, so commit a lockfile (or generate one in a prior CI step) for an exact result

And **skips** these directories (build output and vendored code — nothing to audit there):
- `node_modules/`, `target/`, `build/`, `.gradle/`, `.git/`, `dist/`, `out/`, `vendor/`, `test-fixtures/`, `__fixtures__/`

Use `exclude` to add custom glob patterns on top of the defaults.

## Output

After a successful run, depproof writes to the workspace (or `output-dir` if set):

| File | Contents |
|---|---|
| `depproof-summary.json` | Combined results: per-manifest counts, vuln/license totals, fail/pass per manifest |
| `depproof-sbom-<path>.json` | CycloneDX 1.6 SBOM for each scanned manifest. Slashes in path replaced with `--`. |
| `depproof-report.html` | Human-readable report (vulnerabilities + dependencies + license policy). Self-contained — opens offline, no network or JS. On multi-manifest scans this is an index linking one `depproof-report-<path>.html` per manifest. Set `html: false` to skip. |

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

## Exit codes

- `0` — scan clean (or no findings exceed `fail-on` threshold)
- `1` — findings exceed `fail-on` threshold (one or more manifests failed)
- `2` — scan error (bad arguments or unsupported file)

## Examples

### Monorepo / multi-module project

```yaml
- uses: depproof/depproof-action@v1
  # Discovery default — scans every Maven/Gradle manifest under repo root.
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
