#!/usr/bin/env bash
# Check why Kubernetes nodes are NotReady (taint node.kubernetes.io/not-ready).
# Usage: KUBECONFIG=/path/to/admin.conf ./scripts/check_node_readiness.sh
#        Or run on first master: sudo KUBECONFIG=/etc/kubernetes/admin.conf ./check_node_readiness.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }

if ! command -v kubectl &>/dev/null; then
  err "kubectl not found. Install kubectl or run this script on a node that has it."
  exit 1
fi

if [[ -z "${KUBECONFIG:-}" ]] && [[ ! -f "$HOME/.kube/config" ]] && [[ ! -f "/etc/kubernetes/admin.conf" ]]; then
  err "KUBECONFIG not set and no default kubeconfig found."
  echo "  Example: export KUBECONFIG=/etc/kubernetes/admin.conf"
  echo "  Or: scp <first-master>:/etc/kubernetes/admin.conf ~/.kube/config"
  exit 1
fi

# Use admin.conf on first master if present and nothing else set
if [[ -z "${KUBECONFIG:-}" ]] && [[ -f /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
  info "Using KUBECONFIG=/etc/kubernetes/admin.conf"
fi

KUBECTL="kubectl"

echo "=============================================="
echo "  Node readiness check"
echo "=============================================="

# 1. Nodes
info "Nodes:"
$KUBECTL get nodes -o wide 2>/dev/null || { err "Failed to get nodes (check KUBECONFIG and API reachability)."; exit 1; }
echo ""

NOT_READY=$($KUBECTL get nodes --no-headers 2>/dev/null | grep -v " Ready " || true)
if [[ -n "$NOT_READY" ]]; then
  warn "Some nodes are not Ready:"
  echo "$NOT_READY"
  echo ""
fi

# 2. Tigera operator
info "Tigera Operator (tigera-operator namespace):"
$KUBECTL get pods -n tigera-operator -o wide 2>/dev/null || warn "Could not list tigera-operator pods (namespace may not exist yet)."
echo ""

# 3. Calico
info "Calico (calico-system namespace):"
$KUBECTL get pods -n calico-system -o wide 2>/dev/null || warn "Could not list calico-system pods."
echo ""

# 4. Kube-system core (e.g. CoreDNS often pending when nodes NotReady)
info "Core pods (kube-system):"
$KUBECTL get pods -n kube-system -o wide 2>/dev/null || true
echo ""

# 5. Events (last 20)
info "Recent cluster events (last 20):"
$KUBECTL get events -A --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
echo ""

# 6. If any node is NotReady, describe first one
FIRST_NOT_READY=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1; exit}')
if [[ -n "${FIRST_NOT_READY:-}" ]]; then
  info "Conditions for first NotReady node ($FIRST_NOT_READY):"
  $KUBECTL describe node "$FIRST_NOT_READY" 2>/dev/null | sed -n '/Conditions:/,/Addresses:/p' || true
  echo ""
  err "Summary: nodes have taint node.kubernetes.io/not-ready. Common causes:"
  echo "  1. Calico/CNI pods not Running -> fix image pull or network to registry.local:5000"
  echo "  2. kubelet or containerd failing on nodes -> check: systemctl status kubelet containerd; journalctl -u kubelet -n 50"
  echo "  3. Firewall blocking node-to-node or node-to-API traffic"
  exit 1
fi

info "All nodes are Ready."
exit 0
