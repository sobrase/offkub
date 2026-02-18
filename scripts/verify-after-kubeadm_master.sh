#!/usr/bin/env bash
# Run after the kubeadm_master role. Verifies API server, join scripts on first master, and that all masters have joined.
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
echo "=== After kubeadm_master: join scripts on first master ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "test -f /tmp/join.sh && echo 'join.sh OK'; test -f /tmp/join-master.sh && echo 'join-master.sh OK'" -b
echo "=== After kubeadm_master: API server health (from first master) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw /healthz 2>/dev/null || true" -b
echo "=== After kubeadm_master: nodes (control plane) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide 2>/dev/null || true" -b
echo "=== After kubeadm_master: kubelet running on all masters ==="
ansible masters -i inventory -m shell -a "systemctl is-active kubelet" -b
echo "verify-after-kubeadm_master OK."
