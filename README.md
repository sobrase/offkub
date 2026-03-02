# offkub

Utility scripts for preparing an offline Kubernetes deployment. See [UPGRADE.md](UPGRADE.md) for how to upgrade an existing cluster.

### Deploy (full flow)

1. **Fetch offline assets** (once, on a machine with internet; requires root):
   ```bash
   sudo ./scripts/fetch_offline_assets.sh
   ```
   This populates `/opt/offline/pkgs` and `/opt/offline/images`.

2. **Deploy from your laptop** (SSH to all nodes must work, e.g. via `sshm` / `~/.ssh/config`):
   ```bash
   # Optional: use a venv for Ansible
   python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

   # Sync assets to first master and run the playbook
   ./scripts/deploy.sh
   ```
   If assets are already on the first master at `/opt/offline`, use:
   ```bash
   ./scripts/deploy.sh --assets-on-master
   ```

The deploy script syncs `/opt/offline` to the first master, starts the asset server there, then runs the Ansible playbook. All nodes pull packages and images from that HTTP server.

### Inventory (sshm hosts)

The `inventory` file lists your nodes: the first three hosts under `[masters]`
and the next two under `[workers]` (3 masters, 2 workers). Use full hostnames
from your SSH config (`HostName`) so the same host is used everywhere. To refresh
from SSH config: `./scripts/sshm-inventory.sh`. You can set `registry_master_ip`
in `group_vars/all.yml` to override the first master IP; leave it empty to use
the first master’s IP from inventory.

### Docker registry (first master, all nodes use it)

The playbook deploys a **Docker registry** on the **first master** (role `setup_registry`, run once):

- **Registry**: `registry:2` container on port **5000**; reachable as `registry.local:5000`.
- **First master**: Docker is installed there; the registry runs as a container; all offline images (Kubernetes, Calico, Traefik, CSI, etc.) are pushed to it.
- **All nodes**: `prepare_system` adds `registry.local` → first master IP in `/etc/hosts` on every node. **containerd** (role `install_k8s`) is configured with a mirror so `registry.local:5000` is used for image pulls. kubeadm and all workloads pull from this registry.
- **Registry data** is stored under `registry_data_path` (default `/srv/registry`). A **daily cron job** runs garbage-collection to remove unused blobs and limit disk use. If you later add a separate disk so a full registry cannot fill root, set `registry_data_device` in `group_vars/all.yml` (e.g. `"/dev/sdb1"`), format it, then run with `--tags registry_apply` to have the role mount it at `registry_data_path`.
- **Garbage collection**: a daily cron job (3:00) runs `registry garbage-collect` to remove unused blobs. Ensure the registry config has `storage.delete.enabled: true` (the role deploys this).

No extra step is required: a full deploy (`site.yml` or `./scripts/deploy.sh`) installs the registry on the first master and points all nodes to it.

### Restricting access (firewall)

If your nodes are on the public internet, you can whitelist all ports except SSH (22): SSH stays open to anyone; all other ports are allowed only from your IP(s) and cluster nodes. See [SECURITY.md](SECURITY.md) for details. In short:

1. Edit `vars/restrict_access.yml`: set `restrict_access_enabled: true` and `allowed_source_ips: ["YOUR_IP/32"]` (get your IP with `curl -s ifconfig.me`).
2. Run the firewall playbook: `ansible-playbook -i inventory restrict_access.yml`. The main deploy playbook (`site.yml`) does **not** run the firewall.

### Nodes NotReady and NFS storage test

If nodes stay **NotReady** after workers join, the playbook’s `post_install_checks` role fixes this by:
setting the Calico API endpoint, disabling eBPF (Felix iptables mode), restarting Calico pods, then **waiting for all nodes to become Ready** (up to ~5 minutes). The NVIDIA device plugin is only applied when the `[gpu]` group has hosts.

After a full deploy, the **NFS StorageClass** is tested automatically: a PVC using `nfs-csi` is created, a pod mounts it and writes/reads a file, then the test namespace is removed. To re-run only post-install and the NFS test (cluster and NFS already deployed):

```bash
./scripts/run-post-install-and-nfs-test.sh
```

### First master restored (etcd out of sync)

If you restored **VPS1** (first master) to a previous snapshot, its etcd data will not match the other control-plane nodes and **etcd will not start** on VPS1. Rejoin VPS1 to the cluster so it gets a fresh etcd member:

1. Ensure at least one other master (e.g. the second in your inventory) is healthy and the API is reachable.
2. Run:

   ```bash
   .venv/bin/ansible-playbook -i inventory rejoin_first_master.yml
   ```

   This copies a working `admin.conf` from the second master to VPS1, runs `kubeadm reset phase remove-etcd-member` on VPS1 (to remove its stale etcd member from the cluster), does a full `kubeadm reset` on VPS1, then generates a new control-plane join command from the second master and runs `kubeadm join --control-plane` on VPS1. After that, all three masters and workers should be Ready.

### Verification at each stage

Run these scripts from the repo root to confirm each phase before continuing:

| After | Script |
|-------|--------|
| (before any deploy) | `./scripts/verify-preflight.sh` |
| prepare_system | `./scripts/verify-after-prepare_system.sh` |
| install_k8s | `./scripts/verify-after-install_k8s.sh` |
| setup_registry | `./scripts/verify-after-setup_registry.sh` |
| kubeadm_master | `./scripts/verify-after-kubeadm_master.sh` |
| kubeadm_workers | `./scripts/verify-after-kubeadm_workers.sh` |
| Full playbook | `./scripts/verify-after-deploy.sh` |

Or run a single stage: `./scripts/verify-all-stages.sh <stage>` with stage one of
`preflight`, `prepare_system`, `install_k8s`, `setup_registry`, `kubeadm_master`,
`kubeadm_workers`, `deploy`. Use `./scripts/verify-all-stages.sh all` to run every
verification (after the full playbook).

### SSH and logs on nodes

Use the same SSH config as `sshm`. Helpers:

- **`./scripts/ssh-node.sh <node>`** – SSH into a node by inventory name (e.g. `vps-2`, `first-master`).
- **`./scripts/node-logs.sh <node> kubelet`** – Stream kubelet logs on that node.
- **`./scripts/node-logs.sh <node> containerd`** – Stream containerd logs on that node.
- **`./scripts/node-logs.sh first-master kubectl`** – List pods (from first master). Use `kubectl <ns/pod>` for a specific pod’s logs.

During initialization the first master node now writes two join command
scripts: `/tmp/join.sh` for workers and `/tmp/join-master.sh` for additional
control plane nodes. Subsequent masters read the latter file to join the
cluster with `kubeadm join --control-plane`, while worker nodes continue to use
`/tmp/join.sh`.

For multi-master setups, the playbook relies on the `control_plane_endpoint`
variable defined in `group_vars/all.yml`. This value should point to a stable
address (IP or DNS name) that resolves to the Kubernetes API server. Additional
control plane nodes reference this endpoint when joining the cluster.

The registry image version can be customized via the `registry_version`
variable in `group_vars/all.yml`. Ensure the matching tarball is available
under `offline_image_dir` before running the playbook.

The `prepare_system` role configures kernel parameters required for Kubernetes.
It disables swap, loads the `overlay` and `br_netfilter` modules, and enables
IPv4 forwarding via `/etc/sysctl.d/k8s.conf`. These settings ensure that
`kubeadm` passes preflight checks in fully air‑gapped deployments.

Calico's manifest is applied in two phases. The playbook first installs its
CustomResourceDefinitions and waits until the `FelixConfiguration` CRD becomes
available before applying the rest of the resources. This avoids failures that
can occur when the API server has not yet processed the CRDs during the initial
apply. After the manifest is applied, the playbook ensures all Calico pods
reach the `Running` phase. If they remain pending, the kubelet service is
restarted on every node and the readiness check is retried.


The `traefik_gateway` role deploys a Traefik Gateway controller and related
Gateway API resources using a manifest rendered from the official Helm chart.
Traefik runs as a DaemonSet so every node exposes ports 80 and 443. The
rendered manifest references container images in the local registry so the
gateway can be installed entirely offline. During deployment the role creates a
self-signed certificate and stores it in a `traefik-cert` Secret so the HTTPS
listener is enabled without external dependencies.

The `sample_app` role provides a minimal Deployment, Service and HTTPRoute that
use only local manifests and images. It allows quick end‑to‑end testing of the
cluster once the gateway is running.

`scripts/fetch_offline_assets.sh` now also saves the `traefik/whoami` image
used by the optional test route so the gateway can serve traffic without
external access. The script additionally pulls the `calico/typha`,
`calico/csi` and `calico/node-driver-registrar` images so Calico components
start successfully in fully offline environments.

`scripts/fetch_offline_assets.sh` also retrieves the NVIDIA GPU driver runfile
specified by `nvidia_driver_runfile` and the `nvidia_packages`. These files are
placed under `offline_pkg_dir` so the `install_gpu` role can install GPU
support entirely from the local asset server.


## Troubleshooting 404 errors when testing Traefik
If navigating to `http://<NODE_IP>` returns a 404 page after running the playbook,
Traefik is reachable but no `HTTPRoute` matched the request. Verify that the
`traefik-gateway` resource exists and that the sample route is accepted:

```bash
kubectl get gateways,httproutes -A
kubectl describe gateway traefik-gateway -n default
kubectl describe httproute echo-app -n default
```

The route status should list `Accepted=True` and reference the gateway under
`Parents`. If the route is not accepted, inspect the controller logs:

```bash
kubectl logs -n traefik-system daemonset/traefik
```
If this command prints no output, the controller may be running with a higher
log level that hides informational messages. The provided manifest starts
Traefik with `--log.level=info` and `--accesslog` so startup events are
visible even without traffic. Reapply the controller manifest if you updated
an earlier version.

If `kubectl describe gateway traefik-gateway -n default` shows `Waiting for controller`
or `Reason: Pending`, the Gateway has not been reconciled yet. Confirm that the
Traefik controller is running and the `traefik` GatewayClass exists:

```bash
kubectl get gatewayclasses
kubectl get pods -n traefik-system
```

A healthy daemonset and `Accepted=True` GatewayClass mean the controller is ready
to program the Gateway and associated routes.
Once reconciled, `kubectl describe gateway traefik-gateway -n default` lists the assigned `Address`.
If the controller logs contain RBAC errors such as `configmaps is forbidden` or
`endpointslices.discovery.k8s.io is forbidden`, edit the Traefik ClusterRole to
allow listing these resources.

A missing GatewayClass or incorrect `parentRefs` will prevent Traefik from using
the route. Once the route is accepted, the sample page should load from any
node's IP address.

