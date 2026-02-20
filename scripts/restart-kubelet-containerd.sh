#!/usr/bin/env bash
# Restart kubelet and containerd on all nodes.
# Run from repo root. Usage: ./scripts/restart-kubelet-containerd.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
if [[ -x "$ROOT_DIR/.venv/bin/ansible-playbook" ]]; then
  exec "$ROOT_DIR/.venv/bin/ansible-playbook" -i inventory restart_kubelet_containerd.yml "$@"
fi
ansible-playbook -i inventory restart_kubelet_containerd.yml "$@"
