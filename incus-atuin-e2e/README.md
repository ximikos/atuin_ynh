# Atuin End-to-End Testing in Incus Containers

**Purpose**

These scripts automate setting up, running, and testing the Atuin server and clients inside Incus containers, enabling reproducible end-to-end testing in an isolated environment.

**Scripts**

- `atuin-incus-up.sh`  
  Creates and configures an Atuin server in an Incus container.

- `atuin-incus-test.sh`  
  Starts client containers and performs end-to-end tests (registration, sync, history replication).

- `atuin-incus-down.sh`  
  Removes all Incus containers created for the Atuin test setup.

- `vars.sh`  
  Shared configuration variables used by all scripts.

