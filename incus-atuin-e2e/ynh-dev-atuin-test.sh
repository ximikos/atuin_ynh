#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vars.sh
source "${SCRIPT_DIR}/vars.sh"

log()  { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

require() { command -v "$1" >/dev/null 2>&1 || { err "Missing '$1'"; exit 1; }; }
require incus

usage() {
  cat >&2 <<'EOF'
Usage:
  ./ynh-dev-atuin-test.sh [YNH_CONTAINER] [DOMAIN]

Or via env:
  YNH_CONTAINER=ynh-dev-trixie-unstable DOMAIN=atuin.yolo.test ./ynh-dev-atuin-test.sh

Defaults:
  - If YNH_CONTAINER is not provided, script auto-picks:
      1) ynh-dev-trixie-unstable if exists
      2) ynh-dev-bookworm-unstable if exists
  - DOMAIN defaults to atuin.yolo.test

Cleanup:
  - Client containers are deleted automatically on script exit.
  - Set KEEP_CLIENTS=1 to keep them for debugging.
EOF
}

# ---- Arg/env handling ----
ARG_YNH_CONTAINER="${1:-}"
ARG_DOMAIN="${2:-}"

DEFAULT_DOMAIN="atuin.yolo.test"
DOMAIN="${DOMAIN:-${ARG_DOMAIN:-$DEFAULT_DOMAIN}}"

container_exists() {
  local n="$1"
  incus info "$n" >/dev/null 2>&1
}

auto_pick_container() {
  if container_exists "ynh-dev-trixie-unstable"; then
    echo "ynh-dev-trixie-unstable"
    return 0
  fi
  if container_exists "ynh-dev-bookworm-unstable"; then
    echo "ynh-dev-bookworm-unstable"
    return 0
  fi
  return 1
}

# Priority: env > arg > auto-pick
if [[ -n "${YNH_CONTAINER:-}" ]]; then
  YNH_CONTAINER="${YNH_CONTAINER}"
elif [[ -n "${ARG_YNH_CONTAINER}" ]]; then
  YNH_CONTAINER="${ARG_YNH_CONTAINER}"
else
  if ! YNH_CONTAINER="$(auto_pick_container)"; then
    err "No suitable YunoHost container found."
    err "Expected one of: ynh-dev-trixie-unstable, ynh-dev-bookworm-unstable"
    err "Run 'incus list' and pass the container name as 1st arg or set YNH_CONTAINER=..."
    usage
    exit 1
  fi
fi

# YunoHost's local CA cert path (common default)
YNH_CA_PATH="${YNH_CA_PATH:-/etc/ssl/certs/ca-yunohost_crt.pem}"

: "${CLIENT1_NAME:?Missing CLIENT1_NAME in vars.sh}"
: "${CLIENT2_NAME:?Missing CLIENT2_NAME in vars.sh}"
: "${CLIENT1_IMAGE:?Missing CLIENT1_IMAGE in vars.sh}"
: "${CLIENT2_IMAGE:?Missing CLIENT2_IMAGE in vars.sh}"
: "${VERSION:?Missing VERSION in vars.sh}"
: "${USERNAME:?Missing USERNAME in vars.sh}"
: "${EMAIL:?Missing EMAIL in vars.sh}"
: "${PASSWORD:?Missing PASSWORD in vars.sh}"

cleanup_instance() {
  local n="$1"
  if incus info "$n" >/dev/null 2>&1; then
    log "Deleting ${n}"
    incus delete -f "$n" >/dev/null
  fi
}

# Cleanup on exit:
# - clients were previously deleted only at the beginning
# - if the script fails mid-run, they'd be left behind
# - set KEEP_CLIENTS=1 to keep them for debugging
cleanup_on_exit() {
  local exit_code=$?
  if [[ "${KEEP_CLIENTS:-0}" == "1" ]]; then
    warn "KEEP_CLIENTS=1 set -> keeping client containers (${CLIENT1_NAME}, ${CLIENT2_NAME})"
    exit "$exit_code"
  fi

  # Always try cleanup; don't mask original failure
  set +e
  cleanup_instance "${CLIENT1_NAME}"
  cleanup_instance "${CLIENT2_NAME}"
  exit "$exit_code"
}
trap cleanup_on_exit EXIT

log "Atuin version: ${VERSION}"
log "YunoHost container: ${YNH_CONTAINER}"
log "Domain: ${DOMAIN}"

if ! incus info "${YNH_CONTAINER}" >/dev/null 2>&1; then
  err "YunoHost container '${YNH_CONTAINER}' not found (incus info failed)."
  err "Available containers:"
  incus list >&2 || true
  exit 1
fi

log "Getting YunoHost container IPv4..."
YNH_IP="$(incus list "${YNH_CONTAINER}" -c 4 --format csv | head -n1 | cut -d' ' -f1 | cut -d, -f1)"
if [[ -z "${YNH_IP}" ]]; then
  err "Could not detect YunoHost container IPv4."
  exit 1
fi
log "${YNH_CONTAINER} IPv4 = ${YNH_IP}"

install_atuin_quiet() {
  local n="$1"
  log "${n}: Installing atuin ${VERSION}..."
  incus exec "$n" -- bash -lc "
    set -euo pipefail
    log=/tmp/apt-install.log
    rm -f \"\$log\"

    export DEBIAN_FRONTEND=noninteractive
    {
      apt-get -qq update

      # We install ca-certificates mainly because we need HTTPS to:
      #  - download Atuin release artifacts from GitHub via curl
      # It also provides the base system trust store, which matters later if the YunoHost
      # instance uses HTTPS (we then add YunoHost's *local* CA on top of this).
      apt-get -qq install -y ca-certificates curl tar openssl
    } >>\"\$log\" 2>&1 || {
      echo '[ERROR] apt install failed. Last 120 log lines:' >&2
      tail -n 120 \"\$log\" >&2 || true
      exit 1
    }

    arch=\$(uname -m)
    case \"\$arch\" in
      x86_64)  pkg='atuin-x86_64-unknown-linux-gnu.tar.gz' ;;
      aarch64) pkg='atuin-aarch64-unknown-linux-gnu.tar.gz' ;;
      *) echo \"[ERROR] Unsupported arch: \$arch\" >&2; exit 1 ;;
    esac

    cd /tmp
    curl -fsSL -o atuin.tgz \"https://github.com/atuinsh/atuin/releases/download/v${VERSION}/\${pkg}\"
    tar -xzf atuin.tgz
    dir=\$(find . -maxdepth 1 -type d -name 'atuin-*unknown-linux-*' | head -n1)
    install -m 0755 \"\${dir}/atuin\" /usr/local/bin/atuin

    /usr/local/bin/atuin --version
  "
}

inject_hosts() {
  local n="$1"

  # We hardcode the DOMAIN -> YNH_IP mapping into /etc/hosts because this is a *local* test domain
  # (e.g. atuin.yolo.test). We don't want or rely on external DNS for this E2E test.
  # This makes "curl http(s)://$DOMAIN" and Atuin sync resolve to the YunoHost container reliably.
  log "${n}: Injecting /etc/hosts: ${YNH_IP} ${DOMAIN}"
  incus exec "$n" -- bash -lc "
    set -euo pipefail
    if ! grep -qE \"^${YNH_IP//./\\.}[[:space:]]+${DOMAIN//./\\.}(\\s|$)\" /etc/hosts; then
      echo \"${YNH_IP} ${DOMAIN}\" >> /etc/hosts
    fi
    tail -n 5 /etc/hosts
  "
}

install_yunohost_ca_into_client() {
  local client="$1"

  log "${client}: Installing YunoHost CA from ${YNH_CONTAINER}:${YNH_CA_PATH} ..."
  # Stream CA cert from YunoHost container into client container and register it in system trust store.
  # This is needed only when the server is reached via HTTPS and uses a local/self-signed CA,
  # otherwise clients will fail with TLS errors (UnknownIssuer).
  incus exec "${YNH_CONTAINER}" -- bash -lc "test -s '${YNH_CA_PATH}'" >/dev/null 2>&1 || {
    err "YunoHost CA file not found or empty: ${YNH_CA_PATH} (override via YNH_CA_PATH=...)"
    exit 1
  }

  incus exec "${YNH_CONTAINER}" -- bash -lc "cat '${YNH_CA_PATH}'" \
    | incus exec "${client}" -- bash -lc "
      set -euo pipefail
      mkdir -p /usr/local/share/ca-certificates
      cat > /usr/local/share/ca-certificates/yunohost-local-ca.crt
      update-ca-certificates >/dev/null 2>&1 || true
      echo '[INFO] YunoHost CA installed into system trust store' >&2
    "
}

# IMPORTANT: This function must output ONLY "http" or "https" on stdout.
detect_scheme() {
  local n="$1"

  log "${n}: Detecting whether server redirects HTTP->HTTPS..."

  local location
  location="$(incus exec "$n" -- bash -lc "
    set -e
    curl -sS -I http://${DOMAIN}/ --connect-timeout 3 --max-time 6 2>/dev/null \
      | awk 'tolower(\$0) ~ /^location: / {print \$2}' \
      | tail -n1 \
      | tr -d '\r'
  " || true)"

  if [[ "${location}" == https://* ]]; then
    echo "https"
    return 0
  fi

  echo "http"
}

delete_remote_account_from_client1() {
  # Client-side deletion of the server account.
  # We try to find a non-interactive flag if supported; otherwise fall back to piping "yes".
  log "[CLEANUP] ${CLIENT1_NAME}: deleting remote account for '${USERNAME}'"

  incus exec "${CLIENT1_NAME}" -- bash -lc "
    set -euo pipefail
    export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
    export ATUIN_SESSION=\"ynh-test-client1-cleanup-\$(date +%s%N)\"

    # Ensure we're logged in (client1 was logged out earlier)
    atuin login -u '${USERNAME}' -p '${PASSWORD}' -k '${KEY}'

    help=\$(atuin account delete --help 2>&1 || true)

    if echo \"\$help\" | grep -qE '(--yes|-y|--force)'; then
      if echo \"\$help\" | grep -qE '(^|[[:space:]])--yes([[:space:]]|,|$)'; then
        atuin account delete --yes
      elif echo \"\$help\" | grep -qE '(^|[[:space:]])-y([[:space:]]|,|$)'; then
        atuin account delete -y
      elif echo \"\$help\" | grep -qE '(^|[[:space:]])--force([[:space:]]|,|$)'; then
        atuin account delete --force
      else
        # Flag hinted but not clearly parseable; fall back to prompt automation
        yes | atuin account delete
      fi
    else
      # No non-interactive flags detected -> best-effort answer the prompt
      yes | atuin account delete
    fi
  "
}

log "Recreating clients..."
cleanup_instance "${CLIENT1_NAME}"
cleanup_instance "${CLIENT2_NAME}"

log "Launching ${CLIENT1_NAME}: ${CLIENT1_IMAGE}"
incus launch "${CLIENT1_IMAGE}" "${CLIENT1_NAME}"

log "Launching ${CLIENT2_NAME}: ${CLIENT2_IMAGE}"
incus launch "${CLIENT2_IMAGE}" "${CLIENT2_NAME}"

install_atuin_quiet "${CLIENT1_NAME}"
install_atuin_quiet "${CLIENT2_NAME}"

inject_hosts "${CLIENT1_NAME}"
inject_hosts "${CLIENT2_NAME}"

scheme="$(detect_scheme "${CLIENT1_NAME}")"
SYNC_ADDR="${scheme}://${DOMAIN}"
log "Using ATUIN_SYNC_ADDRESS=${SYNC_ADDR}"

if [[ "${scheme}" == "https" ]]; then
  warn "HTTPS detected. Installing YunoHost local CA into both clients to avoid UnknownIssuer..."
  # Only do this for HTTPS. For HTTP there's no TLS validation to fix, and adding extra CA handling
  # would just be unnecessary moving parts.
  install_yunohost_ca_into_client "${CLIENT1_NAME}"
  install_yunohost_ca_into_client "${CLIENT2_NAME}"
fi

log "[TEST] ${CLIENT1_NAME}: register + execute 5 harmless cmds + import + sync"
incus exec "${CLIENT1_NAME}" -- bash -lc "
  set -euo pipefail
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"ynh-test-client1-\$(date +%s%N)\"

  atuin register -u '${USERNAME}' -e '${EMAIL}' -p '${PASSWORD}'

  # RUN_ID uniquely identifies *this* test run (nanosecond timestamp).
  # We prefix all injected history items with ATUIN_TEST_\${RUN_ID}_* so we can:
  #  - grep only our own test commands
  #  - avoid false positives from existing shell history
  #  - run this script repeatedly without clashes
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
  err "Failed to read RUN_ID from ${CLIENT1_NAME}"
  exit 1
fi
log "RUN_ID=${RUN_ID}"

log "${CLIENT1_NAME}: extracting key"
KEY="$(incus exec "${CLIENT1_NAME}" -- bash -lc "export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'; atuin key" | tr -d '\r' | sed -n '1p')"
if [[ -z "${KEY}" ]]; then
  err "Failed to read atuin key from ${CLIENT1_NAME}"
  exit 1
fi

log "[TEST] ${CLIENT1_NAME}: logout"
incus exec "${CLIENT1_NAME}" -- bash -lc "
  set -euo pipefail
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"ynh-test-client1-logout-\$(date +%s%N)\"
  atuin logout
"

log "[TEST] ${CLIENT2_NAME}: login + sync + verify 5 cmds were synced"
incus exec "${CLIENT2_NAME}" -- bash -lc "
  set -euo pipefail
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"ynh-test-client2-\$(date +%s%N)\"

  atuin login -u '${USERNAME}' -p '${PASSWORD}' -k '${KEY}'
  atuin sync

  got=\$(atuin history list --cmd-only | grep -F \"ATUIN_TEST_${RUN_ID}_\" | sort -u | wc -l)
  if [ \"\$got\" -ne 5 ]; then
    echo \"[ERROR] Expected 5 synced commands for RUN_ID=${RUN_ID}, got \$got\" >&2
    echo \"[DEBUG] Matching lines:\" >&2
    atuin history list --cmd-only | grep -F \"ATUIN_TEST_${RUN_ID}_\" | tail -n 100 >&2 || true
    exit 1
  fi

  echo \"[OK] Synced 5 test commands (RUN_ID=${RUN_ID})\"
  atuin status | sed -n '1,120p'
"

# Ensure no user remains on server after successful tests (client-side).
delete_remote_account_from_client1

log "[OK] Tests passed: register, execute+record 5 cmds, import, sync, login, verify sync, delete account."
log "If something failed, useful server-side logs:"
log "  incus exec ${YNH_CONTAINER} -- journalctl -u nginx --no-pager -n 200 -l"
log "  incus exec ${YNH_CONTAINER} -- tail -n 200 /var/log/nginx/${DOMAIN}-access.log 2>/dev/null || true"
log "  incus exec ${YNH_CONTAINER} -- tail -n 200 /var/log/nginx/${DOMAIN}-error.log  2>/dev/null || true"
log "  incus exec ${YNH_CONTAINER} -- journalctl -u atuin --no-pager -n 120 -l"

