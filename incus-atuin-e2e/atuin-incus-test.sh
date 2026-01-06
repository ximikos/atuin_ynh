#!/usr/bin/env bash
set -euo pipefail

# Load shared variables (PORT, VERSION, SERVER_NAME, CLIENT1_NAME, CLIENT2_NAME, CLIENT*_IMAGE, USERNAME/EMAIL/PASSWORD, ...)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vars.sh
if [[ ! -f "${SCRIPT_DIR}/vars.sh" ]]; then
  echo "[ERROR] Missing ${SCRIPT_DIR}/vars.sh"
  exit 1
fi
source "${SCRIPT_DIR}/vars.sh"

: "${SERVER_NAME:?Missing SERVER_NAME in vars.sh}"
: "${CLIENT1_NAME:?Missing CLIENT1_NAME in vars.sh}"
: "${CLIENT2_NAME:?Missing CLIENT2_NAME in vars.sh}"
: "${CLIENT1_IMAGE:?Missing CLIENT1_IMAGE in vars.sh}"
: "${CLIENT2_IMAGE:?Missing CLIENT2_IMAGE in vars.sh}"
: "${PORT:?Missing PORT in vars.sh}"
: "${VERSION:?Missing VERSION in vars.sh}"
: "${USERNAME:?Missing USERNAME in vars.sh}"
: "${EMAIL:?Missing EMAIL in vars.sh}"
: "${PASSWORD:?Missing PASSWORD in vars.sh}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing '$1'"; exit 1; }; }
require incus

# --- show version early (requested) ---
echo "[INFO] Atuin version: ${VERSION}"

if ! incus info "${SERVER_NAME}" >/dev/null 2>&1; then
  echo "[ERROR] Server '${SERVER_NAME}' not found. Run ./atuin-incus-up.sh first."
  exit 1
fi

echo "[INFO] Ensuring server service is active..."
if ! incus exec "${SERVER_NAME}" -- bash -lc "systemctl is-active --quiet atuin-server"; then
  echo "[ERROR] atuin-server service is not active"
  incus exec "${SERVER_NAME}" -- bash -lc "systemctl status atuin-server --no-pager -l || true"
  incus exec "${SERVER_NAME}" -- bash -lc "journalctl -u atuin-server --no-pager -n 200 -l || true"
  exit 1
fi

echo "[INFO] Getting server IPv4..."
SERVER_IP="$(incus list "${SERVER_NAME}" -c 4 --format csv | head -n1 | cut -d' ' -f1 | cut -d, -f1)"
if [[ -z "${SERVER_IP}" ]]; then
  echo "[ERROR] Could not detect server IP."
  exit 1
fi
SYNC_ADDR="http://${SERVER_IP}:${PORT}"
echo "[INFO] Using ATUIN_SYNC_ADDRESS=${SYNC_ADDR}"

cleanup_instance() {
  local n="$1"
  if incus info "$n" >/dev/null 2>&1; then
    echo "[INFO] Deleting ${n}"
    incus delete -f "$n" >/dev/null
  fi
}

install_atuin_quiet() {
  local n="$1"
  echo "[INFO] ${n}: Installing atuin ${VERSION} (quiet apt)..."
  incus exec "$n" -- bash -lc "
    set -euo pipefail

    log=/tmp/apt-install.log
    rm -f \"\$log\"

    echo '[INFO] Installing required apt packages (quiet)...'
    export DEBIAN_FRONTEND=noninteractive
    {
      apt-get -qq update
      apt-get -qq install -y ca-certificates curl tar
    } >>\"\$log\" 2>&1 || {
      echo '[ERROR] apt install failed. Last 120 log lines:'
      tail -n 120 \"\$log\" || true
      exit 1
    }

    arch=\$(uname -m)
    case \"\$arch\" in
      x86_64)  pkg='atuin-x86_64-unknown-linux-gnu.tar.gz' ;;
      aarch64) pkg='atuin-aarch64-unknown-linux-gnu.tar.gz' ;;
      *) echo \"[ERROR] Unsupported arch: \$arch\"; exit 1 ;;
    esac

    cd /tmp
    curl -fsSL -o atuin.tgz \"https://github.com/atuinsh/atuin/releases/download/v${VERSION}/\${pkg}\"
    tar -xzf atuin.tgz
    dir=\$(find . -maxdepth 1 -type d -name 'atuin-*unknown-linux-*' | head -n1)
    install -m 0755 \"\${dir}/atuin\" /usr/local/bin/atuin

    /usr/local/bin/atuin --version
  "
}

echo "[INFO] Recreating clients..."
cleanup_instance "${CLIENT1_NAME}"
cleanup_instance "${CLIENT2_NAME}"

echo "[INFO] Launching ${CLIENT1_NAME}: ${CLIENT1_IMAGE}"
incus launch "${CLIENT1_IMAGE}" "${CLIENT1_NAME}"

echo "[INFO] Launching ${CLIENT2_NAME}: ${CLIENT2_IMAGE}"
incus launch "${CLIENT2_IMAGE}" "${CLIENT2_NAME}"

echo "[INFO] Installing atuin in clients..."
install_atuin_quiet "${CLIENT1_NAME}"
install_atuin_quiet "${CLIENT2_NAME}"

echo "[TEST] ${CLIENT1_NAME}: register + execute 5 harmless cmds + import + sync"
incus exec "${CLIENT1_NAME}" -- bash -lc "
  set -euo pipefail
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"incus-test-client1-\$(date +%s%N)\"

  atuin register -u '${USERNAME}' -e '${EMAIL}' -p '${PASSWORD}'

  RUN_ID=\$(date +%s%N)
  echo \"\$RUN_ID\" > /tmp/atuin_run_id

  HISTFILE=/tmp/atuin_bash_history
  export HISTFILE
  set -o history
  history -c

  for i in 1 2 3 4 5; do
    cmd=\"echo ATUIN_TEST_\${RUN_ID}_\${i}\"
    eval \"\$cmd\"
    history -s \"\$cmd\"
  done
  history -a

  atuin import bash
  atuin sync
  atuin status | sed -n '1,120p'
"

RUN_ID="$(incus exec "${CLIENT1_NAME}" -- bash -lc "cat /tmp/atuin_run_id" | tr -d '\r\n')"
if [[ -z "${RUN_ID}" ]]; then
  echo "[ERROR] Failed to read RUN_ID from ${CLIENT1_NAME}"
  exit 1
fi
echo "[INFO] RUN_ID=${RUN_ID}"

echo "[INFO] ${CLIENT1_NAME}: extracting key"
KEY="$(incus exec "${CLIENT1_NAME}" -- bash -lc "export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'; atuin key" | tr -d '\r' | sed -n '1p')"
if [[ -z "${KEY}" ]]; then
  echo "[ERROR] Failed to read atuin key from ${CLIENT1_NAME}"
  exit 1
fi

echo "[TEST] ${CLIENT1_NAME}: logout"
incus exec "${CLIENT1_NAME}" -- bash -lc "
  set -euo pipefail
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"incus-test-client1-logout-\$(date +%s%N)\"
  atuin logout
"

echo "[TEST] ${CLIENT2_NAME}: login + sync + verify 5 cmds were synced"
incus exec "${CLIENT2_NAME}" -- bash -lc "
  set -euo pipefail
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"incus-test-client2-\$(date +%s%N)\"

  atuin login -u '${USERNAME}' -p '${PASSWORD}' -k '${KEY}'
  atuin sync

  got=\$(atuin history list --cmd-only | grep -F \"ATUIN_TEST_${RUN_ID}_\" | sort -u | wc -l)
  if [ \"\$got\" -ne 5 ]; then
    echo \"[ERROR] Expected 5 synced commands for RUN_ID=${RUN_ID}, got \$got\"
    echo \"[DEBUG] Matching lines:\"
    atuin history list --cmd-only | grep -F \"ATUIN_TEST_${RUN_ID}_\" | tail -n 100 || true
    exit 1
  fi

  echo \"[OK] Synced 5 test commands (RUN_ID=${RUN_ID})\"
  atuin status | sed -n '1,120p'
"

echo "[OK] Tests passed: register, execute+record 5 cmds, import, sync, login, verify sync."
echo "[INFO] Leaving clients running for inspection:"
echo "       incus exec ${CLIENT1_NAME} -- bash"
echo "       incus exec ${CLIENT2_NAME} -- bash"

