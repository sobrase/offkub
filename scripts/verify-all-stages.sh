#!/usr/bin/env bash
# Run all verification scripts in deployment order. Use after each corresponding playbook stage or at the end.
# Usage: ./scripts/verify-all-stages.sh [stage]
#   No argument: run preflight only (safe before any deploy).
#   Stage: preflight | prepare_system | install_k8s | setup_registry | kubeadm_master | kubeadm_workers | deploy
#   Or run individual scripts: verify-after-prepare_system.sh, etc.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
run() { echo ">>> $*"; "$@"; }
stage="${1:-preflight}"
case "$stage" in
  preflight)    run "$ROOT_DIR/scripts/verify-preflight.sh" ;;
  prepare_system) run "$ROOT_DIR/scripts/verify-after-prepare_system.sh" ;;
  install_k8s)  run "$ROOT_DIR/scripts/verify-after-install_k8s.sh" ;;
  setup_registry) run "$ROOT_DIR/scripts/verify-after-setup_registry.sh" ;;
  kubeadm_master) run "$ROOT_DIR/scripts/verify-after-kubeadm_master.sh" ;;
  kubeadm_workers) run "$ROOT_DIR/scripts/verify-after-kubeadm_workers.sh" ;;
  deploy)       run "$ROOT_DIR/scripts/verify-after-deploy.sh" ;;
  all)
    run "$ROOT_DIR/scripts/verify-preflight.sh"
    run "$ROOT_DIR/scripts/verify-after-prepare_system.sh"
    run "$ROOT_DIR/scripts/verify-after-install_k8s.sh"
    run "$ROOT_DIR/scripts/verify-after-setup_registry.sh"
    run "$ROOT_DIR/scripts/verify-after-kubeadm_master.sh"
    run "$ROOT_DIR/scripts/verify-after-kubeadm_workers.sh"
    run "$ROOT_DIR/scripts/verify-after-deploy.sh"
    ;;
  *) echo "Usage: $0 [preflight|prepare_system|install_k8s|setup_registry|kubeadm_master|kubeadm_workers|deploy|all]" >&2; exit 1 ;;
esac
