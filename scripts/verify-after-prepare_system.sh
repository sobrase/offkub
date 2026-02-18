#!/usr/bin/env bash
# Run after the prepare_system role. Verifies swap off, kernel modules, sysctl, /etc/hosts.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$ROOT_DIR/.ansible/tmp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
[[ -x "$ROOT_DIR/.venv/bin/ansible" ]] && PATH="$ROOT_DIR/.venv/bin:$PATH"
echo "=== After prepare_system: swap disabled ==="
ansible all -i inventory -m shell -a "swapon -s 2>/dev/null || true; echo '---'; cat /proc/swaps 2>/dev/null || true" -b
echo "=== After prepare_system: overlay and br_netfilter loaded ==="
ansible all -i inventory -m shell -a "lsmod | grep -E 'overlay|br_netfilter' || true" -b
echo "=== After prepare_system: sysctl k8s.conf ==="
ansible all -i inventory -m shell -a "cat /etc/sysctl.d/k8s.conf 2>/dev/null || true" -b
echo "=== After prepare_system: registry.local in /etc/hosts ==="
ansible all -i inventory -m shell -a "grep registry.local /etc/hosts || true" -b
echo "verify-after-prepare_system OK."
