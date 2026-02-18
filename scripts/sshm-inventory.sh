#!/usr/bin/env bash
# List SSH hosts from sshm (reads ~/.ssh/config) for use when building the Ansible inventory.
# Usage: ./scripts/sshm-inventory.sh
# To regenerate inventory with 3 masters + 2 workers, run this and assign first 3 to [masters], next 2 to [workers].
set -euo pipefail
if ! command -v sshm &>/dev/null; then
  echo "sshm not found. Install it or use ~/.ssh/config directly." >&2
  exit 1
fi
echo "# Hosts from: sshm search \"\""
sshm search ""
