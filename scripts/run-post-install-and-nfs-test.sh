#!/usr/bin/env bash
# Run post_install_checks (fix node readiness, optional GPU) and NFS storage test.
# Use when the cluster is already deployed but nodes are NotReady, or to re-run NFS test.
# NFS (nfs_server + nfs_csi) must already be deployed (run full site.yml once).
# Prerequisites: SSH to masters; assets on first master if images are needed.
# Usage: ./scripts/run-post-install-and-nfs-test.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$ROOT_DIR/.ansible/tmp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
if [[ -x "$ROOT_DIR/.venv/bin/ansible-playbook" ]]; then
  PATH="$ROOT_DIR/.venv/bin:$PATH"
fi
export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
ansible-playbook -i inventory site.yml --start-at-task "Disable kube-proxy" "$@"
