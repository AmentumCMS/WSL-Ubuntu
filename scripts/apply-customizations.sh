#!/usr/bin/env bash
# =============================================================================
# apply-customizations.sh  —  runs INSIDE the build container as root
#
# Applies organizational customizations to the WSL image:
#   1. Sources customizations/config.env for configuration variables
#   2. Installs packages listed in customizations/packages.list
#   3. Copies files from customizations/files/ into the container filesystem
#   4. Runs numbered hook scripts from customizations/scripts/ in order
#
# All customization sources live under /opt/customizations/ inside the container
# (mounted from the repo's customizations/ directory by the build script).
#
# Environment variables:
#   UBUNTU_VERSION  — e.g. "22.04" (default: 22.04)
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"
CUSTOM_DIR="/opt/customizations"

log()  { echo "[customize] $*"; }
warn() { echo "[customize] WARNING: $*" >&2; }

# ─── 1. Load configuration ────────────────────────────────────────────────────
if [ -f "${CUSTOM_DIR}/config.env" ]; then
  log "Loading customization config: ${CUSTOM_DIR}/config.env"
  # shellcheck source=/dev/null
  set -a; source "${CUSTOM_DIR}/config.env"; set +a
else
  warn "No config.env found; using defaults"
fi

# ─── 2. Install packages ──────────────────────────────────────────────────────
PACKAGES_FILE="${CUSTOM_DIR}/packages.list"

if [ -f "${PACKAGES_FILE}" ]; then
  log "Reading package list from ${PACKAGES_FILE}..."

  # Filter out comments and blank lines
  PACKAGES=$(grep -v '^\s*#' "${PACKAGES_FILE}" | grep -v '^\s*$' | tr '\n' ' ' || true)

  if [ -n "${PACKAGES}" ]; then
    log "Updating apt package index..."
    apt-get update -q

    log "Installing packages: ${PACKAGES}"
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends ${PACKAGES}
    log "Package installation complete"
  else
    log "Package list is empty; skipping package installation"
  fi
else
  warn "No packages.list found; skipping package installation"
fi

# ─── 3. Copy customization files ──────────────────────────────────────────────
FILES_DIR="${CUSTOM_DIR}/files"

if [ -d "${FILES_DIR}" ] && [ -n "$(ls -A "${FILES_DIR}" 2>/dev/null)" ]; then
  log "Copying customization files from ${FILES_DIR}/ to /..."
  cp -a "${FILES_DIR}/." /
  log "File copy complete"
else
  log "No customization files directory found or it is empty; skipping"
fi

# ─── 4. Run hook scripts ──────────────────────────────────────────────────────
SCRIPTS_DIR="${CUSTOM_DIR}/scripts"

if [ -d "${SCRIPTS_DIR}" ]; then
  HOOK_SCRIPTS=$(find "${SCRIPTS_DIR}" -maxdepth 1 -name '*.sh' | sort)

  if [ -n "${HOOK_SCRIPTS}" ]; then
    log "Running customization hook scripts..."
    for script in ${HOOK_SCRIPTS}; do
      script_name="$(basename "${script}")"
      log "  Running: ${script_name}"
      chmod +x "${script}"
      bash "${script}" || {
        warn "Script ${script_name} exited with non-zero status; continuing"
      }
      log "  Finished: ${script_name}"
    done
    log "All hook scripts complete"
  else
    log "No hook scripts found in ${SCRIPTS_DIR}"
  fi
else
  log "No scripts directory found; skipping hook scripts"
fi

# ─── 5. Final cleanup ─────────────────────────────────────────────────────────
apt-get clean
rm -rf /var/lib/apt/lists/*

log "Customization complete"
