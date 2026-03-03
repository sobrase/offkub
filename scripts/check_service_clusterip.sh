#!/usr/bin/env bash
# Diagnose why some Services have no ClusterIP.
# Run from first master: sudo KUBECONFIG=/etc/kubernetes/admin.conf ./scripts/check_service_clusterip.sh
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
export KUBECONFIG

echo "=== Services with no ClusterIP (CLUSTER-IP is None or <none>) ==="
kubectl get svc -A -o wide 2>/dev/null | awk 'NR==1 || $4=="None" || $4=="<none>"' || true

echo ""
echo "=== Count of services without ClusterIP ==="
none_count=$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.clusterIP=="")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l)
echo "$none_count"

echo ""
echo "=== kubeadm-config ClusterConfiguration (networking) ==="
kubectl get cm kubeadm-config -n kube-system -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null | grep -A5 '^networking:' || echo "Could not read kubeadm-config or no networking section"

echo ""
echo "=== kube-apiserver --service-cluster-ip-range (on this node) ==="
if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
  grep -o '\--service-cluster-ip-range=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null || echo "Not found in manifest"
else
  echo "No static pod manifest (run on a control-plane node)"
fi

echo ""
echo "=== Hint ==="
echo "If serviceSubnet is missing or apiserver has no --service-cluster-ip-range, the ClusterIP allocator has no range."
echo "Fix: 1) kubectl edit cm kubeadm-config -n kube-system  -> add under networking: serviceSubnet: \"10.96.0.0/12\""
echo "     2) On each control-plane node, add to kube-apiserver manifest (in /etc/kubernetes/manifests/):"
echo "        - --service-cluster-ip-range=10.96.0.0/12"
echo "        Then kubelet will restart the apiserver. Or run: kubeadm upgrade apply <version> --config <config-with-serviceSubnet>"
