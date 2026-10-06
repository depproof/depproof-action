# shellcheck shell=bash
# Sourced by scan.sh: signing material, the container run itself, and attaching the SBOM to a release.

# Pulls and runs the Scanner, leaving its exit code in DEPPROOF_EXIT.
#
# The image is a multi-arch manifest at ghcr.io/depproof/depproof:v1 unless `scanner-image` says
# otherwise (a digest pin, an internal mirror, a pre-release). `--rm` removes the container after exit.
# The workspace is mounted read-write so SBOMs can be written back; depproof doesn't modify the source.
#
# The exit code is captured rather than allowed to propagate, because the surfaces after the scan
# matter MOST when it fails — letting `set -e` abort here would mean a failing build renders nothing.
# scan.sh re-raises it verbatim at the end, so exit codes 1/2/3/4 keep their distinct meanings.
run_scanner() {
  SCANNER_IMAGE="${INPUT_SCANNER_IMAGE:-}"
  SCANNER_IMAGE="${SCANNER_IMAGE:-ghcr.io/depproof/depproof:v1}"
  set +e
  # SBOM author and signing. The private key is written to the runner's temporary directory — outside
  # the workspace, so no later upload step can sweep it up — mounted read-only, and deleted as soon as
  # the scan returns (or by the trap, if the job is cancelled first).
  if [ -n "${INPUT_SBOM_AUTHOR:-}" ]; then
    ARGS+=("--sbom-author" "${INPUT_SBOM_AUTHOR}")
  fi
  if [ -n "${DEPPROOF_SIGN_KEY:-}" ] && ! KEY_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/depproof-keys.XXXXXX" 2>/dev/null)"; then
    # Never fall back to writing the key somewhere else: no private directory, no signature.
    KEY_DIR=""
    echo "::warning::depproof-action: could not create a private directory for the signing key — the SBOM will not be signed."
  elif [ -n "${DEPPROOF_SIGN_KEY:-}" ]; then
    ( umask 077; printf '%s\n' "${DEPPROOF_SIGN_KEY}" > "${KEY_DIR}/sign-key.pem" )
    DOCKER_MOUNTS+=("-v" "${KEY_DIR}:/run/depproof-keys:ro")
    ARGS+=("--sign-key" "/run/depproof-keys/sign-key.pem")
    if [ -n "${INPUT_SIGN_PUBLIC_KEY:-}" ]; then
      printf '%s\n' "${INPUT_SIGN_PUBLIC_KEY}" > "${KEY_DIR}/sign-public-key.pem"
      ARGS+=("--sign-public-key" "/run/depproof-keys/sign-public-key.pem")
    fi
  elif [ -n "${INPUT_SIGN_PUBLIC_KEY:-}" ]; then
    echo "::warning::depproof-action: sign-public-key is set without sign-key — the SBOM will not be signed."
  fi
  if [ "$HUB_MOUNT" = "1" ]; then
    DOCKER_MOUNTS+=("-v" "${HUB_TMP}/responses:/run/depproof-hub:ro")
  fi

  docker run --rm \
    "${DOCKER_ENV[@]}" \
    "${DOCKER_MOUNTS[@]}" \
    -v "${GITHUB_WORKSPACE}":/workspace \
    -w /workspace \
    "${SCANNER_IMAGE}" \
    "${ARGS[@]}"
  # shellcheck disable=SC2034  # read by the publish steps and re-raised by scan.sh
  DEPPROOF_EXIT=$?
  set -e
  remove_temporaries || true
}

# The original travels with the release: on a tag build, attach the SBOM files the scan just wrote to
# the GitHub release for that tag. Best-effort — the verdict is already decided.
attach_release_sbom() {
  if [ "${INPUT_RELEASE_SBOM:-false}" = "true" ] && [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    shopt -s nullglob
    SBOM_FILES=("${OUTPUT_DIR}"/depproof-sbom*.json)
    shopt -u nullglob
    if [ "${#SBOM_FILES[@]}" -eq 0 ]; then
      echo "::warning::depproof-action: release-sbom is set but the scan wrote no SBOM file to attach."
    elif ! gh release upload "${GITHUB_REF_NAME}" "${SBOM_FILES[@]}" --clobber --repo "${GITHUB_REPOSITORY:-}" >/dev/null 2>&1; then
      echo "::warning::depproof-action: could not attach the SBOM to release ${GITHUB_REF_NAME} (does the release exist, and does the job have contents: write?)."
    else
      echo "depproof-action: attached ${#SBOM_FILES[@]} SBOM file(s) to release ${GITHUB_REF_NAME}"
    fi
  fi
}
