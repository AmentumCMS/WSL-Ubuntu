# WSL-Ubuntu

Automated build pipeline for a hardened, STIG-compliant Ubuntu WSL2 image
customized for organizational use.

## What This Builds

| Artifact | Description |
|----------|-------------|
| `wsl-ubuntu-<ver>-<build>.tar.gz` | WSL2-importable Ubuntu rootfs |
| `SHA256SUMS` / `SHA512SUMS` | Integrity checksums |
| `scap-results/post-remediation-report.html` | OpenSCAP/STIG compliance report |
| `scan-results/clamav-results.txt` | ClamAV antivirus findings |
| `scan-results/trivy-results.txt` | Trivy CVE scan |
| `scan-results/grype-results.txt` | Grype CVE scan |
| `scan-results/*-sbom.spdx.json` | Software Bill of Materials (SPDX) |
| `scan-results/*-sbom.cyclonedx.json` | Software Bill of Materials (CycloneDX) |

All artifacts are attached to every [GitHub Release](../../releases) and also
available as [workflow run artifacts](../../actions).

The hardened Docker image is published to
[GitHub Container Registry (GHCR)](../../pkgs/container/wsl-ubuntu).

---

## Quick Start — Import the Image into WSL2

```powershell
# 1. Download the latest release tarball
$tag    = (Invoke-RestMethod https://api.github.com/repos/<owner>/WSL-Ubuntu/releases/latest).tag_name
$asset  = "wsl-ubuntu-22.04-${tag}.tar.gz"
Invoke-WebRequest "https://github.com/<owner>/WSL-Ubuntu/releases/download/${tag}/${asset}" -OutFile $asset

# 2. Verify the checksum (compare against SHA256SUMS from the same release)
Get-FileHash $asset -Algorithm SHA256

# 3. Import into WSL2
wsl --import Ubuntu-Hardened C:\WSL\Ubuntu-Hardened .\$asset --version 2

# 4. Launch
wsl -d Ubuntu-Hardened
```

### Or pull from GHCR and import

```bash
# Pull the container image
docker pull ghcr.io/<owner>/wsl-ubuntu:latest

# Export as a WSL tarball (on Windows with Docker Desktop)
docker export $(docker create ghcr.io/<owner>/wsl-ubuntu:latest) -o wsl-ubuntu.tar
# Then: wsl --import ...
```

---

## Repository Structure

```
.github/
└── workflows/
    └── build.yml          ← CI/CD pipeline (build · harden · scan · publish)

scripts/
├── build-wsl-image.sh     ← Orchestrates Docker-based rootfs build
├── harden.sh              ← OpenSCAP/STIG hardening (runs inside container)
└── apply-customizations.sh ← Applies org customizations (runs inside container)

customizations/             ← ✏️  EDIT THESE to customize your image
├── config.env             ← Organization variables (name, timezone, user, etc.)
├── packages.list          ← Extra apt packages to install
├── files/                 ← Drop-in files copied into the image filesystem
│   └── etc/
│       ├── motd
│       └── profile.d/99-org-env.sh
└── scripts/               ← Numbered hook scripts run in order
    ├── 00-configure-apt.sh
    └── 01-configure-users.sh
```

See [`customizations/README.md`](customizations/README.md) for the full
customization guide.

---

## Build Pipeline Overview

```
push / tag / schedule / manual dispatch
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  GitHub Actions — ubuntu-latest runner                              │
│                                                                     │
│  1. docker pull ubuntu:<version>                                    │
│  2. docker run  (ephemeral build container)                         │
│     ├── [optional] ubuntu pro attach                                │
│     ├── apply-customizations.sh  (packages · files · hooks)        │
│     └── harden.sh  (OpenSCAP pre-scan → remediate → post-scan)     │
│  3. docker export → rootfs.tar.gz  (WSL tarball)                   │
│  4. docker commit → wsl-ubuntu:local  (for GHCR push)              │
│  5. ClamAV scan  (rootfs directory)                                 │
│  6. Syft SBOM  (SPDX + CycloneDX)                                  │
│  7. Grype CVE scan  (from SBOM)                                     │
│  8. Trivy CVE scan  (rootfs)                                        │
│  9. sha256sum / sha512sum                                           │
│  10. docker push → ghcr.io/<owner>/wsl-ubuntu                      │
│  11. GitHub Release  (tarball + all scan artifacts)                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Triggers

| Trigger | Behavior |
|---------|----------|
| Push to `main` | Full build + publish as pre-release |
| Push a `v*` tag | Full build + publish as stable release |
| Pull request | Build + scan only (no publish) |
| Weekly schedule | Monday 02:00 UTC — full build + publish |
| Manual dispatch | Choose Ubuntu version, SCAP profile, Pro enablement |

---

## Secrets Configuration

Configure these in **Settings → Secrets and variables → Actions**:

| Secret | Required | Description |
|--------|----------|-------------|
| `GITHUB_TOKEN` | Auto | Provided by Actions — used for GHCR and releases |
| `UBUNTU_PRO_TOKEN` | Optional | Ubuntu Pro attach token for ESM / FIPS |

To obtain an Ubuntu Pro token: <https://ubuntu.com/pro/dashboard>

---

## Customizing the Image

See **[customizations/README.md](customizations/README.md)** for the full guide.

In summary:

1. **Add packages** — edit `customizations/packages.list`
2. **Drop in files** — add files under `customizations/files/` (mirrors `/`)
3. **Run scripts** — add numbered `NN-name.sh` scripts to `customizations/scripts/`
4. **Configure** — edit `customizations/config.env`

---

## STIG/SCAP Hardening

Hardening is applied via [OpenSCAP](https://www.open-scap.org/) using the
[SCAP Security Guide (SSG)](https://github.com/ComplianceAsCode/content).

The pipeline runs three passes:

1. **Pre-remediation scan** — baseline snapshot before any fixes
2. **Remediation** — `oscap xccdf eval --remediate` applies all automatable fixes
3. **Post-remediation scan** — compliance snapshot after fixes

The HTML compliance report (`post-remediation-report.html`) is attached to
every release.

### WSL-specific notes

WSL2 shares the Windows host kernel, so some STIG controls cannot be enforced
at image build time:

| Control category | Status in image |
|-----------------|----------------|
| File permissions, PAM, SSH config | ✅ Applied at build |
| auditd rules, sysctl defaults | ✅ Config written; applied at WSL boot |
| Kernel parameters | ⚠️ Applied at WSL instance boot via `/etc/sysctl.d/99-stig.conf` |
| Bootloader hardening | ➖ Not applicable (WSL2 uses Windows bootloader) |
| Active service checks | ⚠️ Services start at WSL instance launch |

Controls marked ⚠️ are documented in the SCAP report as `notchecked` or
`fail` with a clear explanation.

---

## Security Scan Results

After every build:

- **ClamAV** — antivirus scan of the extracted rootfs
- **Trivy** — CVE scan using the NVD + OS vendor databases
- **Grype** — CVE scan using the Anchore vulnerability database
- **SARIF** — Trivy and Grype results uploaded to **GitHub Security** tab
  (Settings → Security → Code scanning)

---

## External Steps / Prerequisites

The following cannot be handled automatically via GitHub Actions and require
manual one-time setup:

1. **Enable GitHub Packages** — GHCR is enabled by default for public repos;
   private repos may need it enabled in Settings → Packages.

2. **Enable GitHub Security / Code Scanning** — required to view SARIF results
   in the Security tab (free for public repos; requires Advanced Security license
   for private repos).

3. **Ubuntu Pro token** — obtain from <https://ubuntu.com/pro/dashboard> and
   add as the `UBUNTU_PRO_TOKEN` secret.

4. **MSIX/Store distribution** — distributing via the Microsoft Store requires
   a Windows code-signing certificate and submission to Microsoft's partner
   portal. This is out of scope for this pipeline but the rootfs tarball
   produced here can serve as the payload for an MSIX package built separately
   on a Windows runner.
