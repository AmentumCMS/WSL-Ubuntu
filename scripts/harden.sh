#!/usr/bin/env bash
# =============================================================================
# harden.sh  —  runs INSIDE the build container as root
#
# Applies STIG/SCAP hardening using OpenSCAP and the SCAP Security Guide (SSG).
# Steps:
#   1. Installs OpenSCAP scanner + SCAP Security Guide content
#   2. Runs a pre-remediation compliance evaluation (baseline snapshot)
#   3. Applies STIG remediations via oscap --remediate
#   4. Runs a post-remediation compliance evaluation (shows what improved)
#   5. Applies additional manual hardening for controls that oscap cannot fix
#      inside a container (SSH, PAM, auditd, sysctl defaults, etc.)
#
# Environment variables:
#   UBUNTU_VERSION  — e.g. "22.04" (default: 22.04)
#   STIG_PROFILE    — SCAP profile ID (default: stig profile)
#
# NOTE: Some STIG controls are not remediable inside a container at build time:
#   - Kernel parameters (sysctl) — enforced at WSL instance launch
#   - Bootloader hardening       — not applicable to WSL2
#   - Active systemd services    — services start at WSL instance boot
# These controls are documented in the SCAP report as "notchecked" or "fail"
# and should be addressed via Windows/WSL configuration policy where applicable.
# =============================================================================
set -uo pipefail  # Note: -e intentionally omitted; oscap returns non-zero for findings

export DEBIAN_FRONTEND=noninteractive

UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"
STIG_PROFILE="${STIG_PROFILE:-xccdf_org.ssgproject.content_profile_stig}"
SCAP_RESULTS_DIR="/opt/scap-results"

mkdir -p "${SCAP_RESULTS_DIR}"

log()  { echo "[harden] $*"; }
warn() { echo "[harden] WARNING: $*" >&2; }

# ─── 1. Install OpenSCAP and SCAP Security Guide ──────────────────────────────
log "Installing OpenSCAP and SCAP Security Guide..."
apt-get update -q
apt-get install -y --no-install-recommends \
  openscap-scanner \
  ssg-debianoids \
  python3-libopenscap8 \
  bzip2 \
  unzip

# ─── 2. Locate the correct SSG benchmark file ─────────────────────────────────
# Try the packaged content first; fall back to downloading from upstream.
SSG_CONTENT=""

case "${UBUNTU_VERSION}" in
  22.04)
    PACKAGED_CONTENT="/usr/share/xml/scap/ssg/content/ssg-ubuntu2204-ds.xml"
    SSG_FILE_PATTERN="ssg-ubuntu2204-ds*.xml"
    UPSTREAM_FILENAME="ssg-ubuntu2204-ds.xml"
    ;;
  24.04)
    PACKAGED_CONTENT="/usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml"
    SSG_FILE_PATTERN="ssg-ubuntu2404-ds*.xml"
    UPSTREAM_FILENAME="ssg-ubuntu2404-ds.xml"
    ;;
  *)
    warn "No SSG content mapping for Ubuntu ${UBUNTU_VERSION}; attempting generic search"
    PACKAGED_CONTENT="/dev/null"
    SSG_FILE_PATTERN="ssg-ubuntu*.xml"
    UPSTREAM_FILENAME=""
    ;;
esac

if [ -f "${PACKAGED_CONTENT}" ]; then
  SSG_CONTENT="${PACKAGED_CONTENT}"
  log "Using packaged SSG content: ${SSG_CONTENT}"
else
  log "Packaged SSG content not found; searching installed files..."
  SSG_CONTENT=$(find /usr/share/xml/scap/ssg/content/ -name "${SSG_FILE_PATTERN}" \
    2>/dev/null | sort -V | tail -1 || true)
fi

# If still not found, download the latest SSG release from upstream
if [ -z "${SSG_CONTENT}" ] && [ -n "${UPSTREAM_FILENAME}" ]; then
  log "Downloading latest SSG content from ComplianceAsCode upstream..."
  SSG_URL="https://github.com/ComplianceAsCode/content/releases/latest/download"
  mkdir -p /usr/share/xml/scap/ssg/content
  wget -q "${SSG_URL}/${UPSTREAM_FILENAME}" \
    -O "/usr/share/xml/scap/ssg/content/${UPSTREAM_FILENAME}" \
    || warn "Download failed; SCAP hardening may be incomplete"
  SSG_CONTENT="/usr/share/xml/scap/ssg/content/${UPSTREAM_FILENAME}"
fi

if [ -z "${SSG_CONTENT}" ] || [ ! -f "${SSG_CONTENT}" ]; then
  warn "No SSG content available. Skipping OpenSCAP hardening."
  exit 0
fi

log "SSG content: ${SSG_CONTENT}"

# ─── 3. List available profiles (informational) ───────────────────────────────
log "Available profiles in SSG content:"
oscap info "${SSG_CONTENT}" 2>&1 | grep -E "^\s+Profile:" || true

# Verify the requested profile exists; fall back to CIS Level 2 if STIG not available
if ! oscap info "${SSG_CONTENT}" 2>&1 | grep -q "${STIG_PROFILE}"; then
  warn "Profile '${STIG_PROFILE}' not found in SSG content."
  FALLBACK="xccdf_org.ssgproject.content_profile_cis_level2_server"
  if oscap info "${SSG_CONTENT}" 2>&1 | grep -q "${FALLBACK}"; then
    warn "Falling back to CIS Level 2 Server profile: ${FALLBACK}"
    STIG_PROFILE="${FALLBACK}"
  else
    warn "No suitable profile found. Skipping OpenSCAP hardening."
    exit 0
  fi
fi

log "Using SCAP profile: ${STIG_PROFILE}"

# ─── 4. Pre-remediation baseline scan ─────────────────────────────────────────
log "Running pre-remediation SCAP evaluation..."
oscap xccdf eval \
  --profile "${STIG_PROFILE}" \
  --results  "${SCAP_RESULTS_DIR}/pre-remediation-results.xml" \
  --report   "${SCAP_RESULTS_DIR}/pre-remediation-report.html" \
  "${SSG_CONTENT}" 2>&1 \
  | tee "${SCAP_RESULTS_DIR}/pre-remediation.log" \
  || true
log "Pre-remediation scan complete"

# ─── 5. Apply SCAP/STIG remediations ──────────────────────────────────────────
log "Applying SCAP/STIG remediations (this may take several minutes)..."
oscap xccdf eval \
  --profile  "${STIG_PROFILE}" \
  --remediate \
  --results  "${SCAP_RESULTS_DIR}/remediation-results.xml" \
  --report   "${SCAP_RESULTS_DIR}/remediation-report.html" \
  "${SSG_CONTENT}" 2>&1 \
  | tee "${SCAP_RESULTS_DIR}/remediation.log" \
  || true
log "SCAP remediation pass complete"

# ─── 6. Post-remediation scan (final compliance snapshot) ─────────────────────
log "Running post-remediation SCAP evaluation..."
oscap xccdf eval \
  --profile "${STIG_PROFILE}" \
  --results  "${SCAP_RESULTS_DIR}/post-remediation-results.xml" \
  --report   "${SCAP_RESULTS_DIR}/post-remediation-report.html" \
  "${SSG_CONTENT}" 2>&1 \
  | tee "${SCAP_RESULTS_DIR}/post-remediation.log" \
  || true
log "Post-remediation scan complete"

# ─── 7. Supplemental manual hardening ─────────────────────────────────────────
# These controls cannot be remediated by oscap inside a container but are
# important for a hardened WSL image.
log "Applying supplemental manual hardening..."

# --- SSH hardening ---
if [ -d /etc/ssh ]; then
  SSHD_CONFIG="/etc/ssh/sshd_config"
  cat >> "${SSHD_CONFIG}" << 'SSHEOF'

# === STIG supplemental hardening ===
Protocol 2
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 1
LoginGraceTime 60
Banner /etc/issue.net
PrintLastLog yes
IgnoreRhosts yes
HostbasedAuthentication no
PermitUserEnvironment no
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256
SSHEOF
  log "SSH configuration hardened"
fi

# --- PAM password policy ---
if [ -f /etc/pam.d/common-password ]; then
  # Install password quality library if not present
  apt-get install -y --no-install-recommends libpam-pwquality 2>/dev/null || true

  # Set strong password requirements
  cat > /etc/security/pwquality.conf << 'PWEOF'
# STIG password quality requirements
minlen = 15
minclass = 4
maxrepeat = 3
maxclassrepeat = 4
lcredit = -1
ucredit = -1
dcredit = -1
ocredit = -1
difok = 8
gecoscheck = 1
PWEOF
  log "PAM password policy hardened"
fi

# --- Account lockout policy ---
if [ -f /etc/pam.d/common-auth ]; then
  apt-get install -y --no-install-recommends libpam-faillock 2>/dev/null || true
  # Configure faillock
  cat > /etc/security/faillock.conf << 'FLEOF'
# STIG account lockout policy
deny = 3
fail_interval = 900
unlock_time = 900
silent
audit
FLEOF
  log "Account lockout policy configured"
fi

# --- auditd rules ---
if apt-get install -y --no-install-recommends auditd audispd-plugins 2>/dev/null; then
  mkdir -p /etc/audit/rules.d
  cat > /etc/audit/rules.d/99-stig.rules << 'AUDITEOF'
## STIG Audit Rules
# Delete all existing rules
-D

# Buffer size
-b 8192

# Failure mode: 1=printk, 2=panic
-f 1

# Monitor authentication events
-w /etc/passwd -p wa -k identity
-w /etc/group  -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# Monitor sudo usage
-w /etc/sudoers -p wa -k privilege_escalation
-w /etc/sudoers.d/ -p wa -k privilege_escalation

# Monitor privileged command execution
-a always,exit -F arch=b64 -S execve -F euid=0 -k privileged

# Monitor file deletion
-a always,exit -F arch=b64 -S unlink  -F auid>=1000 -F auid!=unset -k delete
-a always,exit -F arch=b64 -S unlinkat -F auid>=1000 -F auid!=unset -k delete
-a always,exit -F arch=b64 -S rename  -F auid>=1000 -F auid!=unset -k delete

# Monitor kernel module loading
-w /sbin/insmod  -p x -k modules
-w /sbin/rmmod   -p x -k modules
-w /sbin/modprobe -p x -k modules

# Make rules immutable (uncomment to prevent runtime changes)
# -e 2
AUDITEOF
  log "auditd rules installed"
fi

# --- Sysctl defaults (WSL-compatible; kernel params take effect at WSL boot) ---
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-stig.conf << 'SYSCTLEOF'
# STIG sysctl hardening — applied at WSL instance boot
# Network hardening
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0

# Kernel hardening
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
SYSCTLEOF
log "sysctl defaults written to /etc/sysctl.d/99-stig.conf"

# --- MOTD / Login banner ---
cat > /etc/issue.net << 'BANNEREOF'
******************************************************************************
            AUTHORIZED USE ONLY — THIS SYSTEM IS MONITORED
******************************************************************************
This system is for authorized users only. Individuals using this system
without authority, or in excess of their authority, are subject to having
all of their activities monitored and recorded. Anyone using this system
expressly consents to such monitoring and is advised that if such monitoring
reveals possible evidence of criminal activity, evidence may be provided to
law enforcement officials.
******************************************************************************
BANNEREOF
cp /etc/issue.net /etc/issue
log "Login banners set"

# --- Disable unused filesystems ---
cat > /etc/modprobe.d/stig-blacklist.conf << 'MODEOF'
# STIG: Disable unused/insecure filesystem modules
install cramfs  /bin/true
install freevxfs /bin/true
install jffs2   /bin/true
install hfs     /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf     /bin/true
install usb-storage /bin/true
MODEOF
log "Unused filesystem modules disabled"

# ─── 8. Log summary ──────────────────────────────────────────────────────────
log "STIG/SCAP hardening complete."
log "SCAP results written to: ${SCAP_RESULTS_DIR}/"
ls -lh "${SCAP_RESULTS_DIR}/" 2>/dev/null || true
