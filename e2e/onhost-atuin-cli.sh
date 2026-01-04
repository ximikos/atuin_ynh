#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

require() { command -v "$1" >/dev/null 2>&1 || { err "Missing '$1'"; exit 1; }; }

# ---- Config (override via env) ----
VERSION="${VERSION:-18.10.0}"                            # Atuin upstream version for CLI download
DOMAIN="${DOMAIN:-atuin.ynh.test}"                        # if you want to test via nginx domain
SERVER_TOML="${SERVER_TOML:-/var/www/atuin/server.toml}"  # YunoHost app config path
PASSWORD="${PASSWORD:-paSSw000rd!}"
USERNAME="${USERNAME:-e2e_user}"
EMAIL="${EMAIL:-e2e_user@example.invalid}"

# If empty -> prefer localhost HTTP via parsed port from server.toml:
#   http://127.0.0.1:<port>
# If set -> use as-is (e.g. "https://atuin.ynh.test")
ATUIN_SYNC_ADDRESS_OVERRIDE="${ATUIN_SYNC_ADDRESS_OVERRIDE:-}"

# Isolated client home (empty -> mktemp)
E2E_HOME="${E2E_HOME:-}"

detect_arch_pkg() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  echo "atuin-x86_64-unknown-linux-gnu.tar.gz" ;;
    aarch64) echo "atuin-aarch64-unknown-linux-gnu.tar.gz" ;;
    *)
      err "Unsupported arch: $arch"
      exit 1
      ;;
  esac
}

install_atuin_cli() {
  require curl
  require tar
  require install

  local pkg url tmp dir
  pkg="$(detect_arch_pkg)"
  url="https://github.com/atuinsh/atuin/releases/download/v${VERSION}/${pkg}"
  tmp="$(mktemp -d)"

  log "Installing atuin CLI v${VERSION} from ${url}"
  curl -fsSL -o "${tmp}/atuin.tgz" "${url}"
  tar -xzf "${tmp}/atuin.tgz" -C "${tmp}"

  dir="$(find "${tmp}" -maxdepth 1 -type d -name 'atuin-*unknown-linux-*' | head -n1)"
  if [[ -z "${dir}" || ! -f "${dir}/atuin" ]]; then
    err "Could not find atuin binary in extracted archive"
    exit 1
  fi

  install -m 0755 "${dir}/atuin" /usr/local/bin/atuin
  rm -rf "${tmp}"

  log "Atuin CLI installed: $(atuin --version)"
}

read_server_port() {
  if [[ ! -f "${SERVER_TOML}" ]]; then
    err "Server TOML not found: ${SERVER_TOML}"
    exit 1
  fi
  local port
  port="$(grep -E '^\s*port\s*=\s*[0-9]+' "${SERVER_TOML}" | head -n1 | sed -E 's/.*=\s*([0-9]+).*/\1/')"
  if [[ -z "${port}" ]]; then
    err "Could not parse port from ${SERVER_TOML}"
    exit 1
  fi
  echo "${port}"
}

setup_isolated_home() {
  if [[ -n "${E2E_HOME}" ]]; then
    mkdir -p "${E2E_HOME}"
    export HOME="${E2E_HOME}"
  else
    export HOME
    HOME="$(mktemp -d)"
    export HOME
  fi

  export XDG_CONFIG_HOME="${HOME}/.config"
  export XDG_DATA_HOME="${HOME}/.local/share"
  mkdir -p "${XDG_CONFIG_HOME}/atuin"

  log "Using isolated HOME=${HOME}"
}

configure_sync_address() {
  local addr
  if [[ -n "${ATUIN_SYNC_ADDRESS_OVERRIDE}" ]]; then
    addr="${ATUIN_SYNC_ADDRESS_OVERRIDE}"
  else
    # safest for on-host e2e: direct to local server, avoids TLS/CA hassle
    local port
    port="$(read_server_port)"
    addr="http://127.0.0.1:${port}"
  fi

  cat > "${XDG_CONFIG_HOME}/atuin/config.toml" <<EOF
sync_address = "${addr}"
EOF

  export ATUIN_SYNC_ADDRESS="${addr}"
  log "ATUIN_SYNC_ADDRESS=${ATUIN_SYNC_ADDRESS}"
}

extract_last_sync_value() {
  # Prints the value after "Last sync:" (trimmed), or empty string if not found
  # We avoid depending on exact spacing/case too much.
  local status_file="$1"
  awk '
    BEGIN{IGNORECASE=1}
    $0 ~ /^last[[:space:]]+sync[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "", $0);
      gsub(/[[:space:]]+$/, "", $0);
      print $0;
      exit 0
    }
  ' "$status_file" || true
}

assert_server_accepted_sync() {
  local status_file="$1"
  local last_sync
  last_sync="$(extract_last_sync_value "$status_file")"

  if [[ -z "${last_sync}" ]]; then
    err "Could not find 'Last sync:' in atuin status output"
    err "atuin status output:"
    sed -n '1,200p' "$status_file" >&2 || true
    exit 1
  fi

  # Common values when nothing synced: "Never" (exact casing can vary)
  if [[ "${last_sync,,}" == "never" ]]; then
    err "Server sync not confirmed: Last sync is 'Never'"
    err "atuin status output:"
    sed -n '1,200p' "$status_file" >&2 || true
    exit 1
  fi

  log "[OK] Server accepted sync (Last sync: ${last_sync})"
}

run_e2e() {
  require atuin

  local RUN_ID HISTFILE got status_file

  log "[TEST] register"
  atuin register -u "${USERNAME}" -e "${EMAIL}" -p "${PASSWORD}"

  log "[TEST] run 5 harmless commands + record them into bash history"
  RUN_ID="$(date +%s%N)"
  echo "${RUN_ID}" > "${HOME}/run_id"

  HISTFILE="${HOME}/.bash_history"
  export HISTFILE
  set -o history
  history -c

  for i in 1 2 3 4 5; do
    cmd="echo ATUIN_TEST_${RUN_ID}_${i}"
    eval "${cmd}" >/dev/null
    history -s "${cmd}"
  done
  history -a

  log "[TEST] atuin import bash"
  atuin import bash

  log "[TEST] atuin sync"
  atuin sync

  # Capture status for parsing + debugging
  status_file="${HOME}/atuin_status.txt"
  atuin status > "${status_file}" 2>&1 || {
    err "atuin status failed"
    sed -n '1,200p' "${status_file}" >&2 || true
    exit 1
  }

  # Hard assertion: last sync must not be "Never"
  assert_server_accepted_sync "${status_file}"

  # Optional sanity: confirm we see our 5 commands locally
  got="$(atuin history list --cmd-only | grep -F "ATUIN_TEST_${RUN_ID}_" | sort -u | wc -l | tr -d ' ')"
  if [[ "${got}" -ne 5 ]]; then
    err "Expected 5 imported commands locally, got ${got}"
    atuin history list --cmd-only | grep -F "ATUIN_TEST_${RUN_ID}_" | tail -n 50 >&2 || true
    exit 1
  fi

  log "[OK] Imported + synced 5 commands (RUN_ID=${RUN_ID})"
}

main() {
  require bash

  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update
  apt-get -qq install -y ca-certificates curl tar >/dev/null

  install_atuin_cli
  setup_isolated_home
  configure_sync_address
  run_e2e

  log "[OK] On-host E2E finished"
  log "Useful logs if needed:"
  log "  yunohost service log atuin"
  log "  journalctl -u atuin --no-pager -n 200 -l"
}

main "$@"
