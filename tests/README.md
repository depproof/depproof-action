# Tests

```bash
bash tests/test_summary_body.sh
bash tests/test_coverage_annotation.sh
```

No dependencies, no network, no Docker.

## What is — and is not — tested here

Two scripts, and both exist for the same reason: a surface the engine cannot reach from inside the
container.

`scripts/summary_body.sh` decides what a CI surface displays when the engine did not produce a
summary.

`scripts/coverage_annotation.sh` lifts the engine's coverage caveat onto the **run page** as a
`::warning::`. The engine already renders that caveat into `depproof-summary.md`; a job summary and
a PR comment are both pages someone has to open, and a green build gets one glance at the run page.
What is tested here is only the Action's half — that a real gap becomes an annotation, that a
manifest the engine already excused (`superseded`) stays silent, and that no display problem can
fail a build. Whether something *is* a gap is the engine's judgement, read from
`depproof-summary.json` rather than re-derived, and tested there in `CoverageAdviceTest`.

Everything else about the summary — the verdict, how findings rank, how EPSS is formatted, whether
absent data reads as clean — is **rendered by the engine** and tested there, in `MarkdownReportTest`.
It moved (ADR-0006, amended) because none of it was ever a GitHub concern: those are statements about
how a finished scan must be presented, and they now hold for every CI rather than for this wrapper
alone. The engine is also the only component that knows the gate decision with waivers applied, which
is what makes the verdict trustworthy in the first place.

So this Action no longer renders anything. It runs the scan, then puts the engine's
`depproof-summary.md` where GitHub can show it — the workflow run page, and a pull request comment
that updates in place.

## Why the leftover deserves tests at all

Because of one case the engine cannot cover: **it produced no summary.**

The engine writes `depproof-summary.md` once a scan completes, so an absent or empty file means the
scan never got that far — bad arguments, an unreadable manifest, a crash. That is exactly when a
wrapper is most tempted to do nothing, and doing nothing leaves a blank run page. A blank run page
reads as *"nothing to report"*, when what actually happened is *"nothing was checked"*.

That is the same defect class the engine and hub were hardened against — the scanner once recording
`kev=false` when it meant "not checked", the hub coercing a null EPSS score to zero. Absence must
never present as safety. The tests here pin the wrapper end of it:

- an absent **or empty** summary produces an explicit "no summary produced" note, never silence
- that note says it is **not a clean result**, and never reads as a pass
- it reports the exit code, so the run page can be matched to the step log
- it still reaches the PR comment, since a reviewer is who most needs to know
- the script exits `0` regardless — a display problem must never change the build's verdict

The remaining tests cover comment identity: the marker must be the **first** line, or the Action
cannot find its own previous comment and every push appends another copy until people mute it.

## The rest of the Action

`action.yml` is a bash script inside a YAML block scalar — two languages that can each break
independently, in a repository with no build step, where a break does not fail here but in a
consumer's pipeline at `@v1`. CI therefore parses `action.yml` and runs `bash -n` over the embedded
script. That check earned itself immediately: multi-line Python in a `run:` block broke the YAML
during development.
