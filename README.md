# offkub

Utility scripts for preparing an offline Kubernetes deployment.

Use `scripts/fetch_offline_assets.sh` on a machine with internet access to
retrieve required packages, their dependencies, images and manifests. Copy the resulting
`offline_pkg_dir` and `offline_image_dir` directories to your air-gapped
environment. On the master node, start the lightweight HTTP service
with `scripts/serve_assets.py` to expose these directories to the other
hosts:

```bash
python3 scripts/serve_assets.py -d /opt/offline -p 8080
```

Once the service is running, execute the Ansible playbook. All nodes
will pull packages and images from this local HTTP server.

During initialization the first master node now writes two join command
scripts: `/tmp/join.sh` for workers and `/tmp/join-master.sh` for additional
control plane nodes. Subsequent masters read the latter file to join the
cluster with `kubeadm join --control-plane`, while worker nodes continue to use
`/tmp/join.sh`.

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
apply.


The `traefik_gateway` role deploys a Traefik Gateway controller and related
Gateway API resources. All manifests use container images from the local
registry so the gateway can be installed entirely offline.

`scripts/fetch_offline_assets.sh` also downloads the cunoFS CSI Helm chart and
its container images. The chart is extracted under
`roles/cunofs-csi-driver/files/chart` and the tarred images are saved in
`offline_image_dir` alongside the other archives.
Image references inside the chart are rewritten to use the
`registry_host`/`registry_port` settings so the manifests can be applied
fully offline.

Provide the cunoFS license key via the `cunofs_license_key` variable to
generate a `cunofs-license` Secret during deployment. The driver manifests
will be installed into the namespace specified by `cunofs_namespace`.

