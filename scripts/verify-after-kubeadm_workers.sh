#!/usr/bin/env bash
# Run after the kubeadm_workers role. Verifies worker nodes have joined the cluster.
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
echo "=== After kubeadm_workers: all nodes (masters + workers) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide" -b
echo "=== After kubeadm_workers: kubelet running on workers ==="
ansible workers -i inventory -m shell -a "systemctl is-active kubelet" -b
echo "verify-after-kubeadm_workers OK."
