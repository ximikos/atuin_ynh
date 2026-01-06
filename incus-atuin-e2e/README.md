# Atuin End-to-End Testing in Incus Containers

## Purpose

These scripts automate setting up, running, and testing the Atuin server and clients inside Incus containers, enabling reproducible end-to-end testing in an isolated environment.

## Scripts

- `atuin-incus-up.sh`
  Creates and configures an Atuin server in an Incus container.

- `atuin-incus-test.sh`
  Starts client containers and performs end-to-end tests (user registration, sync, and history replication).

- `atuin-incus-down.sh`
  Removes all Incus containers created for the Atuin test setup.

- `vars.sh`
  Shared configuration variables used by the Incus-based Atuin server and client test scripts.

- `ynh-dev-atuin-test.sh`
  Runs an end-to-end test against an Atuin server installed in YunoHost inside an Incus container.
  It provisions two client containers, installs the Atuin CLI, trusts the YunoHost TLS certificate, registers a user, synchronizes shell history, and verifies that the history is correctly synced between clients.

  The YunoHost target container can be selected explicitly:
  - via the first positional argument: `./ynh-dev-atuin-test.sh <YNH_CONTAINER> [DOMAIN]`
  - or via environment variable `YNH_CONTAINER`

  The test domain can be selected:
  - via the second positional argument: `./ynh-dev-atuin-test.sh <YNH_CONTAINER> <DOMAIN>`
  - or via environment variable `DOMAIN`

  If `YNH_CONTAINER` is not provided, the script auto-selects the target container:
  1) `ynh-dev-trixie-unstable` (if present)
  2) `ynh-dev-bookworm-unstable` (if present)

  Default domain is `atuin.yolo.test`.

## Examples

Run against the trixie (YunoHost 13) container:
  ./ynh-dev-atuin-test.sh ynh-dev-trixie-unstable atuin.yolo.test

Run against the bookworm container:
  ./ynh-dev-atuin-test.sh ynh-dev-bookworm-unstable atuin.yolo.test

Equivalent usage with environment variables:
  YNH_CONTAINER=ynh-dev-trixie-unstable DOMAIN=atuin.yolo.test ./ynh-dev-atuin-test.sh

