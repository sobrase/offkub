# offkub

Utility scripts for preparing an offline Kubernetes deployment.

Use `scripts/fetch_offline_assets.sh` on a machine with internet access to
retrieve required packages, their dependencies, images and manifests. The
script installs the Helm CLI automatically if it is missing. Copy the resulting
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
Gateway API resources. Traefik runs as a DaemonSet so every node exposes ports
80 and 443. All manifests use container images from the local registry so the
gateway can be installed entirely offline.

The `sample_app` role provides a minimal Deployment, Service and HTTPRoute that
use only local manifests and images. It allows quick end‑to‑end testing of the
cluster once the gateway is running.

`scripts/fetch_offline_assets.sh` now also saves the `traefik/whoami` image
used by the optional test route so the gateway can serve traffic without
external access.

`scripts/fetch_offline_assets.sh` also downloads the cunoFS CSI Helm chart and
its container images. The chart is extracted under
`roles/cunofs-csi-driver/files/chart` and the tarred images are saved in
`offline_image_dir` alongside the other archives.
Image references inside the chart are rewritten to use the
`registry_host`/`registry_port` settings so the manifests can be applied
fully offline.
The script extracts the driver version from the Helm chart and pulls
`cunofs/cunofs-csi:<version>` accordingly. The version is stored in the
`cunofs_version` variable used by Ansible to load the tarball named
`cunofs-csi_<version>.tar`.
The `setup_registry` role loads these cunoFS image tarballs and pushes the
images to the local registry so the driver can start without external access.
The Helm version used for fetching can be customised via the
`helm_version` variable in `group_vars/all.yml`.

Fetching the cunoFS images requires credentials for the private Docker
repository. Run `docker login registry-1.docker.io` before executing the
script or set `SKIP_CUNOFS=1` to skip downloading the cunoFS assets.

Provide the cunoFS license key via the `cunofs_license_key` variable to
generate a `cunofs-license` Secret during deployment. The driver manifests
will be installed into the namespace specified by `cunofs_namespace`.

After Traefik is set up, the playbook automatically runs the
`cunofs-csi-driver` role to deploy the cunoFS CSI driver from the locally
extracted Helm chart. This step requires no internet access and completes the
offline Kubernetes installation.

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

A missing GatewayClass or incorrect `parentRefs` will prevent Traefik from using
the route. Once the route is accepted, the sample page should load from any
node's IP address.

