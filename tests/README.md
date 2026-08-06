# Tests

```bash
python3 -m unittest discover -s tests -v
```

No dependencies, no network, no Docker — they run in milliseconds against fixtures that mirror real
engine output.

## What is under test

Only `scripts/render_summary.py`, which turns a completed scan into the markdown a developer reads on
the workflow run page and in a pull request comment.

The scan itself is not tested here. It belongs to the engine, which has its own suite and its own
repository — by the time this code runs, the scan has finished and produced a correct answer. **The
single job of everything in `scripts/` is to display that answer without changing it, contradicting
it, or making its absence look like success.** Every test below defends one of those three.

## Why a display layer needs tests at all

Because the failure mode is not a crash.

A crash is loud and gets fixed. A summary that renders `0%` for a real exploitation score, or a green
headline over a scan that never ran, is quiet — and it is read at exactly the moment someone is
deciding whether to merge. Wrong output here is more dangerous than no output, because a reassuring
green block is the thing people stop checking.

This repository also has no build step and nothing that runs it before a consumer does. A break does
not fail here; it fails in someone else's pipeline, at `@v1`, for everyone at once.

## How the tests are grouped

Each class is a property being protected, not a function being covered.

| Class | Protects |
|---|---|
| `VerdictSelection` | The headline matches the build's real outcome |
| `AbsenceIsNotSafety` | Not-checked, not-scanned and no-data never render as clean |
| `FindingOrder` | The most urgent finding is the one people read first |
| `CommentIdentity` | The PR comment updates in place instead of accumulating |
| `Formatting` | Numbers are legible and do not mislead at the extremes |

### The two that carry the most weight

**`VerdictSelection`.** The engine emits two signals that legitimately disagree. The exit code is the
gate *with* waivers applied — the build's real outcome. `summary.json`'s `fail` is the gate *without*
them, kept raw so a hub ingesting it sees unsuppressed truth. A centrally-waived finding therefore
leaves `fail: true` on disk while the build exits `0`. Render the file's flag and you print
**❌ Failed** directly beside a green check. The renderer takes its verdict from the exit code, always,
and says so explicitly when the two differ.

**`AbsenceIsNotSafety`.** The recurring defect class across this whole product — the same shape as the
engine once recording `kev=false` for Log4Shell when it meant *"not checked"*, and the hub coercing a
null EPSS score to zero. Three different states get conflated into "fine": no data, unchecked data,
and genuinely-zero data. They are not the same claim and must not look the same.

## Adding a test

State the property in the method name as a sentence, and put *why it matters* in the body rather than
restating the assertion. `test_known_exploited_outranks_a_higher_severity_that_is_not` says what would
break; a comment explains that sorting by severity would invert the argument the product is built on.
