# cunofs-csi-driver role

This role deploys the cunoFS CSI driver in an air‑gapped Kubernetes cluster.
All manifests are templated locally and applied with `kubectl` so no
internet access is required once the assets have been fetched.
The chart and container images are downloaded by
`scripts/fetch_offline_assets.sh` and reference the private registry.

Set `cunofs_license_key` to provide your license string. A Kubernetes Secret
named `cunofs-license` is created and the `CUNOFS_LICENSE` environment
variable for the controller and node pods references this secret so the driver
starts correctly. The driver will be installed into the namespace defined by
`cunofs_namespace` (default `cunofs-system`). Image names can be adjusted in
`defaults/main.yml`.
