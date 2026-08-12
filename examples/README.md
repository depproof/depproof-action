# Examples

Working configurations to **copy into your own repository** and edit. Nothing here is fetched or
included at run time — a pipeline should not need to reach a host of ours to know how to build, and
plenty of self-hosted CI cannot.

Each file is [`basic.yml`](github/basic.yml) plus one idea, so start there and take what you need.

## GitHub Actions

| File | The question it answers |
|---|---|
| [`github/basic.yml`](github/basic.yml) | I just want it running. Scan every manifest, fail on a critical, keep the reports. |
| [`github/scheduled.yml`](github/scheduled.yml) | What about code nobody is changing? A daily run, and why a PR-only scan misses most new risk. |
| [`github/gradle-exact-graph.yml`](github/gradle-exact-graph.yml) | My Gradle numbers look too low. Produce the resolved graph, single- and multi-module, then gate on it. |
| [`github/monorepo.yml`](github/monorepo.yml) | One repository, many services. Exclude subtrees, or one scan and one gate per team. |
| [`github/hub.yml`](github/hub.yml) | Estate-wide questions. Push to a self-hosted hub, apply KEV/EPSS at scan time, honour central waivers. |

## GitLab CI

| File | The question it answers |
|---|---|
| [`gitlab/depproof.gitlab-ci.yml`](gitlab/depproof.gitlab-ci.yml) | We are not on GitHub. The same scan, gate and summary, with a merge request comment that updates in place. |

The scan, the gate, the SBOMs and the summary are all produced by the scanner, which knows nothing
about any CI — a wrapper only decides where the output is displayed (ADR-0006, amended). So the
GitLab job is not a port of the Action; it is the same container with the same arguments. Anything
that behaves differently between the two is a bug in a wrapper, not a difference in what depproof
found.

For any other CI, the whole job is one `docker run` — see the
[engine README](https://github.com/depproof/depproof#any-ci--gitlab-jenkins-anything-that-runs-a-container).

## Two defaults worth changing deliberately

**`retention-days`** on the artifact upload. Every example sets it. A daily scan writes an SBOM set
per repository per day, and GitHub's 90-day default is storage nobody decided to spend.

**`require-fidelity`** is `off`. The scan always *says* when it could not read a resolved graph — on
the run page, in the PR comment, and as a warning annotation — but only this input makes that fail a
build. It is off by default because it can fail a build whose findings list is empty, which is
exactly when it matters and exactly the kind of surprise nobody should be opted into.
