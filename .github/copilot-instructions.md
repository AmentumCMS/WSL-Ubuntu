# Copilot Instructions

## Repository Overview

This repository builds a **corporate-approvable, hardened Ubuntu image for WSL (Windows Subsystem for Linux)**. The goal is to produce a secure, compliant WSL distribution suitable for enterprise environments.

## Project Purpose

- Build a hardened Ubuntu base image for WSL
- Ensure corporate security and compliance requirements are met
- Provide a reproducible, automated image build process

## Repository Structure

- `README.md` — Project overview and documentation
- `.github/` — GitHub configuration, workflows, and Copilot instructions

## Coding & Contribution Guidelines

- Keep all scripts POSIX-compatible or clearly target `bash` where shell-specific features are needed
- Prefer minimal, auditable changes — this is a security-sensitive project
- Document any hardening steps with comments explaining *why* each configuration is applied
- Follow the principle of least privilege in all configurations

## Building & Testing

- Image builds should be reproducible and scripted (no manual steps)
- Test that the resulting WSL image launches correctly and passes baseline security checks
- Validate any changes against corporate compliance requirements before merging

## Security Considerations

- Do not introduce packages or configurations that weaken the security posture
- Prefer well-maintained, widely-used packages from official Ubuntu repositories
- Any added tooling should be justified and documented
