#!/usr/bin/env bash
# Run after full playbook (all roles). Verifies cluster, pods, and optional Traefik/sample app.
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
echo "=== After full deploy: nodes ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide" -b
echo "=== Storage class (default should be nfs-csi) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get storageclass -o wide" -b
echo "=== Calico (calico-system) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n calico-system -o wide" -b
echo "=== Traefik ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n traefik -o wide" -b
echo "=== Pods (all namespaces) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A" -b
echo "=== Gateways and HTTPRoutes (Traefik) ==="
ansible "$FIRST_MASTER" -i inventory -m shell -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get gateways,httproutes -A 2>/dev/null || true" -b
echo "verify-after-deploy OK."
