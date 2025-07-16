#!/usr/bin/env bash
set -euo pipefail

# This script downloads Debian packages and container images needed for
# offline deployment. It must be run on a machine with internet access
# and Docker/apt utilities installed.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VARS_FILE="$ROOT_DIR/group_vars/all.yml"

# Ensure PyYAML is available for parsing YAML
if ! python3 - <<'PY'
import yaml
PY
then
  echo "Installing PyYAML for YAML parsing" >&2
  pip3 install --user PyYAML >/dev/null
fi

read -r offline_pkg_dir offline_image_dir kube_version kube_version_pkgs \
        containerd_version calico_version calico_image_version \
        device_plugin_version <<< "$(python3 - <<PY
import yaml,sys
with open('$VARS_FILE') as f:
    data = yaml.safe_load(f)
fields = ['offline_pkg_dir','offline_image_dir','kube_version',
          'kube_version_pkgs','containerd_version','calico_version',
          'calico_image_version','device_plugin_version']
print(' '.join(str(data.get(k,'')) for k in fields))
PY
)"

kubernetes_packages=( $(python3 - <<PY
import yaml
with open('$VARS_FILE') as f:
    data = yaml.safe_load(f)
print(' '.join(data.get('kubernetes_packages', [])))
PY
) )

registry_packages=( $(python3 - <<PY
import yaml
with open('$VARS_FILE') as f:
    data = yaml.safe_load(f)
print(' '.join(data.get('registry_docker_packages', [])))
PY
) )

containerd_pkg_file="containerd.io_${containerd_version}-1_amd64.deb"

mkdir -p "$offline_pkg_dir" "$offline_image_dir"

# Temporary directory used for apt downloads to avoid permission issues with
# the _apt sandbox user. Files are moved to $offline_pkg_dir afterwards.
download_tmp=$(mktemp -d)

# Function to download a deb by name/version using apt-get download
fetch_deb() {
  local file="$1"
  local name="${file%%_*}"
  local ver_arch="${file#*_}"
  local version="${ver_arch%_amd64.deb}"
  version="${version//%3a/:}"
  echo "Downloading $name=$version"
  pushd "$download_tmp" >/dev/null
  apt-get -y download "$name=$version"
  local dl_file="${name}_${version//:/%3a}_amd64.deb"
  if [[ ! -f $dl_file ]]; then
    dl_file=$(ls ${name}_*_amd64.deb | head -n1)
  fi
  mv "$dl_file" "$offline_pkg_dir/$file"
  popd >/dev/null
}

cd "$offline_pkg_dir"
for pkg in "${kubernetes_packages[@]}" "${registry_packages[@]}" "$containerd_pkg_file"; do
  fetch_deb "$pkg"
done

cd "$offline_image_dir"

# Registry image
docker pull registry:2.8.2
docker save registry:2.8.2 -o registry_2.8.2.tar

# Kubernetes control plane images
if command -v kubeadm >/dev/null; then
  mapfile -t k8s_images < <(kubeadm config images list --kubernetes-version "v${kube_version}")
else
  k8s_images=(
    "registry.k8s.io/kube-apiserver:v${kube_version}"
    "registry.k8s.io/kube-controller-manager:v${kube_version}"
    "registry.k8s.io/kube-scheduler:v${kube_version}"
    "registry.k8s.io/kube-proxy:v${kube_version}"
    "registry.k8s.io/etcd:3.5.9-0"
    "registry.k8s.io/coredns/coredns:v1.10.1"
    "registry.k8s.io/pause:3.9"
  )
fi

for img in "${k8s_images[@]}"; do
  base="$(basename "$img")"
  file="${base/:/_}.tar"
  docker pull "$img"
  docker save "$img" -o "$file"
  echo "Saved $img to $file"
done

# Calico images
calico_images=(
  "docker.io/calico/cni:${calico_image_version}"
  "docker.io/calico/node:${calico_image_version}"
  "docker.io/calico/kube-controllers:${calico_image_version}"
)
for img in "${calico_images[@]}"; do
  base="$(basename "$img")"
  file="${base/:/_}.tar"
  docker pull "$img"
  docker save "$img" -o "$file"
  echo "Saved $img to $file"
done

# NVIDIA device plugin image
docker pull nvcr.io/nvidia/k8s-device-plugin:${device_plugin_version}
docker save nvcr.io/nvidia/k8s-device-plugin:${device_plugin_version} \
  -o nvidia-device-plugin_${device_plugin_version}.tar

# Calico manifest
curl -L \
  -o calico.yaml \
  "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/calico.yaml"

# Cleanup temporary download directory
rm -rf "$download_tmp"

echo "All assets saved under $offline_pkg_dir and $offline_image_dir"
