#!/usr/bin/env bash
# Destroy the cluster then recreate it (same as deploy.sh). Verifies nodes, Calico, Traefik, NFS default storage.
# Usage: ./scripts/destroy_and_redeploy.sh [--assets-on-master]
#   Or: OFFLINE_ROOT=/path/to/offline ./scripts/destroy_and_redeploy.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$ROOT_DIR/.ansible/tmp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
[[ -x "$ROOT_DIR/.venv/bin/ansible-playbook" ]] && PATH="$ROOT_DIR/.venv/bin:$PATH"
export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
export ANSIBLE_SSH_COMMON_ARGS="${ANSIBLE_SSH_COMMON_ARGS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"

echo "=== Destroying cluster (kubeadm reset on all nodes) ==="
ansible-playbook -i inventory destroy_cluster.yml

echo "=== Applying firewall (restrict_access) so first master allows 8081/5000 from peers ==="
ansible-playbook -i inventory restrict_access.yml

echo "=== Recreating cluster (deploy) ==="
"$ROOT_DIR/scripts/deploy.sh" "$@"

echo "=== Verifying cluster (nodes, pods, Traefik, storage) ==="
"$ROOT_DIR/scripts/verify-after-deploy.sh"

echo "=== Destroy + redeploy + verify done. ==="
