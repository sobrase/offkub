#!/usr/bin/env bash
# Deploy the cluster: sync offline assets to first master, start asset server, run playbook.
# Prerequisites:
#   1. Offline assets: run sudo ./scripts/fetch_offline_assets.sh on a machine with internet,
#      then set OFFLINE_ROOT to that dir (default /opt/offline) or copy it to first master at /opt/offline.
#   2. SSH access to all inventory hosts (same as sshm). First connect may require accepting host keys.
# Usage: OFFLINE_ROOT=/path/to/offline ./scripts/deploy.sh
#   Or if assets are already on first master at /opt/offline, run ./scripts/deploy.sh --assets-on-master
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
# Use project-local temp so Ansible does not require ~/.ansible
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$ROOT_DIR/.ansible/tmp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
# Prefer venv ansible if present
if [[ -x "$ROOT_DIR/.venv/bin/ansible-playbook" ]]; then
  PATH="$ROOT_DIR/.venv/bin:$PATH"
fi
OFFLINE_ROOT="${OFFLINE_ROOT:-/opt/offline}"
ASSETS_ON_MASTER=false
for arg in "$@"; do
  case "$arg" in
    --assets-on-master) ASSETS_ON_MASTER=true ;;
  esac
done

FIRST_MASTER=$(awk '/^\[masters\]$/{getline; print; exit}' inventory)
export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
export ANSIBLE_SSH_COMMON_ARGS="${ANSIBLE_SSH_COMMON_ARGS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"

run_ansible() {
  ansible-playbook -i inventory "$@"
}

echo "=== Preflight: SSH to all hosts ==="
ansible all -i inventory -m ping

if [[ "$ASSETS_ON_MASTER" == "true" ]]; then
  echo "=== Skipping sync (--assets-on-master); ensuring serve_assets.py and asset server on $FIRST_MASTER ==="
  scp "$ROOT_DIR/scripts/serve_assets.py" "$FIRST_MASTER:/opt/offline/" 2>/dev/null || true
  ansible "$FIRST_MASTER" -i inventory -m shell -a "pgrep -f 'serve_assets.py' || (nohup python3 /opt/offline/serve_assets.py -d /opt/offline -p 8081 </dev/null >/tmp/serve_assets.log 2>&1 &); sleep 1; pgrep -f serve_assets || true" -b
else
  if [[ ! -d "$OFFLINE_ROOT/pkgs" || ! -d "$OFFLINE_ROOT/images" ]]; then
    echo "Offline assets not found at $OFFLINE_ROOT (need pkgs/ and images/)." >&2
    echo "Run: sudo ./scripts/fetch_offline_assets.sh (on a machine with internet), then re-run with OFFLINE_ROOT=/opt/offline or copy /opt/offline to $FIRST_MASTER:/opt/offline and use --assets-on-master." >&2
    exit 1
  fi
  echo "=== Syncing $OFFLINE_ROOT to $FIRST_MASTER:/opt/offline ==="
  rsync -avz --delete "$OFFLINE_ROOT/" "$FIRST_MASTER:/opt/offline/" || scp -r "$OFFLINE_ROOT" "$FIRST_MASTER:/opt/offline"
  echo "=== Copying serve_assets.py to first master ==="
  scp "$ROOT_DIR/scripts/serve_assets.py" "$FIRST_MASTER:/opt/offline/"
  echo "=== Starting asset server on $FIRST_MASTER ==="
  ansible "$FIRST_MASTER" -i inventory -m shell -a "pkill -f serve_assets.py || true; sleep 1; nohup python3 /opt/offline/serve_assets.py -d /opt/offline -p 8081 </dev/null >/tmp/serve_assets.log 2>&1 & sleep 2; pgrep -f serve_assets || (cat /tmp/serve_assets.log)" -b
fi

echo "=== Running playbook ==="
run_ansible site.yml

echo "=== Deploy complete. Verify with: ./scripts/verify-after-deploy.sh ==="
