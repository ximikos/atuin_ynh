#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

require() { command -v "$1" >/dev/null 2>&1 || { err "Missing '$1'"; exit 1; }; }

# ---- Config (override via env) ----
VERSION="${VERSION:-18.10.0}"                            # Atuin upstream version for CLI download
DOMAIN="${DOMAIN:-atuin.ynh.test}"
SERVER_TOML="${SERVER_TOML:-/var/www/atuin/server.toml}"

# Credentials: if USERNAME/EMAIL not provided, they will be generated safely.
PASSWORD="${PASSWORD:-paSSw000rd!}"
USERNAME="${USERNAME:-}"                                 # optional
EMAIL="${EMAIL:-}"                                       # optional
USERNAME_PREFIX="${USERNAME_PREFIX:-e2e-user}"           # used when USERNAME not provided
EMAIL_DOMAIN="${EMAIL_DOMAIN:-example.invalid}"          # used when EMAIL not provided

# If empty -> prefer localhost HTTP via parsed port from server.toml
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
  # Robustly prints the value after "Last sync:" (trimmed), even if indented.
  # Returns empty string if not found.
  local status_file="$1"
  awk '
    BEGIN{IGNORECASE=1}
    index(tolower($0), "last sync:") {
      sub(/.*[Ll]ast[[:space:]]+[Ss]ync[[:space:]]*:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
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
    sed -n '1,220p' "$status_file" >&2 || true
    exit 1
  fi

  if [[ "${last_sync,,}" == "never" ]]; then
    err "Server sync not confirmed: Last sync is 'Never'"
    err "atuin status output:"
    sed -n '1,220p' "$status_file" >&2 || true
    exit 1
  fi

  log "[OK] Server accepted sync (Last sync: ${last_sync})"
}

generate_credentials_if_missing() {
  local run_id prefix user email

  run_id="$(date +%s%N)"
  prefix="${USERNAME_PREFIX}"

  # sanitize: lowercase, replace '_' with '-', drop other invalid chars
  prefix="$(echo "${prefix}" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "${prefix}" ]]; then
    prefix="e2e"
  fi

  if [[ -z "${USERNAME}" ]]; then
    user="${prefix}-${run_id}"
    USERNAME="${user}"
  fi

  if echo "${USERNAME}" | grep -q '_'; then
    err "USERNAME contains '_' but server only allows alphanumeric + '-'"
    err "Set USERNAME without underscores, or rely on auto-generated username."
    exit 1
  fi

  if [[ -z "${EMAIL}" ]]; then
    email="${USERNAME}@${EMAIL_DOMAIN}"
    EMAIL="${email}"
  fi

  export USERNAME EMAIL
  log "Using USERNAME=${USERNAME}"
  log "Using EMAIL=${EMAIL}"
}

run_e2e() {
  require atuin

  local RUN_ID HISTFILE got status_file

  generate_credentials_if_missing

  # Required by atuin sync in non-interactive environments
  export ATUIN_SESSION="onhost-e2e-$(date +%s%N)"
  log "ATUIN_SESSION=${ATUIN_SESSION}"

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

  status_file="${HOME}/atuin_status.txt"
  atuin status > "${status_file}" 2>&1 || {
    err "atuin status failed"
    sed -n '1,220p' "${status_file}" >&2 || true
    exit 1
  }

  assert_server_accepted_sync "${status_file}"

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
