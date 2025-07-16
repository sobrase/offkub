#!/usr/bin/env bash
set -euo pipefail

# This script targets Debian 12 hosts. Ensure we are running as root so that
# repository configuration and package downloads succeed.
if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run this script as root" >&2
  exit 1
fi

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

# Configure Kubernetes apt repository for Debian 12 based on the official
# installation instructions. Only add the repo if it's missing.
kube_minor="$(echo "$kube_version" | awk -F. '{print $1 "." $2}')"
if [[ ! -f /etc/apt/sources.list.d/kubernetes.list ]]; then
  echo "Adding Kubernetes apt repository for v${kube_minor}"
  mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${kube_minor}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${kube_minor}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
fi
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg

# Temporary directory used for apt downloads to avoid permission issues with
# the _apt sandbox user. Files are moved to $offline_pkg_dir afterwards.
download_tmp=$(mktemp -d)

# Download a .deb package and all of its dependencies
fetch_deb() {
  local file="$1"
  local name="${file%%_*}"
  local ver_arch="${file#*_}"
  local version="${ver_arch%_amd64.deb}"
  version="${version//%3a/:}"
  echo "Downloading $name=$version and dependencies"
  pushd "$download_tmp" >/dev/null
  # Avoid literal '*.deb' when there are no dependency packages
  shopt -s nullglob
  # Download package and dependencies into $download_tmp
  apt-get -y -o Dir::Cache::archives="$download_tmp" --download-only install "${name}=${version}"
  # Rename the primary package to match the file name expected by Ansible
  local main_pkg="${name}_${version}_amd64.deb"
  if [[ -f $main_pkg ]]; then
    mv "$main_pkg" "$offline_pkg_dir/$file"
  else
    # Fallback to apt-get download for the main package if needed
    apt-get -y download "${name}=${version}"
    mv "${name}_${version//:/%3a}_amd64.deb" "$offline_pkg_dir/$file"
  fi
  # Move dependencies (if any) while avoiding overwriting existing files
  for dep in *.deb; do
    [[ "$dep" == "$main_pkg" ]] && continue
    if [[ ! -f "$offline_pkg_dir/$dep" ]]; then
      mv "$dep" "$offline_pkg_dir/"
    else
      rm -f "$dep"
    fi
  done
  shopt -u nullglob
  popd >/dev/null
}

cd "$offline_pkg_dir"
for pkg in "${kubernetes_packages[@]}" "${registry_packages[@]}" "$containerd_pkg_file"; do
  # kubernetes-cni and cri-tools are fetched automatically as dependencies
  # of other Kubernetes packages, so skip explicitly downloading them here
  if [[ $pkg == kubernetes-cni_* || $pkg == cri-tools_* ]]; then
    continue
  fi
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
