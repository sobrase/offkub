# cunofs-csi-driver role

This role deploys the cunofs CSI driver in an air-gapped Kubernetes cluster.
All manifests are stored under `files/` and reference images from the local registry.
Adjust `cunofs_controller_image` and `cunofs_node_image` in `defaults/main.yml`
to match your environment.
