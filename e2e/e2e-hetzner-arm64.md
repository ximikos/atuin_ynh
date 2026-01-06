# ARM64 End-to-End Testing on Hetzner Cloud

This repository provides an **optional end-to-end (E2E) testing workflow**
for validating the Atuin YunoHost app on **ARM64 (aarch64)** hardware.

The workflow provisions a temporary ARM64 virtual machine on Hetzner Cloud,
installs YunoHost, deploys the Atuin app from this repository, runs CLI-based
synchronization tests, collects logs, and then destroys the server.

The workflow is designed for maintainers and contributors and is **not enabled
by default** for forks.

---

## Overview

The workflow performs the following steps:

1. Create a temporary ARM64 VM on Hetzner Cloud
2. Install YunoHost non-interactively
3. Install the Atuin YunoHost app from the current Git branch
4. Enable Atuin user registration
5. Run on-host Atuin CLI E2E tests:
   - register a user
   - import 5 test commands
   - synchronize history with the server
   - verify that the server accepted the sync
6. Collect logs and diagnostics
7. Destroy the VM

---

## Workflow location
`.github/workflows/e2e-hetzner-arm64.yml`


The workflow is triggered manually using **workflow_dispatch**.

---

## E2E test script

The actual test logic is implemented in:

`e2e/onhost-atuin-cli.sh`


This script runs **on the same machine as the Atuin server** and performs
a full client-side sync using the official Atuin CLI.

Key characteristics:
- works on amd64 and arm64
- does not require Incus or containers
- uses an isolated HOME directory
- connects directly to the local Atuin server over HTTP
- validates that the server accepted the sync via `atuin status`

---

## Requirements

To run this workflow, the following secrets must be configured in the repository:

| Secret name | Description |
|------------|-------------|
| `HCLOUD_TOKEN` | Hetzner Cloud API token |
| `RUNNER_TOKEN` | GitHub token used to register the ephemeral runner |
| `YUNOHOST_ADMIN_PASSWORD` | Admin password for YunoHost postinstall |
| `ATUIN_E2E_PASSWORD` | Password used for Atuin CLI test user |

The workflow uses the **CAX11** ARM64 server type by default.

---

## Cost considerations

Each run creates a temporary ARM64 VM on Hetzner Cloud.
The server is destroyed automatically at the end of the workflow.

Running the workflow repeatedly may incur small costs.

---

## When to use this workflow

This workflow is intended for:

- validating ARM64 support
- testing upstream Atuin releases on real hardware
- verifying YunoHost packaging changes
- debugging architecture-specific issues

For local `amd64` testing (!not arm), consider the Incus-based E2E tests in: `incus-atuin-e2e/`


---

## Notes

- The workflow intentionally avoids HTTPS/TLS to keep the test environment
  simple and deterministic.
- The Atuin CLI requires `ATUIN_SESSION` to be set in non-interactive shells;
  this is handled automatically by the test script.
- The workflow is not triggered automatically on pull requests.
