# shellcheck shell=bash
# shellcheck disable=SC2034  # state shared with the other steps scan.sh sources, read there
# Sourced by scan.sh: the state every later step registers for removal, and the trap that removes it.
#
# Material this run creates outside its own outputs: the signing key, the hub credential and the hub's
# responses (all under RUNNER_TEMP), and the files Go resolution writes into the checkout. A trap removes
# or restores all of it, because a failed or cancelled job must leave no secret on the runner and no edit
# in the tree -- a later step may upload, commit or cache either.

KEY_DIR=""
HUB_TMP=""
HUB_MOUNT=0
GO_BACKUP=""
GO_DIRS=()
# Every file Go resolution can create or rewrite. One that existed is put back as it was; one that did
# not is removed, so a go.deps.json the repository committed itself survives.
GO_FILES=(go.mod go.sum go.deps.json go.pkgs.json)
DOCKER_MOUNTS=()

restore_go_tree() {
  local i f
  [ -n "$GO_BACKUP" ] || return 0
  for i in "${!GO_DIRS[@]}"; do
    for f in "${GO_FILES[@]}"; do
      if [ -e "${GO_BACKUP}/${i}/${f}" ]; then
        cp -p "${GO_BACKUP}/${i}/${f}" "${GO_DIRS[$i]}/${f}"
      else
        rm -f "${GO_DIRS[$i]}/${f}"
      fi
    done
  done
  rm -rf "$GO_BACKUP"
  GO_BACKUP=""
}

remove_temporaries() {
  restore_go_tree
  if [ -n "$KEY_DIR" ]; then rm -rf "$KEY_DIR"; KEY_DIR=""; fi
  if [ -n "$HUB_TMP" ]; then rm -rf "$HUB_TMP"; HUB_TMP=""; fi
}

on_exit() {
  local rc=$?
  set +e
  remove_temporaries
  exit "$rc"
}

install_cleanup_trap() {
  trap on_exit EXIT
  # A cancelled job is signalled, not exited; turning the signal into an exit is what runs the trap above.
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
