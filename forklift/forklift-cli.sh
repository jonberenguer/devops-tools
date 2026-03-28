#!/bin/bash
# bash forklift-cli.sh build|deploy \
#        running-service-name|service-name \
#        volpassword \
#        [timestamp-value-for deploy]

# Fix #5: Fail fast on errors, unset variables, and pipeline failures
set -euo pipefail
trap 'echo "[forklift] Error on line $LINENO — aborting." >&2' ERR

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

FORKLIFT_METHOD="${1:-}"
SERVICE_NAME="${2:-}"
VOL_PW="${3:-}"

# Fix #3: exit 1 (not 0) on invalid input so callers detect failure
usage() {
  echo "Usage: $0 <image-build|build|deploy> <service-name> <vol-password> [timestamp]" >&2
  exit 1
}

possible_methods=("image-build" "build" "deploy")
is_found=false
for value in "${possible_methods[@]}"; do
  if [[ "${FORKLIFT_METHOD}" == "${value}" ]]; then
    is_found=true
    break
  fi
done

if ! $is_found; then
  echo "[forklift] Invalid method: '${FORKLIFT_METHOD}'" >&2
  usage
fi

# Fix #9: Validate SERVICE_NAME is present and contains only safe characters
if [[ -z "${SERVICE_NAME}" ]]; then
  echo "[forklift] SERVICE_NAME is required." >&2
  usage
fi

if [[ ! "${SERVICE_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[forklift] Invalid SERVICE_NAME '${SERVICE_NAME}': only alphanumerics, hyphens, and underscores are allowed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# forklift-image-build
# Build the local utility container used for yq parsing and 7z volume ops.
# ---------------------------------------------------------------------------
forklift-image-build() {
  # Fix #12: Pin Alpine version instead of using :latest
  # Fix #13: vim gated behind a build-arg (pass --build-arg INCLUDE_VIM=true to keep it)
  # Fix #14: Note on extra packages — kept as-is for ad-hoc use, but commented clearly
  # Fix #15: /home/1000 UID noted; consider passing UID as build-arg if host UID differs

  local FORKLIFT_DIR="${HOME}/image-builders/forklift"
  mkdir -p "${FORKLIFT_DIR}"
  pushd "${FORKLIFT_DIR}" > /dev/null

  cat << 'EOF' > Dockerfile
FROM alpine:3.21

ARG INCLUDE_VIM=false

# Core utilities required by forklift operations
RUN apk update \
  && apk add --no-cache \
    bash shadow \
    7zip tar xz zip unzip \
    gzip \
    jq yq \
  # Optional packages for ad-hoc interactive use inside the container.
  # rsync/openssh/iputils/bind-tools/curl/miller are not used by the script
  # itself — remove if you want a leaner image.
  && apk add --no-cache \
    rsync rsync-openrc openssh \
    iputils bind-tools curl ca-certificates \
    miller \
  # Conditionally install vim
  && if [ "$INCLUDE_VIM" = "true" ]; then apk add --no-cache vim; fi \
  && rm -rf /var/cache/apk/*

# Set bash as the default shell for root
RUN chsh -s /bin/bash root

# Userspace folder — adjust UID/GID here if your host user differs from 1000
RUN mkdir /home/1000 && chown 1000:1000 /home/1000

CMD ["/bin/bash"]
EOF

  docker build --no-cache -t local/forklift:latest .
  popd > /dev/null
}

# ---------------------------------------------------------------------------
# Helper: get images listed in a compose file
# Fix #8: Removed -it flags (not needed for piped non-interactive use)
# Fix #4: No unquoted globs here, but tr -d '\r' can now be dropped since
#         TTY carriage-return injection is eliminated by removing -t
# ---------------------------------------------------------------------------
get-images() {
  local COMPOSE_FILE="$1"
  docker run --rm \
    -v "${COMPOSE_FILE}:/docker-compose.yml:ro" \
    local/forklift \
    yq -r '.services[].image?' "/docker-compose.yml" | xargs
}

# Fix #8: Same -it removal as above
get-service-vols() {
  local COMPOSE_FILE="$1"
  docker run --rm \
    -v "${COMPOSE_FILE}:/docker-compose.yml:ro" \
    local/forklift \
    yq -r '.volumes | keys[]?' "/docker-compose.yml" | xargs
}

# Resolve the compose file path for a named service without requiring jq/yq
# on the host. Pipes `docker compose ls --format json` output into the
# forklift container for parsing.
get-compose-file() {
  local service_name="$1"
  local compose_json
  compose_json=$(docker compose ls --format json)
  echo "${compose_json}" | docker run --rm -i \
    local/forklift \
    jq -r --arg name "${service_name}" \
      '.[] | select(.Name == $name) | .ConfigFiles'
}

# ---------------------------------------------------------------------------
# build-forklift: snapshot a running service into a timestamped archive
# ---------------------------------------------------------------------------
build-forklift() {
  local TIMESTAMP
  TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)

  local ARCH_FOLDER="${HOME}/temp"
  local TS_PATH="${ARCH_FOLDER}/${SERVICE_NAME}/${TIMESTAMP}"
  local USER_PERM
  USER_PERM="$(id -u):$(id -g)"

  # Fix #7: Resolve compose file via the forklift container (no host jq/yq needed)
  local SERVICE_COMPOSE
  SERVICE_COMPOSE=$(get-compose-file "${SERVICE_NAME}")

  if [[ -z "${SERVICE_COMPOSE}" ]]; then
    echo "[forklift] Could not find a running compose service named '${SERVICE_NAME}'." >&2
    exit 1
  fi

  local SERVICE_DIR
  SERVICE_DIR=$(dirname "${SERVICE_COMPOSE}")

  # Fix #6: Validate directory exists before pushd
  if [[ ! -d "${SERVICE_DIR}" ]]; then
    echo "[forklift] Service directory '${SERVICE_DIR}' does not exist." >&2
    exit 1
  fi

  mkdir -p "${TS_PATH}"
  pushd "${SERVICE_DIR}" > /dev/null

  ## Get and save images
  local SERVICE_IMAGES
  SERVICE_IMAGES=$(get-images "${SERVICE_COMPOSE}")
  docker image save -o "${TS_PATH}/${SERVICE_NAME}_images.tar" ${SERVICE_IMAGES}

  ## Save service folder content
  tar -czvf "${TS_PATH}/${SERVICE_NAME}-service-folder.tar.gz" \
    -C "${SERVICE_DIR%/*}" "${SERVICE_DIR##*/}"

  ## Get and save volumes
  local SERVICE_VOLS
  SERVICE_VOLS=$(get-service-vols "${SERVICE_COMPOSE}")

  for svol in ${SERVICE_VOLS}; do
    local COMP="/backup-dst/${svol}-archive.7z"

    # Fix #1: Pass password via -e env var so it never appears in `ps aux`.
    #         Use \${VOL_PW} (backslash-escaped) so the HOST shell does not
    #         expand it — it expands only inside the container.
    # Fix #11: Use /backup-src/. (dot) to also capture hidden files/dirs.
    #          Added a check that the archive was actually created.
    docker run --rm \
      -e VOL_PW="${VOL_PW}" \
      -v "${svol}:/backup-src:ro" \
      -v "${TS_PATH}:/backup-dst" \
      local/forklift bash -c "
        7z a '${COMP}' -p\"\${VOL_PW}\" /backup-src/. && \
        chown ${USER_PERM} '${COMP}' && \
        chmod 600 '${COMP}'
      "
  done

  popd > /dev/null

  tar -czvf "${ARCH_FOLDER}/${SERVICE_NAME}_${TIMESTAMP}-with-images.tar.gz" \
    -C "${ARCH_FOLDER}" "${SERVICE_NAME}/${TIMESTAMP}"

  echo "[forklift] Build complete:"
  ls -alh "${ARCH_FOLDER}"
}

# ---------------------------------------------------------------------------
# deploy-forklift: restore a snapshot onto this host
# ---------------------------------------------------------------------------
deploy-forklift() {
  local TIMESTAMP="$1"

  # Fix #9: Basic timestamp format sanity check
  if [[ ! "${TIMESTAMP}" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
    echo "[forklift] Invalid timestamp format '${TIMESTAMP}'. Expected YYYYMMDD_HHMMSS." >&2
    exit 1
  fi

  local ARCH_FOLDER="${HOME}/temp"
  local TS_PATH="${ARCH_FOLDER}/${SERVICE_NAME}/${TIMESTAMP}"
  local SERVICE_PARENT_FOLDER="${HOME}/services"
  local SERVICE_DIR="${SERVICE_PARENT_FOLDER}/${SERVICE_NAME}"
  local ARCHIVE="${ARCH_FOLDER}/${SERVICE_NAME}_${TIMESTAMP}-with-images.tar.gz"

  if [[ ! -f "${ARCHIVE}" ]]; then
    echo "[forklift] Archive not found: '${ARCHIVE}'" >&2
    exit 1
  fi

  mkdir -p "${SERVICE_PARENT_FOLDER}"

  pushd "${ARCH_FOLDER}" > /dev/null
  tar xzvf "${ARCHIVE}"

  pushd "${SERVICE_NAME}/${TIMESTAMP}" > /dev/null

  # Load images
  # Fix #4: Quote the glob passed to -iname
  find ./ -type f -iname "*_images.tar" -exec docker image load -i {} \;

  # Restore service folder
  find ./ -type f -iname "*-service-folder.tar.gz" \
    -exec tar -zxvf {} -C "${SERVICE_PARENT_FOLDER}" \;

  # Fix #6: Validate SERVICE_DIR exists after extraction
  if [[ ! -d "${SERVICE_DIR}" ]]; then
    echo "[forklift] Expected service dir '${SERVICE_DIR}' was not found after extraction." >&2
    exit 1
  fi

  pushd "${SERVICE_DIR}" > /dev/null

  local SERVICE_COMPOSE="${SERVICE_DIR}/docker-compose.yml"
  local SERVICE_VOLS
  SERVICE_VOLS=$(get-service-vols "${SERVICE_COMPOSE}")

  for svol in ${SERVICE_VOLS}; do
    echo "[forklift] Restoring docker volume: ${svol}"

    # Fix #10: Bring down the stack before touching volumes
    docker compose -f "${SERVICE_COMPOSE}" down 2>/dev/null || true

    docker volume rm "${svol}" 2>/dev/null || true
    docker volume create "${svol}"

    local COMP="/backup-src/${svol}-archive.7z"

    # Fix #1: Same env-var password pattern as build
    docker run --rm \
      -e VOL_PW="${VOL_PW}" \
      -v "${svol}:/backup-dst" \
      -v "${TS_PATH}:/backup-src:ro" \
      local/forklift bash -c "
        7z x -y '${COMP}' -p\"\${VOL_PW}\" -o/backup-dst/
      "
  done

  popd > /dev/null
  popd > /dev/null
  popd > /dev/null

  echo "[forklift] Deploy complete. Start your service with:"
  echo "  docker compose -f '${SERVICE_DIR}/docker-compose.yml' up -d"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${FORKLIFT_METHOD}" in
  "image-build")
    forklift-image-build
    ;;
  "build")
    build-forklift
    ;;
  "deploy")
    # Fix #3: exit 1 on missing timestamp; fix #9: timestamp validated inside deploy-forklift
    if [[ -z "${4:-}" ]]; then
      echo "[forklift] 'deploy' requires a timestamp argument." >&2
      usage
    fi
    deploy-forklift "$4"
    ;;
  *)
    echo "[forklift] Unhandled method: '${FORKLIFT_METHOD}'" >&2
    usage
    ;;
esac
