#!/usr/bin/env bash
# SSH into a node by inventory name. Uses your ~/.ssh/config (same as sshm).
# Usage: ./scripts/ssh-node.sh <node>
#   node: inventory hostname (e.g. vps-1.vps.ovh.net, vps-2) or "first-master"
# Examples:
#   ./scripts/ssh-node.sh first-master
#   ./scripts/ssh-node.sh vps-4
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INVENTORY="$ROOT_DIR/inventory"
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <node>" >&2
  echo "  node: inventory hostname or 'first-master'" >&2
  echo "Hosts in inventory:" >&2
  grep -E '^[a-zA-Z0-9].*' "$INVENTORY" | grep -v '^\[' || true
  exit 1
fi
NODE="$1"
if [[ "$NODE" == "first-master" ]]; then
  NODE=$(awk '/^\[masters\]$/{getline; print; exit}' "$INVENTORY")
fi
exec ssh "$NODE" "${@:2}"
