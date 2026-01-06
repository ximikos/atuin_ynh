#!/usr/bin/env bash
set -euo pipefail

# ---- Common ----
PORT="8888"
VERSION="18.10.0"

SERVER_NAME="atuin-server"
CLIENT1_NAME="atuin-client1"
CLIENT2_NAME="atuin-client2"

SERVER_IMAGE="images:debian/12"
CLIENT1_IMAGE="images:ubuntu/22.04"
CLIENT2_IMAGE="images:ubuntu/24.04"

# Persisted data on host
BASE_DIR="${HOME}/incus-atuin/server"

# Test account (used by test script)
USERNAME="testuser2"
EMAIL="testuser2@example.com"
PASSWORD="test-pass-123"

