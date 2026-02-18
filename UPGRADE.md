# Upgrading Kubernetes Clusters (offkub / kubeadm)

This guide describes how to upgrade a Kubernetes cluster deployed with offkub. It follows the [official kubeadm upgrade procedure](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/). Use it for patch upgrades (e.g. 1.32.11 → 1.32.12) and minor upgrades (e.g. 1.32.x → 1.33.x). Other stack components (Calico, Traefik) have their own release cycles; see the references at the end.

## Important rules

- **Do not skip minor versions.** Upgrade one minor at a time (e.g. 1.32 → 1.33 → 1.34).
- **Match versions.** Keep kubeadm, kubelet, and kubectl at the same version on each node. See the [version skew policy](https://kubernetes.io/releases/version-skew-policy/).
- **Back up etcd and application state** before upgrading. `kubeadm upgrade` does not touch workloads, but backups are recommended.

## Upgrade order (official kubeadm order)

1. **Worker nodes** (one at a time or in small batches).
2. **Additional control plane nodes** (one at a time).
3. **First (primary) control plane node** last.

---

## Preparing offline assets for the new version

Before upgrading nodes, prepare packages and images for the target Kubernetes version.

1. **Choose target version.** Check [Patch Releases](https://kubernetes.io/releases/patch-releases/) for the latest patch of your target minor (e.g. 1.32.12 or 1.33.8).

2. **Get exact package versions.** On a Debian 12 machine with the Kubernetes repo enabled for the target minor:
   ```bash
   sudo apt update
   apt-cache madison kubeadm
   ```
   Use the version string shown (e.g. `1.32.12-1.1`).

3. **Update `group_vars/all.yml`:**
   - Set `kube_version` (e.g. `"1.32.12"`).
   - Set `kube_version_pkgs` (e.g. `"1.32.12-1.1"`).
   - Update `kubernetes_packages` with the exact `.deb` filenames (kubeadm, kubelet, kubectl, kubernetes-cni, cri-tools, and the utility packages).

4. **Re-fetch offline assets** on a machine with internet:
   ```bash
   sudo ./scripts/fetch_offline_assets.sh
   ```

5. **Copy** the updated `offline_pkg_dir` and `offline_image_dir` to your first master (or wherever you serve assets). If you use the asset server, replace the contents and keep the server running so nodes can pull new packages during the upgrade.

---

## Upgrading worker nodes

Perform these steps for each worker node (or a few at a time), so you do not remove too much capacity at once.

1. **Upgrade kubeadm** (packages from your offline dir or asset server). Replace `1.32.x` with your target patch (e.g. `1.32.12`):
   ```bash
   sudo apt-mark unhold kubeadm
   sudo apt-get update && sudo apt-get install -y kubeadm='1.32.x-*'
   sudo apt-mark hold kubeadm
   ```
   On fully offline nodes, install the specific `.deb` you placed in the offline dir instead of `apt-get update/install`.

2. **Run the node upgrade:**
   ```bash
   sudo kubeadm upgrade node
   ```

3. **Drain the node** (from a control plane node or wherever you have `kubectl` and admin kubeconfig):
   ```bash
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   ```

4. **Upgrade kubelet and kubectl** on the worker:
   ```bash
   sudo apt-mark unhold kubelet kubectl
   sudo apt-get update && sudo apt-get install -y kubelet='1.32.x-*' kubectl='1.32.x-*'
   sudo apt-mark hold kubelet kubectl
   ```
   On offline nodes, install the kubelet and kubectl `.deb` packages from your offline dir.

5. **Restart kubelet:**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```

6. **Uncordon the node:**
   ```bash
   kubectl uncordon <node-name>
   ```

7. **Verify:** `kubectl get nodes`. The node should show the new version and status `Ready`.

Repeat for the next worker until all workers are upgraded.

---

## Upgrading additional control plane nodes

For each **non-first** control plane node, one at a time:

1. **Upgrade kubeadm** (same as workers):
   ```bash
   sudo apt-mark unhold kubeadm
   sudo apt-get update && sudo apt-get install -y kubeadm='1.32.x-*'
   sudo apt-mark hold kubeadm
   ```

2. **Run the node upgrade** (use `kubeadm upgrade node`, **not** `kubeadm upgrade apply`):
   ```bash
   sudo kubeadm upgrade node
   ```

3. **Drain the node:**
   ```bash
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   ```

4. **Upgrade kubelet and kubectl**, then restart kubelet (same as workers):
   ```bash
   sudo apt-mark unhold kubelet kubectl
   sudo apt-get update && sudo apt-get install -y kubelet='1.32.x-*' kubectl='1.32.x-*'
   sudo apt-mark hold kubelet kubectl
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```

5. **Uncordon the node:**
   ```bash
   kubectl uncordon <node-name>
   ```

6. **Verify:** `kubectl get nodes`. Repeat for the next control plane node until only the first control plane node is left on the old version.

---

## Upgrading the first (primary) control plane node

Do this **last**, after all workers and other control plane nodes are upgraded.

1. **Upgrade kubeadm** on the first control plane node:
   ```bash
   sudo apt-mark unhold kubeadm
   sudo apt-get update && sudo apt-get install -y kubeadm='1.32.x-*'
   sudo apt-mark hold kubeadm
   ```

2. **Check the upgrade plan:**
   ```bash
   sudo kubeadm upgrade plan
   ```
   This shows the current cluster version and the version you can upgrade to.

3. **Apply the control plane upgrade** (replace with your target version, e.g. `v1.32.12`):
   ```bash
   sudo kubeadm upgrade apply v1.32.x
   ```
   Follow any prompts. When this finishes, the control plane components (API server, controller-manager, scheduler, etcd) and add-ons (CoreDNS, kube-proxy) are upgraded on this node.

4. **Drain the node:**
   ```bash
   kubectl drain <first-control-plane-node-name> --ignore-daemonsets --delete-emptydir-data
   ```

5. **Upgrade kubelet and kubectl**, then restart kubelet:
   ```bash
   sudo apt-mark unhold kubelet kubectl
   sudo apt-get update && sudo apt-get install -y kubelet='1.32.x-*' kubectl='1.32.x-*'
   sudo apt-mark hold kubelet kubectl
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```

6. **Uncordon the node:**
   ```bash
   kubectl uncordon <first-control-plane-node-name>
   ```

7. **Verify the cluster:**
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```
   All nodes should show the new version and be `Ready`; system pods (CoreDNS, Calico, etc.) should be `Running`.

---

## Changing the Kubernetes package repository (minor upgrades)

When moving to a **new minor version** (e.g. 1.32 → 1.33), the community repositories at [pkgs.k8s.io](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/change-package-repository/) use a different repo per minor. On nodes that use `apt` with internet, you must [change the package repository](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/) to the new minor before installing the new kubeadm/kubelet/kubectl. For offkub, you re-run `fetch_offline_assets.sh` with the new minor in `group_vars` (and the correct repo is used during the fetch); nodes then install from the offline packages you provide.

---

## Calico and Traefik

- **Calico:** Upgrading the CNI may require a new manifest and image versions. See [Calico upgrade](https://docs.tigera.io/calico/latest/operations/upgrade) and update `group_vars/all.yml` (`calico_version`, `calico_image_version`, etc.) and re-fetch manifests/images if you use the offline flow.
- **Traefik:** Upgrade by updating the Helm chart version and image tag in `group_vars`, re-running the fetch script to render new manifests, then applying the updated Traefik manifest. See [Traefik documentation](https://doc.traefik.io/traefik/) for version-specific notes.

---

## Recovering from a failed upgrade

If `kubeadm upgrade apply` or `kubeadm upgrade node` fails (e.g. node power loss during upgrade), you can often recover by running the same command again; kubeadm is idempotent. For a bad state, you can run:

```bash
sudo kubeadm upgrade apply --force
```

without changing the version to align the cluster state. See [Recovering from a failure state](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/#recovering-from-a-failure-state) in the official docs.
