#!/usr/bin/env python3
"""Tests for the merge-request comment embedded in examples/gitlab/depproof.gitlab-ci.yml.

The script under test lives *inside* the template, because `include: remote:` fetches exactly one
file and a CI job that downloads code at run time to execute it is the thing this product warns
people about. That leaves one source of truth and this harness, which extracts the heredoc from the
YAML and runs it against a stub GitLab API. Testing a copy would test the copy.

What is tested here is only the wrapper's half — one note per MR rather than one per push, and that
nothing it can hit turns into a failed build. What the summary *says* is rendered by the engine and
tested there.

Run: python3 tests/test_gitlab_mr_note.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "examples" / "gitlab" / "depproof.gitlab-ci.yml"

passed = failed = 0


def check(name, condition, why):
    global passed, failed
    if condition:
        print(f"  ok   {name}")
        passed += 1
    else:
        print(f"  FAIL {name} — {why}")
        failed += 1


def extract_script():
    """Pull the `python3 - depproof-summary.md <<'PY' ... PY` body out of the template."""
    text = TEMPLATE.read_text()
    m = re.search(r"<<'PY'\n(.*?)\n\s*PY\n", text, re.S)
    if not m:
        sys.exit("could not find the embedded PY heredoc in the template — did the delimiter change?")
    # The heredoc is indented inside the YAML block scalar; strip the common indent.
    lines = m.group(1).split("\n")
    indent = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
    return "\n".join(l[indent:] if l.strip() else "" for l in lines)


class Stub(BaseHTTPRequestHandler):
    """A GitLab notes API with just enough behaviour to be lied to convincingly."""

    notes = []          # existing notes returned by GET
    calls = []          # (method, path, body) actually made
    pages = False       # when True, the marker note only appears on page 2
    endless = False     # when True, every page claims another page after it
    fail = False        # when True, every call 500s

    def log_message(self, *_):
        pass

    def _send(self, code, payload, headers=None):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n).decode()) if n else None

    def do_GET(self):
        Stub.calls.append(("GET", self.path, None))
        if Stub.fail:
            return self._send(500, {"message": "boom"})
        # Parsed, not substring-matched: `page=1` is also a substring of `per_page=100`, and the
        # first version of this stub therefore answered every request as page 1 — an endless "there
        # is another page" that hung the suite. The bug was the stub's; the guard it prompted in the
        # script is real, and `endless` below is what pins it.
        query = dict(parse_qsl(urlsplit(self.path).query))
        page = query.get("page", "1")
        if Stub.endless:
            return self._send(200, [], {"X-Next-Page": "2"})
        if Stub.pages:
            first = page == "1"
            return self._send(200, [] if first else Stub.notes, {"X-Next-Page": "2" if first else ""})
        self._send(200, Stub.notes, {"X-Next-Page": ""})

    def do_POST(self):
        Stub.calls.append(("POST", self.path, self._read()))
        self._send(201 if not Stub.fail else 500, {"id": 99})

    def do_PUT(self):
        Stub.calls.append(("PUT", self.path, self._read()))
        self._send(200 if not Stub.fail else 500, {"id": 42})


def run(script, summary_text, env_extra=None, notes=None, pages=False, fail=False, endless=False):
    Stub.notes = notes or []
    Stub.calls = []
    Stub.pages = pages
    Stub.endless = endless
    Stub.fail = fail

    server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory() as d:
            summary = Path(d) / "depproof-summary.md"
            if summary_text is not None:
                summary.write_text(summary_text)
            script_file = Path(d) / "mr_note.py"
            script_file.write_text(script)

            env = {
                **os.environ,
                "CI_API_V4_URL": f"http://127.0.0.1:{server.server_address[1]}/api/v4",
                "CI_PROJECT_ID": "77",
                "CI_MERGE_REQUEST_IID": "5",
                "DEPPROOF_GITLAB_TOKEN": "t0ken",
                "CI_PIPELINE_URL": "https://gitlab.example.com/p/-/pipelines/1",
                **(env_extra or {}),
            }
            proc = subprocess.run(
                [sys.executable, str(script_file), str(summary)],
                capture_output=True, text=True, env=env,
            )
            return proc, list(Stub.calls)
    finally:
        server.shutdown()


def main():
    script = extract_script()
    summary = "## depproof — ❌ Failed\n\nGate rule(s) **severity>=critical** matched."

    print("\nfirst run on a merge request")
    proc, calls = run(script, summary)
    posts = [c for c in calls if c[0] == "POST"]
    check("posts a note", len(posts) == 1, f"expected one POST, got {calls}")
    body = posts[0][2]["body"] if posts else ""
    check("marker is present so the next run can find it", body.startswith("<!-- depproof -->"),
          "without the marker every push appends another copy")
    check("carries the engine's summary unchanged", "severity>=critical" in body, "summary lost")
    check("links back to the pipeline", "pipelines/1" in body, "no way back to the run")
    check("exit 0", proc.returncode == 0, f"rc={proc.returncode} {proc.stderr}")

    print("\nsecond run on the same merge request")
    existing = [{"id": 42, "body": "<!-- depproof -->\nold body"}]
    proc, calls = run(script, summary, notes=existing)
    check("updates in place", [c for c in calls if c[0] == "PUT"], f"expected a PUT, got {calls}")
    check("does not also post", not [c for c in calls if c[0] == "POST"],
          "a second comment per push is how this gets muted")
    check("targets the note it found", any("/notes/42" in c[1] for c in calls if c[0] == "PUT"),
          "updated the wrong note")

    print("\nsomeone else's comments are not ours")
    proc, calls = run(script, summary, notes=[{"id": 7, "body": "LGTM"}])
    check("posts rather than hijacking another note", [c for c in calls if c[0] == "POST"],
          "would have edited a human's comment")

    print("\na busy review pushes our note off page 1")
    proc, calls = run(script, summary, notes=existing, pages=True)
    check("follows pagination", [c for c in calls if c[0] == "PUT"],
          "stopping at page 1 posts a duplicate on every long-running MR")

    print("\nan API that always claims another page")
    proc, calls = run(script, summary, endless=True)
    check("stops walking", len([c for c in calls if c[0] == "GET"]) <= 20,
          "the loop's exit condition is a header the server controls; unbounded, a CI job spins to timeout")
    check("still comments once it stops", [c for c in calls if c[0] == "POST"], "gave up entirely")
    check("exit 0", proc.returncode == 0, f"rc={proc.returncode}")

    print("\nthe scan produced no summary")
    proc, calls = run(script, None)
    body = next((c[2]["body"] for c in calls if c[0] == "POST"), "")
    check("still comments", bool(body), "silence reads as nothing-to-report")
    check("says it is not a clean result", "not a clean result" in body, "absence presented as safety")
    check("never reads as a pass", "✅" not in body and "Passed" not in body, "a dead scan looking green")

    proc, calls = run(script, "   \n")
    check("treats an empty summary the same as a missing one",
          any("No summary produced" in (c[2] or {}).get("body", "") for c in calls if c[0] == "POST"),
          "empty file rendered as clean")

    print("\nnothing here can fail a build")
    proc, _ = run(script, summary, env_extra={"DEPPROOF_GITLAB_TOKEN": ""})
    check("exits 0 with no token", proc.returncode == 0, f"rc={proc.returncode}")
    proc, _ = run(script, summary, env_extra={"CI_MERGE_REQUEST_IID": ""})
    check("exits 0 outside a merge request", proc.returncode == 0, f"rc={proc.returncode}")
    proc, _ = run(script, summary, fail=True)
    check("exits 0 when the API errors", proc.returncode == 0, f"rc={proc.returncode} {proc.stderr}")
    check("says why on stderr", "could not post" in proc.stderr or "skipping" in proc.stderr,
          "a silent failure leaves nobody knowing the comment is missing")
    proc, _ = run(script, summary, env_extra={"CI_API_V4_URL": "http://127.0.0.1:1/api/v4"})
    check("exits 0 when the API is unreachable", proc.returncode == 0, f"rc={proc.returncode}")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
