# Contributing

- **Shell:** `scan.sh` and `scripts/` must pass `shellcheck -S warning`. Repeated blocks become functions,
  and a script that grows past 300 lines is split into `scripts/`.
- **Inputs** reach scripts only through `env:` in `action.yml`, never through `${{ }}` inside `run:`.
- **Secrets** never go on a command line or into the workspace; temporary key material is removed in a
  `trap`, including when a job is cancelled.
- **Comments** explain why the code is the way it is. Keep history out of them; it belongs in the commit
  message.
- **Tests:** every change that alters behaviour adds a case to `tests/`. Run them all before pushing:

      for t in tests/*.sh; do bash "$t" || exit 1; done
      python3 tests/test_gitlab_mr_note.py
