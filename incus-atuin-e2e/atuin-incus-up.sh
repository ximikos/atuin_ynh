#!/usr/bin/env bash
set -euo pipefail

# Load shared variables (PORT, VERSION, SERVER_NAME, SERVER_IMAGE, BASE_DIR, ...)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vars.sh
if [[ ! -f "${SCRIPT_DIR}/vars.sh" ]]; then
  echo "[ERROR] Missing ${SCRIPT_DIR}/vars.sh"
  exit 1
fi
source "${SCRIPT_DIR}/vars.sh"

# ---- sanity defaults (in case vars.sh is missing something) ----
: "${SERVER_NAME:?Missing SERVER_NAME in vars.sh}"
: "${SERVER_IMAGE:?Missing SERVER_IMAGE in vars.sh}"
: "${PORT:?Missing PORT in vars.sh}"
: "${VERSION:?Missing VERSION in vars.sh}"
: "${BASE_DIR:?Missing BASE_DIR in vars.sh}"

mkdir -p "${BASE_DIR}"
chmod 0775 "${BASE_DIR}"

echo "[INFO] Recreating server: ${SERVER_NAME}"
if incus info "${SERVER_NAME}" >/dev/null 2>&1; then
  incus delete -f "${SERVER_NAME}"
fi

echo "[INFO] Launching container: ${SERVER_IMAGE}"
echo "[INFO] Atuin version: ${VERSION}"   # <-- tady je ta verze přesně mezi INFO a 'Launching ...'
incus launch "${SERVER_IMAGE}" "${SERVER_NAME}"

echo "[INFO] Setting privileged mode"
incus config set "${SERVER_NAME}" security.privileged true

echo "[INFO] Mounting persistent server dir -> /config"
incus config device remove "${SERVER_NAME}" config >/dev/null 2>&1 || true
incus config device add "${SERVER_NAME}" config disk source="${BASE_DIR}" path=/config

echo "[INFO] Publishing TCP ${PORT} on host -> container ${PORT}"
incus config device remove "${SERVER_NAME}" http >/dev/null 2>&1 || true
incus config device add "${SERVER_NAME}" http proxy \
  listen="tcp:0.0.0.0:${PORT}" \
  connect="tcp:127.0.0.1:${PORT}"

echo "[INFO] Restarting container to apply config"
incus restart "${SERVER_NAME}"

echo "[INFO] Installing atuin ${VERSION}..."
incus exec "${SERVER_NAME}" -- bash -lc "
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

echo "[INFO] Ensuring /config is writable (fix ownership + perms, then write-test)"
incus exec "${SERVER_NAME}" -- bash -lc "
  set -euo pipefail
  mkdir -p /config
  chown root:root /config
  chmod 0775 /config
  touch /config/.write_test
  rm -f /config/.write_test
"

echo "[INFO] Creating systemd service..."
incus exec "${SERVER_NAME}" -- bash -lc "cat >/etc/systemd/system/atuin-server.service <<EOF
[Unit]
Description=Atuin Sync Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
Environment=ATUIN_HOST=0.0.0.0
Environment=ATUIN_PORT=${PORT}
Environment=ATUIN_OPEN_REGISTRATION=true
Environment=ATUIN_DB_URI=sqlite:///config/atuin.db
Environment=RUST_LOG=info,atuin=debug,atuin_server=debug,tower_http=info
Environment=RUST_BACKTRACE=1
WorkingDirectory=/config
ExecStartPre=/usr/bin/test -w /config
ExecStart=/usr/local/bin/atuin server start
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now atuin-server
"

echo "[INFO] Final status"
incus exec "${SERVER_NAME}" -- bash -lc "systemctl status atuin-server --no-pager -l || true"
incus exec "${SERVER_NAME}" -- bash -lc "journalctl -u atuin-server --no-pager -n 80 -l || true"
incus exec "${SERVER_NAME}" -- bash -lc "ss -lptn | grep ':${PORT} ' || true"

if ! incus exec "${SERVER_NAME}" -- bash -lc "systemctl is-active --quiet atuin-server"; then
  echo "[ERROR] atuin-server is not active. Diagnostics:"
  incus exec "${SERVER_NAME}" -- bash -lc "ls -ld /config; stat -c '%U:%G %a %n' /config || true; mount | grep ' /config ' || true"
  exit 1
fi

echo "[OK] Server running at http://127.0.0.1:${PORT}"
echo "[OK] Persistent data dir: ${BASE_DIR}"

