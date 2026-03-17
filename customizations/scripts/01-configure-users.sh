#!/usr/bin/env bash
# =============================================================================
# customizations/scripts/01-configure-users.sh
#
# Hook script #01: Configure default user and sudo access.
# Runs inside the container after package installation.
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { echo "[01-configure-users] $*"; }

# ── Create default non-root user (optional) ───────────────────────────────────
CREATE_DEFAULT_USER="${CREATE_DEFAULT_USER:-false}"
DEFAULT_USERNAME="${DEFAULT_USERNAME:-wsluser}"
DEFAULT_SHELL="${DEFAULT_SHELL:-/bin/bash}"

if [ "${CREATE_DEFAULT_USER}" = "true" ]; then
  if id "${DEFAULT_USERNAME}" &>/dev/null; then
    log "User '${DEFAULT_USERNAME}' already exists; skipping creation"
  else
    log "Creating default user: ${DEFAULT_USERNAME}"
    useradd \
      --create-home \
      --shell  "${DEFAULT_SHELL}" \
      --groups sudo \
      "${DEFAULT_USERNAME}"
    # Lock password — user will authenticate via Windows credential
    passwd -l "${DEFAULT_USERNAME}"
    log "User '${DEFAULT_USERNAME}' created (password locked; use sudo or Windows credentials)"
  fi

  # Set as default WSL user
  if grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
    sed -i "s/^default = .*/default = ${DEFAULT_USERNAME}/" /etc/wsl.conf
  else
    printf '\n[user]\ndefault = %s\n' "${DEFAULT_USERNAME}" >> /etc/wsl.conf
  fi
  log "Default WSL user set to '${DEFAULT_USERNAME}'"
fi

# ── Harden sudo configuration ─────────────────────────────────────────────────
log "Hardening sudo configuration..."
cat > /etc/sudoers.d/99-wsl-hardening << 'SUDOEOF'
# Require password for sudo (STIG requirement)
Defaults authenticate
Defaults !visiblepw
Defaults log_output
Defaults logfile="/var/log/sudo.log"
Defaults !pwfeedback
# Tighten PATH for sudo sessions
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SUDOEOF
chmod 440 /etc/sudoers.d/99-wsl-hardening

# ── MOTD configuration ────────────────────────────────────────────────────────
ORG_NAME="${ORG_NAME:-My Organization}"
ORG_CONTACT="${ORG_CONTACT:-it-support@example.com}"
UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"

log "Configuring MOTD..."
# Disable dynamic MOTD scripts that reveal system info
if [ -d /etc/update-motd.d ]; then
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
fi

# Truncate organization name to fit in the banner (max 47 chars)
ORG_NAME_TRUNCATED="${ORG_NAME:0:47}"

cat > /etc/motd << MOTDEOF

  ┌─────────────────────────────────────────────────────────────────┐
  │  $(printf '%-63s' "${ORG_NAME_TRUNCATED}")│
  │  $(printf '%-63s' "Ubuntu ${UBUNTU_VERSION} WSL2 — Hardened Image")│
  └─────────────────────────────────────────────────────────────────┘

  This system is for authorized use only.
  All activity may be monitored and recorded.

  Support: ${ORG_CONTACT}

MOTDEOF

log "User and sudo configuration complete"
