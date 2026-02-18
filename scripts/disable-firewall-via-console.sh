#!/bin/sh
# Run this on each node via the provider's console (VNC/KVM or rescue) if you're
# locked out by the restrict_access firewall. Then you can SSH again and run
# the playbook with restrict_access_enabled: false to clean up.
set -e
# Load permissive iptables rules (accept all)
printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\nCOMMIT\n' | sudo iptables-restore
printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\nCOMMIT\n' | sudo ip6tables-restore
echo "Firewall disabled. SSH should work again."
