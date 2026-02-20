#!/usr/bin/env bash
# One-shot repair for nodes stuck in NotReady.
# Run from repo root (where you normally run deploy.sh). Requires SSH to first master.
# Usage: ./scripts/repair-node-readiness.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$ROOT_DIR/.ansible/tmp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
if [[ -x "$ROOT_DIR/.venv/bin/ansible-playbook" ]]; then
  PATH="$ROOT_DIR/.venv/bin:$PATH"
fi
export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
ansible-playbook -i inventory repair_node_readiness.yml "$@"
