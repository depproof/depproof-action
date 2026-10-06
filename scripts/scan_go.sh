# shellcheck shell=bash
# Sourced by scan.sh: Go online resolution. When `go` is on the runner, the resolved graph is written as
# `go.deps.json` next to each `go.mod`, and discovery prefers it over `go.mod`.
#
# TWO FILES, because neither can be the other:
#
#   `go.deps.json` <- `go list -m -json all` — the COMPONENT SET. The exact build list, every
#      module the build requires, with direct/indirect and `replace` already resolved by Go.
#   `go.pkgs.json` <- `go list -deps -test -json ./...` — the SCOPE. One object per package,
#      including the ones pulled in only to compile tests, which is the only place Go records
#      what ships: `go.mod` does not mark test requirements and `go list -m` lists modules,
#      not packages, so neither can answer it.
#
# BOTH, rather than preferring the package one, because they are not nested. The package stream covers
# only modules supplying a package the build actually LOADS, and omits every module that is required but
# never imported from — on a large module graph that can be most of them. It is GOOS-specific besides,
# since `go list` resolves build constraints, so a Linux runner and a macOS runner do not agree on it.
# Preferring it would buy scope and silently pay coverage; emitting both keeps the full component set
# and scopes what it can.
#
# The engine merges them: modules the package stream never mentions report no scope rather than a
# guess. `go.pkgs.json` is a sidecar, not a manifest — nothing scans it on its own.
#
# The package command type-checks, so it fails on a tree that does not compile while the module graph
# still resolves. That is why it is emitted best-effort and on top: a repository that cannot build
# should lose the scope, not the whole dependency graph.
#
# `-mod=mod` stays, because resolution fails without it on trees whose go.sum is incomplete, but it may
# rewrite go.mod and go.sum. Each module directory is backed up first and put back by the trap after the
# scan, and the generated files are removed then too, so the checkout ends as it started even when the
# job fails. A directory that cannot be backed up is not resolved: an untouched tree comes first.

go_backup() { # <dir>
  local slot="${GO_BACKUP}/${#GO_DIRS[@]}" f
  mkdir "$slot" 2>/dev/null || return 1
  for f in "${GO_FILES[@]}"; do
    if [ -e "$1/$f" ] && ! cp -p "$1/$f" "$slot/$f" 2>/dev/null; then
      rm -rf "$slot"
      return 1
    fi
  done
  GO_DIRS+=("$1")
}

resolve_go_modules() {
  [ "${INPUT_GO_ONLINE:-true}" = "true" ] || return 0
  if ! command -v go >/dev/null 2>&1; then
    echo "depproof-action: 'go' not on the runner — Go modules use the static go.mod parse"
    return 0
  fi
  GO_BACKUP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/depproof-go.XXXXXX" 2>/dev/null)" || GO_BACKUP=""
  while IFS= read -r gomod; do
    gdir="$(dirname "$gomod")"
    if [ -z "$GO_BACKUP" ] || ! go_backup "$gdir"; then
      echo "::warning::depproof-action: could not back up ${gdir}/go.mod before resolving it — using the static go.mod parse"
      continue
    fi
    if ( cd "$gdir" && GOFLAGS=-mod=mod go list -m -json all > go.deps.json 2>/dev/null ) \
       && [ -s "${gdir}/go.deps.json" ]; then
      if ( cd "$gdir" && GOFLAGS=-mod=mod go list -deps -test -json ./... > go.pkgs.json 2>/dev/null ) \
         && [ -s "${gdir}/go.pkgs.json" ]; then
        echo "depproof-action: resolved ${gdir}/go.mod — full module list, with scope"
      else
        rm -f "${gdir}/go.pkgs.json"
        echo "depproof-action: resolved ${gdir}/go.mod — full module list, no scope ('go list -deps' failed; does the tree build?)"
      fi
    else
      rm -f "${gdir}/go.deps.json" "${gdir}/go.pkgs.json"
      echo "::warning::depproof-action: 'go list' failed in ${gdir} — using the static go.mod parse"
    fi
  done < <(find "${ROOT}" -name go.mod -not -path '*/vendor/*' 2>/dev/null)
}
