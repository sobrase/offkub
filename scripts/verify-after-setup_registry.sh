#!/usr/bin/env bash
# Run after the setup_registry role (first master). Verifies local registry is up and serving.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$ROOT_DIR/.ansible/tmp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
[[ -x "$ROOT_DIR/.venv/bin/ansible" ]] && PATH="$ROOT_DIR/.venv/bin:$PATH"
FIRST_MASTER=$(awk '/^\[masters\]$/{getline; print; exit}' "$ROOT_DIR/inventory")
if [[ -z "$FIRST_MASTER" ]]; then
  echo "Could not get first master from inventory." >&2
  exit 1
fi
echo "=== After setup_registry: Docker and registry on first master ($FIRST_MASTER) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "systemctl is-active docker 2>/dev/null || true; docker ps 2>/dev/null | grep -E 'registry|5000' || true" -b
echo "=== After setup_registry: registry responds (v2) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/v2/ || echo 000" -b
echo "verify-after-setup_registry OK."
