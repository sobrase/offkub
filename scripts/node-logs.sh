#!/usr/bin/env bash
# Run log commands on a node or from the first master (kubectl).
# Usage: ./scripts/node-logs.sh <node> [kubelet|containerd|kubectl [pod_ns/pod_name]]
#   node: inventory hostname or "first-master"
#   kubelet: journalctl -u kubelet (on that node)
#   containerd: journalctl -u containerd (on that node)
#   kubectl [pod]: run kubectl logs from first master (default: show pods -A)
# Examples:
#   ./scripts/node-logs.sh vps-2 kubelet
#   ./scripts/node-logs.sh first-master containerd
#   ./scripts/node-logs.sh first-master kubectl
#   ./scripts/node-logs.sh first-master kubectl kube-system/coredns-xxx
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INVENTORY="$ROOT_DIR/inventory"
FIRST_MASTER=$(awk '/^\[masters\]$/{getline; print; exit}' "$INVENTORY")
resolve_node() {
  local n="$1"
  if [[ "$n" == "first-master" ]]; then echo "$FIRST_MASTER"; else echo "$n"; fi
}
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <node> [kubelet|containerd|kubectl [pod]]" >&2
  exit 1
fi
NODE=$(resolve_node "$1")
CMD="${2:-}"
case "$CMD" in
  kubelet)   ssh "$NODE" "journalctl -u kubelet -f --no-pager" ;;
  containerd) ssh "$NODE" "journalctl -u containerd -f --no-pager" ;;
  kubectl)
    if [[ -n "${3:-}" ]]; then
      ssh "$FIRST_MASTER" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl logs -f ${3} ${4:-}"
    else
      ssh "$FIRST_MASTER" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A"
    fi
    ;;
  "")
    echo "Usage: $0 <node> [kubelet|containerd|kubectl [pod]]" >&2
    echo "  node: $(grep -E '^[a-zA-Z0-9].*' "$INVENTORY" | grep -v '^\[' | head -5 | tr '\n' ' ')" >&2
    exit 1
    ;;
  *)
    echo "Unknown command: $CMD (use kubelet, containerd, or kubectl)" >&2
    exit 1
    ;;
esac
