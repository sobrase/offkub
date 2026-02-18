#!/usr/bin/env bash
# Copy kubeconfig from the first master (vps1) to ~/.kube/config for local kubectl access.
# Usage: ./scripts/copy-kubeconfig.sh
# Requires: SSH access to the first master (as in inventory).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INVENTORY="${INVENTORY:-$ROOT_DIR/inventory}"
FIRST_MASTER=$(awk '/^\[masters\]$/{getline; print; exit}' "$INVENTORY")
if [[ -z "$FIRST_MASTER" ]]; then
  echo "Could not get first master from inventory ($INVENTORY)." >&2
  exit 1
fi
KUBE_DIR="${HOME}/.kube"
KUBE_CONFIG="${KUBE_DIR}/config"
mkdir -p "$KUBE_DIR"
echo "Fetching /etc/kubernetes/admin.conf from $FIRST_MASTER ..."
ssh "$FIRST_MASTER" "sudo cat /etc/kubernetes/admin.conf" > "$KUBE_CONFIG.new"
# Replace server URL so kubectl from this machine targets the master (not 127.0.0.1)
if grep -q 'server:.*127\.0\.0\.1' "$KUBE_CONFIG.new"; then
  sed -i "s|https://127.0.0.1:[0-9]*|https://${FIRST_MASTER}:6443|g" "$KUBE_CONFIG.new"
  echo "Updated API server URL to https://${FIRST_MASTER}:6443"
fi
chmod 600 "$KUBE_CONFIG.new"
mv "$KUBE_CONFIG.new" "$KUBE_CONFIG"
echo "Kubeconfig written to $KUBE_CONFIG"
echo "Test with: kubectl get nodes"
