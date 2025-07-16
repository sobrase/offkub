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

The registry image version can be customized via the `registry_version`
variable in `group_vars/all.yml`. Ensure the matching tarball is available
under `offline_image_dir` before running the playbook.
