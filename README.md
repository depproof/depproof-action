# depproof-action

Dependency vulnerability + license audit for Maven, Gradle, and npm — **runs entirely inside your CI runner, no data leaves the runner**.

[depproof](https://github.com/depproof/depproof) scans your dependency manifests against [OSV.dev](https://osv.dev) (vulnerabilities) and the full [SPDX license corpus](https://spdx.org/licenses/) + [ClearlyDefined.io](https://clearlydefined.io) (licenses), emits CycloneDX 1.6 SBOMs, and sets a pass/fail exit code that gates your PR.

## Why depproof

- **Privacy-first.** The scan happens inside your GitHub Actions runner. Only public APIs (Maven Central, npm registry, OSV.dev) are called — never anything you control. Your pom.xml / build.gradle.kts / package-lock.json never leaves the runner.
- **Monorepo-aware.** Auto-discovers every manifest in your repo by default (Maven, Gradle, npm, in any subdirectory). Multi-module Maven projects are bundled correctly so child modules resolve their parent locally.
- **Accurate transitive resolution.** Maven projects use Aether (the same engine `mvn` uses). Gradle projects detect Spring Boot / Kotlin / Quarkus plugin BOMs and apply `extra["xxx.version"]` overrides correctly — no more false-positive CVEs against versions you've already patched.
- **Open source, free.** Apache-2.0 licensed. No signup, no API key, no quota.

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
      frontend/package-lock.json

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
- `package-lock.json`, `yarn.lock`, `package.json` (npm)

And **skips** these directories (no way to scan their contents):
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
  "depproofVersion": "0.1.0",
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
      "licenses": { "forbidden": 0, "review": 15, "allowed": 116, "unknown": 0 },
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
- `2` — scan error (bad args, unsupported file, no manifests found in discovery mode)

## Examples

### Monorepo with both Java and JavaScript

```yaml
- uses: depproof/depproof-action@v1
  # Discovery default — scans every manifest under repo root.
```

### Multi-module Maven project

```yaml
- uses: depproof/depproof-action@v1
  # Discovery automatically detects parent + child POMs and bundles them.
  # Child modules resolve their parent locally — no Maven Central round-trip.
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
    fail-on: none  # always exit 0; results still in artifacts
```

## License

Apache-2.0. See [LICENSE](LICENSE).

## Privacy

depproof makes outbound calls to the following public APIs (and nothing else):

- `repo.maven.apache.org` — Maven Central, for transitive resolution
- `registry.npmjs.org` — npm registry, for npm transitive resolution
- `api.osv.dev` — OSV.dev vulnerability database, for CVE lookups
- `api.clearlydefined.io` — ClearlyDefined.io license metadata (fallback when SPDX corpus doesn't match)

No telemetry. No phone-home. No API keys.

Source code: [github.com/depproof/depproof](https://github.com/depproof/depproof) — audit the [Dockerfile](https://github.com/depproof/depproof/blob/main/backend/Dockerfile) and the [action.yml](./action.yml) (~80 lines combined) to verify.
