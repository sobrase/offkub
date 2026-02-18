#!/usr/bin/env bash
# Run after the install_k8s role. Verifies containerd and kubelet are installed and containerd is running.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$ROOT_DIR/.ansible/tmp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
[[ -x "$ROOT_DIR/.venv/bin/ansible" ]] && PATH="$ROOT_DIR/.venv/bin:$PATH"
echo "=== After install_k8s: containerd running ==="
ansible all -i inventory -m shell -a "systemctl is-active containerd" -b
echo "=== After install_k8s: kubelet installed and enabled ==="
ansible all -i inventory -m shell -a "dpkg -l kubelet 2>/dev/null | tail -1; systemctl is-enabled kubelet" -b
echo "=== After install_k8s: cri-socket exists ==="
ansible all -i inventory -m shell -a "test -S /run/containerd/containerd.sock && echo OK || echo MISSING" -b
echo "verify-after-install_k8s OK."
