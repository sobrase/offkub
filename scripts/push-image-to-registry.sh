#!/usr/bin/env bash
# Push an image from your laptop to the cluster registry (first master, port 5000).
# Usage: ./scripts/push-image-to-registry.sh [IMAGE [TAG]]
#   IMAGE defaults to busybox, TAG defaults to laptop-test.
# Requires: Docker with REGISTRY added to insecure-registries (see below).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INVENTORY="${INVENTORY:-$ROOT_DIR/inventory}"

# First master hostname from inventory (no Ansible needed)
FIRST_MASTER=$(awk '/^\[masters\]/{getline; print; exit}' "$INVENTORY")
REGISTRY="${FIRST_MASTER}:5000"

IMAGE="${1:-busybox}"
TAG="${2:-laptop-test}"
FULL="${REGISTRY}/${IMAGE}:${TAG}"

echo "Registry: $REGISTRY (first master: $FIRST_MASTER)"
echo "Image:    $IMAGE:$TAG -> $FULL"
echo ""

# Docker: ensure insecure registry is set (Linux: /etc/docker/daemon.json)
if command -v docker &>/dev/null; then
  if ! docker info 2>/dev/null | grep -q "Insecure Registries" || true; then
    echo "Ensure $REGISTRY is in Docker's insecure-registries (e.g. in /etc/docker/daemon.json):"
    echo "  {\"insecure-registries\": [\"$REGISTRY\"]}"
    echo "Then: sudo systemctl restart docker"
    echo ""
  fi
  echo "Pulling $IMAGE (if not present)..."
  docker pull "$IMAGE" 2>/dev/null || true
  echo "Tagging and pushing to $FULL ..."
  docker tag "$IMAGE" "$FULL"
  docker push "$FULL"
  echo "Done. Push succeeded. Test in cluster with:"
  echo "  kubectl run test-registry --image=$FULL --restart=Never -- /bin/sh -c 'echo hello from registry'"
  echo "  kubectl logs test-registry"
  echo "  kubectl delete pod test-registry"
  exit 0
fi

echo "Docker not found. Use Podman or add Docker and re-run."
exit 1
