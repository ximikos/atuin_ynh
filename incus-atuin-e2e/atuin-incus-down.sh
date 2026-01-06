#!/usr/bin/env bash
set -euo pipefail

# Load shared variables (SERVER_NAME, CLIENT1_NAME, CLIENT2_NAME, BASE_DIR, ...)
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
: "${BASE_DIR:?Missing BASE_DIR in vars.sh}"

for n in "${CLIENT1_NAME}" "${CLIENT2_NAME}" "${SERVER_NAME}"; do
  if incus info "$n" >/dev/null 2>&1; then
    echo "[INFO] Deleting $n"
    incus delete -f "$n"
  else
    echo "[INFO] Not found: $n"
  fi
done

echo "[OK] Containers removed"
echo "[INFO] Persistent data kept in:"
echo "  ${BASE_DIR}"
echo
echo "[INFO] To delete everything (including root-owned SQLite files) run:"
echo "  sudo rm -rfv \"$(dirname "${BASE_DIR}")/\""

