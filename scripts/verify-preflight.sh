#!/usr/bin/env bash
# Run before any deployment. Verifies SSH connectivity to all hosts in the inventory.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$ROOT_DIR/.ansible/tmp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
[[ -x "$ROOT_DIR/.venv/bin/ansible" ]] && PATH="$ROOT_DIR/.venv/bin:$PATH"
echo "=== Preflight: SSH connectivity to all hosts ==="
ansible all -i inventory -m ping
echo "=== Preflight: list hosts ==="
ansible all -i inventory -m debug -a "var=inventory_hostname"
echo "Preflight OK: all hosts reachable."
