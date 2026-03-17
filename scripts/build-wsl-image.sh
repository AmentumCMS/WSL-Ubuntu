#!/usr/bin/env bash
# =============================================================================
# build-wsl-image.sh
#
# Orchestrates the full WSL Ubuntu image build:
#   1. Pulls Ubuntu base image
#   2. Starts an ephemeral build container
#   3. Attaches Ubuntu Pro (optional)
#   4. Applies org customizations (packages, files, hook scripts)
#   5. Applies STIG/SCAP hardening via OpenSCAP
#   6. Collects SCAP compliance results
#   7. Exports the container as a WSL-importable rootfs tarball
#   8. Commits the container as a Docker image for GHCR publishing
#
# Environment variables (set by CI or caller):
#   UBUNTU_VERSION   — e.g. "22.04"  (default: 22.04)
#   STIG_PROFILE     — SCAP profile ID (default: stig)
#   ARTIFACT_BASE    — output filename stem (default: wsl-ubuntu-<version>-local)
#   ENABLE_UBUNTU_PRO — "true" to attach Ubuntu Pro (default: false)
#   UBUNTU_PRO_TOKEN — Ubuntu Pro attach token (required if ENABLE_UBUNTU_PRO=true)
# =============================================================================
set -euo pipefail

UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"
STIG_PROFILE="${STIG_PROFILE:-xccdf_org.ssgproject.content_profile_stig}"
ARTIFACT_BASE="${ARTIFACT_BASE:-wsl-ubuntu-${UBUNTU_VERSION}-local}"
ENABLE_UBUNTU_PRO="${ENABLE_UBUNTU_PRO:-false}"

CONTAINER_NAME="wsl-build-$$"
ARTIFACTS_DIR="$(pwd)/artifacts"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { echo "[build] $*"; }
warn() { echo "[build] WARNING: $*" >&2; }

cleanup() {
  log "Cleaning up build container..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Directories ─────────────────────────────────────────────────────────────
mkdir -p "${ARTIFACTS_DIR}/scap-results"

# ─── 1. Pull base image ───────────────────────────────────────────────────────
log "Pulling ubuntu:${UBUNTU_VERSION}..."
docker pull "ubuntu:${UBUNTU_VERSION}"

# ─── 2. Start build container ─────────────────────────────────────────────────
log "Starting build container: ${CONTAINER_NAME}"
docker run -d \
  --name "${CONTAINER_NAME}" \
  --cap-add=SYS_PTRACE \
  --security-opt apparmor=unconfined \
  --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-local/wsl-ubuntu}" \
  --label "org.opencontainers.image.description=Hardened Ubuntu ${UBUNTU_VERSION} for WSL2" \
  --label "org.opencontainers.image.licenses=MIT" \
  "ubuntu:${UBUNTU_VERSION}" \
  sleep infinity

log "Container ${CONTAINER_NAME} is running"

# ─── 3. Bootstrap apt inside the container ────────────────────────────────────
log "Bootstrapping package manager..."
docker exec "${CONTAINER_NAME}" bash -c "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-utils \
    sudo \
    locales
  locale-gen en_US.UTF-8
"

# ─── 4. Ubuntu Pro (optional) ─────────────────────────────────────────────────
if [[ "${ENABLE_UBUNTU_PRO}" == "true" ]]; then
  if [[ -z "${UBUNTU_PRO_TOKEN:-}" ]]; then
    warn "ENABLE_UBUNTU_PRO=true but UBUNTU_PRO_TOKEN is not set; skipping Pro attachment"
  else
    log "Attaching Ubuntu Pro..."
    docker exec "${CONTAINER_NAME}" bash -c "
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y ubuntu-advantage-tools
      pro attach '${UBUNTU_PRO_TOKEN}'
      # Enable Extended Security Maintenance (ESM) repos
      pro enable esm-infra  --assume-yes 2>/dev/null || true
      pro enable esm-apps   --assume-yes 2>/dev/null || true
    "
    log "Ubuntu Pro attached successfully"
  fi
else
  log "Ubuntu Pro not requested; skipping"
fi

# ─── 5. Copy scripts and customizations into container ────────────────────────
log "Copying build scripts and customizations..."
docker exec "${CONTAINER_NAME}" mkdir -p /opt/build /opt/customizations
docker cp "${SCRIPT_DIR}/." "${CONTAINER_NAME}:/opt/build/"
docker cp "${REPO_ROOT}/customizations/." "${CONTAINER_NAME}:/opt/customizations/"

# ─── 6. Apply org customizations ──────────────────────────────────────────────
log "Applying customizations..."
docker exec \
  -e UBUNTU_VERSION="${UBUNTU_VERSION}" \
  "${CONTAINER_NAME}" \
  bash /opt/build/apply-customizations.sh

# ─── 7. STIG/SCAP hardening ───────────────────────────────────────────────────
log "Applying STIG/SCAP hardening (profile: ${STIG_PROFILE})..."
docker exec \
  -e UBUNTU_VERSION="${UBUNTU_VERSION}" \
  -e STIG_PROFILE="${STIG_PROFILE}" \
  "${CONTAINER_NAME}" \
  bash /opt/build/harden.sh

# ─── 8. Collect SCAP results from container ───────────────────────────────────
log "Collecting SCAP results..."
docker cp "${CONTAINER_NAME}:/opt/scap-results/." "${ARTIFACTS_DIR}/scap-results/" 2>/dev/null \
  || warn "No SCAP results found at /opt/scap-results"

# ─── 9. Clean up build artifacts inside container ─────────────────────────────
log "Cleaning up build artifacts inside container..."
docker exec "${CONTAINER_NAME}" bash -c "
  set -euo pipefail
  # Remove build scripts and caches
  rm -rf /opt/build /opt/customizations
  # Clear apt caches
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
  # Clear bash history
  history -c 2>/dev/null || true
  rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true
"

# ─── 10. Export WSL rootfs tarball ────────────────────────────────────────────
OUTPUT_TAR="${ARTIFACTS_DIR}/${ARTIFACT_BASE}.tar.gz"
log "Exporting WSL rootfs to ${OUTPUT_TAR}..."
docker export "${CONTAINER_NAME}" | gzip --best > "${OUTPUT_TAR}"

TARBALL_SIZE=$(du -sh "${OUTPUT_TAR}" | cut -f1)
log "WSL tarball created: ${OUTPUT_TAR} (${TARBALL_SIZE})"

# ─── 11. Commit Docker image for GHCR publishing ──────────────────────────────
log "Committing Docker image wsl-ubuntu:local..."
docker commit \
  --change 'CMD ["/bin/bash"]' \
  --change "LABEL org.opencontainers.image.title=\"WSL Ubuntu ${UBUNTU_VERSION}\"" \
  --change "LABEL org.opencontainers.image.description=\"Hardened Ubuntu ${UBUNTU_VERSION} WSL2 image with STIG hardening\"" \
  "${CONTAINER_NAME}" \
  wsl-ubuntu:local

log "Build complete."
log "  WSL tarball : ${OUTPUT_TAR}"
log "  Docker image: wsl-ubuntu:local"
log "  SCAP results: ${ARTIFACTS_DIR}/scap-results/"
