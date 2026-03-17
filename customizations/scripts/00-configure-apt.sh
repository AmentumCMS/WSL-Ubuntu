#!/usr/bin/env bash
# =============================================================================
# customizations/scripts/00-configure-apt.sh
#
# Hook script #00: Configure APT settings for the WSL image.
# Runs inside the container before package installation.
#
# Numbering convention:
#   00-09  — System/APT configuration (runs before package install)
#   10-49  — Package-related setup
#   50-79  — User and identity configuration
#   80-99  — Final configuration and cleanup
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { echo "[00-configure-apt] $*"; }

# ── Disable apt-recommends to keep image lean (optional) ─────────────────────
# Uncomment to install only required dependencies, not recommended packages:
# cat > /etc/apt/apt.conf.d/01-no-recommends << 'APTEOF'
# APT::Install-Recommends "false";
# APT::Install-Suggests "false";
# APTEOF
# log "Disabled apt recommends"

# ── Configure HTTP proxy (if needed) ─────────────────────────────────────────
if [ -n "${APT_HTTP_PROXY:-}" ]; then
  log "Configuring APT proxy: ${APT_HTTP_PROXY}"
  cat > /etc/apt/apt.conf.d/02-proxy << APTPROXYEOF
Acquire::http::Proxy "${APT_HTTP_PROXY}";
Acquire::https::Proxy "${APT_HTTP_PROXY}";
APTPROXYEOF
fi

# ── Configure timezone ────────────────────────────────────────────────────────
TIMEZONE="${TIMEZONE:-UTC}"
log "Setting timezone to ${TIMEZONE}..."
apt-get install -y --no-install-recommends tzdata 2>/dev/null || true
ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" > /etc/timezone

# ── Configure locale ─────────────────────────────────────────────────────────
LOCALE="${LOCALE:-en_US.UTF-8}"
log "Setting locale to ${LOCALE}..."
apt-get install -y --no-install-recommends locales 2>/dev/null || true
locale-gen "${LOCALE}"
update-locale LANG="${LOCALE}" LC_ALL="${LOCALE}"

# ── Configure WSL ─────────────────────────────────────────────────────────────
log "Writing /etc/wsl.conf..."
cat > /etc/wsl.conf << WSLEOF
[automount]
enabled = ${WSL_AUTOMOUNT:-true}
root = ${WSL_AUTOMOUNT_ROOT:-/mnt}
options = "${WSL_AUTOMOUNT_OPTIONS:-metadata,umask=22,fmask=11}"
mountFsTab = true

[network]
generateHosts = ${WSL_NETWORK_GENERATE_HOSTS:-true}
generateResolvConf = ${WSL_NETWORK_GENERATE_RESOLV_CONF:-true}

[interop]
enabled = ${WSL_INTEROP_ENABLED:-true}
appendWindowsPath = ${WSL_INTEROP_APPENDWINDOWSPATH:-false}

[boot]
systemd = false
WSLEOF

log "APT and system configuration complete"
