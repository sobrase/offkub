#!/usr/bin/env bash
# Run from first master: test DNS and service connectivity from a pod.
# Usage: run on first master: sudo KUBECONFIG=/etc/kubernetes/admin.conf ./scripts/check_cluster_connectivity.sh
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
export KUBECONFIG
NS=default
POD=connectivity-test-$$
echo "=== Creating test pod $POD ==="
kubectl run "$POD" --image=registry.local:5000/python:3.12-alpine --restart=Never -- sleep 300
kubectl wait --for=condition=Ready "pod/$POD" -n "$NS" --timeout=120s || true
echo "=== DNS test (resolve kubernetes.default) ==="
kubectl exec "$POD" -n "$NS" -- nslookup kubernetes.default.svc.cluster.local 2>&1 || true
echo "=== DNS test (resolve kubernetes) ==="
kubectl exec "$POD" -n "$NS" -- nslookup kubernetes 2>&1 || true
echo "=== Service reachability (curl Kubernetes API via ClusterIP) ==="
kubectl exec "$POD" -n "$NS" -- wget -q -O- --no-check-certificate https://kubernetes.default.svc.cluster.local/healthz 2>&1 || true
echo "=== Pod-to-pod: ping CoreDNS pod IP ==="
COREDNS_IP=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
if [[ -n "$COREDNS_IP" ]]; then
  kubectl exec "$POD" -n "$NS" -- wget -q -O- --timeout=3 "http://${COREDNS_IP}:8080/health" 2>&1 || true
else
  echo "Could not get CoreDNS pod IP"
fi
echo "=== Cleanup ==="
kubectl delete pod "$POD" -n "$NS" --force --grace-period=0 2>/dev/null || true
echo "=== Done ==="
