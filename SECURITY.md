# Restricting access to your cluster

If your servers are exposed on the internet, you can whitelist all ports except SSH by running the **restrict_access** playbook. It uses **iptables** on each node to:

- Allow **SSH (22)** from anyone (no whitelist).
- Allow **all other ports** only from your IP(s) and from **other cluster nodes** (asset server, registry, Calico, etc.).
- Allow **established/related** connections and **loopback**.
- **Drop** all other incoming traffic.

The firewall is **not** run as part of the main deploy (`site.yml`). You apply it separately when you want it.

## Steps

### 1. Get your IP

From your laptop (the machine you use to SSH and run `kubectl`):

```bash
curl -s ifconfig.me
```

Use that IP in CIDR form, e.g. `1.2.3.4/32`. If your IP changes (e.g. home broadband), you’ll need to update the vars file and re-run the playbook, or use a VPN with a static exit IP.

### 2. Configure the firewall

Edit **`vars/restrict_access.yml`**:

```yaml
restrict_access_enabled: true
allowed_source_ips:
  - "YOUR_IP/32"
```

You can add several IPs (e.g. home and office):

```yaml
allowed_source_ips:
  - "1.2.3.4/32"
  - "5.6.7.8/32"
```

If you use a **non-standard SSH port** (e.g. 2222), set `restrict_access_ssh_port: 2222` in the same file so the firewall allows it from anyone.

### 3. Apply the firewall

Run the restrict_access playbook (it uses `vars/restrict_access.yml`):

```bash
ansible-playbook -i inventory restrict_access.yml
```

### 4. Disabling or changing the firewall

Set `restrict_access_enabled: false` in `vars/restrict_access.yml` and run `restrict_access.yml` again; the role will load permissive iptables rules and disable the firewall. To change allowed IPs, edit the vars file and re-run the playbook.

### 5. Persistence across reboot

The role writes rules to `/etc/iptables/rules.v4` and `rules.v6` and loads them with `iptables-restore` / `ip6tables-restore`. The **netfilter-persistent** service is enabled so the same rules are loaded on boot.

## What stays allowed

- **Anyone** → SSH (22) only.
- **Your IP(s)** → any port (SSH, Kubernetes API 6443, etc.).
- **Other cluster nodes** (from inventory) → any port (asset server 8081, registry 5000, Calico, etc.).
- **Established/related** and **loopback** traffic.

## Changing your IP

If your IP changes:

1. Update `allowed_source_ips` in `vars/restrict_access.yml` (and/or use a VPN with a fixed IP).
2. Re-run: `ansible-playbook -i inventory restrict_access.yml`.

If you lock yourself out (e.g. SSH stops working), use the provider’s **console** (VNC/KVM or rescue) on each node and run:

```sh
printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\nCOMMIT\n' | sudo iptables-restore
printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\nCOMMIT\n' | sudo ip6tables-restore
```

Or run the script: `./scripts/disable-firewall-via-console.sh`

Then SSH should work again. Set `restrict_access_enabled: false` in `vars/restrict_access.yml` and run `restrict_access.yml` to clean up, then fix your config and re-apply.

---

## SSH jail (fail2ban)

In addition to the firewall, you can harden SSH with **fail2ban**: any source IP that fails SSH authentication **5 times** within 10 minutes is **banned** for 1 hour (configurable). Your own IP(s) are **whitelisted** (same list as `allowed_source_ips`) so you are never banned.

### Apply SSH jail

Uses the same `vars/restrict_access.yml` (so `allowed_source_ips` are whitelisted):

```bash
ansible-playbook -i inventory ssh_jail.yml
```

### Defaults (role `ssh_jail`)

- **maxretry**: 5 failed attempts → ban
- **findtime**: 10 minutes (window for counting failures)
- **bantime**: 1 hour
- **ignoreip**: `127.0.0.1/8`, `::1`, plus all `allowed_source_ips`

Override in the playbook or in `vars/restrict_access.yml` if you use the same vars for both playbooks.

### If you get banned

From another IP (or after bantime expires), SSH in and unban:

```bash
sudo fail2ban-client set sshd unbanip <BANNED_IP>
# or unban all:
sudo fail2ban-client set sshd unban --all
```

To disable fail2ban on a host: `sudo systemctl stop fail2ban && sudo systemctl disable fail2ban`.

---

## Optional: provider-level firewall

Some providers (e.g. OVH) offer a **cloud firewall** in the control panel. You can whitelist ports there instead of (or in addition to) iptables on the nodes. That way rules are applied before traffic reaches the VM.
