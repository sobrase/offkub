# offkub

Utility scripts for preparing an offline Kubernetes deployment.

Use `scripts/fetch_offline_assets.sh` on a machine with internet access to
retrieve required packages, images and manifests. Copy the resulting
`offline_pkg_dir` and `offline_image_dir` directories to your air-gapped
environment before running the Ansible playbook.
