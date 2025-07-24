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
if ! python3 - <<'PY' 2>/dev/null
import yaml
PY
then
  echo "Installing PyYAML for YAML parsing" >&2
  pip3 install --user PyYAML >/dev/null
fi

# Ensure Jinja2 is available for templating variables inside the YAML file
if ! python3 - <<'PY' 2>/dev/null
import jinja2
PY
then
  echo "Installing Jinja2 for templating" >&2
  pip3 install --user Jinja2 >/dev/null
fi

read -r offline_pkg_dir offline_image_dir kube_version kube_version_pkgs \
        registry_version containerd_version calico_version calico_image_version \
        tigera_operator_version device_plugin_version traefik_version whoami_version traefik_chart_version traefik_crds_chart_version helm_version registry_host registry_port nvidia_driver_runfile csi_provisioner_version csi_resizer_version csi_snapshotter_version livenessprobe_version csi_node_driver_registrar_version snapshot_controller_version <<< "$(python3 - <<PY

import yaml
from jinja2 import Template
text=open('$VARS_FILE').read()
data=yaml.safe_load(text)
rendered=Template(text).render(**data)
data=yaml.safe_load(rendered)
fields=['offline_pkg_dir','offline_image_dir','kube_version','kube_version_pkgs',
        'registry_version','containerd_version','calico_version','calico_image_version',
        'tigera_operator_version','device_plugin_version','traefik_version','whoami_version','traefik_chart_version',
        'traefik_crds_chart_version','helm_version','registry_host','registry_port','nvidia_driver_runfile',
        'csi_provisioner_version','csi_resizer_version','csi_snapshotter_version','livenessprobe_version','csi_node_driver_registrar_version','snapshot_controller_version']
print(' '.join(str(data.get(k,'')) for k in fields))
PY
)"

kubernetes_packages=( $(python3 - <<PY
import yaml
from jinja2 import Template
text=open('$VARS_FILE').read()
data=yaml.safe_load(text)
rendered=Template(text).render(**data)
data=yaml.safe_load(rendered)
print(' '.join(data.get('kubernetes_packages', [])))
PY
) )

registry_packages=( $(python3 - <<PY
import yaml
from jinja2 import Template
text=open('$VARS_FILE').read()
data=yaml.safe_load(text)
rendered=Template(text).render(**data)
data=yaml.safe_load(rendered)
print(' '.join(data.get('registry_docker_packages', [])))
PY
) )

nvidia_packages=( $(python3 - <<PY

import yaml
from jinja2 import Template
text=open('$VARS_FILE').read()
data=yaml.safe_load(text)
rendered=Template(text).render(**data)
data=yaml.safe_load(rendered)
print(' '.join(data.get('nvidia_packages', [])))
PY
) )

containerd_pkg_file="containerd.io_${containerd_version}-1_amd64.deb"

# Storage related images
storage_images=(
  "gcr.io/k8s-staging-sig-storage/nfsplugin:canary"
  "registry.k8s.io/sig-storage/csi-provisioner:${csi_provisioner_version}"
  "registry.k8s.io/sig-storage/csi-resizer:${csi_resizer_version}"
  "registry.k8s.io/sig-storage/csi-snapshotter:${csi_snapshotter_version}"
  "registry.k8s.io/sig-storage/livenessprobe:${livenessprobe_version}"
  "registry.k8s.io/sig-storage/csi-node-driver-registrar:${csi_node_driver_registrar_version}"
  "registry.k8s.io/sig-storage/snapshot-controller:${snapshot_controller_version}"
)

mkdir -p "$offline_pkg_dir" "$offline_image_dir"
gateway_files_dir="$ROOT_DIR/roles/traefik_gateway/files"
mkdir -p "$gateway_files_dir"

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

# Configure Docker apt repository for Debian 12 following the official
# installation instructions. Only add the repository if it's missing.
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  echo "Adding Docker apt repository"
  mkdir -p -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
    > /etc/apt/sources.list.d/docker.list
fi

apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg

# Install Helm if it's missing
if ! command -v helm >/dev/null; then
  echo "Installing Helm ${helm_version}" >&2
  tmp_h=$(mktemp -d)
  curl -fsSL "https://get.helm.sh/helm-${helm_version}-linux-amd64.tar.gz" -o "$tmp_h/helm.tar.gz"
  tar -xzf "$tmp_h/helm.tar.gz" -C "$tmp_h"
  install -m 0755 "$tmp_h/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$tmp_h"
fi

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

# Download NVIDIA container toolkit packages directly from the official repository
for pkg in "${nvidia_packages[@]}"; do
  url="https://raw.githubusercontent.com/NVIDIA/libnvidia-container/gh-pages/stable/deb/amd64/${pkg}"
  echo "Fetching $pkg"
  curl -L -o "$offline_pkg_dir/$pkg" "$url"
done

# Download NVIDIA driver runfile
driver_version="${nvidia_driver_runfile#NVIDIA-Linux-x86_64-}"
driver_version="${driver_version%.run}"
curl -L \
  -o "$offline_pkg_dir/$nvidia_driver_runfile" \
  "https://download.nvidia.com/XFree86/Linux-x86_64/${driver_version}/${nvidia_driver_runfile}"

cd "$offline_image_dir"

# Registry image
docker pull registry:${registry_version}
docker save registry:${registry_version} -o "registry_${registry_version}.tar"

# Kubernetes control plane images
if command -v kubeadm >/dev/null; then
  mapfile -t k8s_images < <(kubeadm config images list --kubernetes-version "v${kube_version}")
else
  k8s_images=(
    "registry.k8s.io/kube-apiserver:v${kube_version}"
    "registry.k8s.io/kube-controller-manager:v${kube_version}"
    "registry.k8s.io/kube-scheduler:v${kube_version}"
    "registry.k8s.io/kube-proxy:v${kube_version}"
    "registry.k8s.io/etcd:3.5.16-0"
    "registry.k8s.io/coredns/coredns:v1.11.3"
    "registry.k8s.io/pause:3.10"
  )
fi

for img in "${k8s_images[@]}"; do
  base="$(basename "$img")"
  file="${base/:/_}.tar"
  docker pull "$img"
  docker save "$img" -o "$file"
  echo "Saved $img to $file"
done

# Traefik image
docker pull traefik:v${traefik_version}
docker save traefik:v${traefik_version} -o "traefik_v${traefik_version}.tar"

# Traefik whoami image used by the optional test route
docker pull traefik/whoami:${whoami_version}
docker save traefik/whoami:${whoami_version} -o "whoami_${whoami_version}.tar"

# Python image for the sample application
docker pull python:3.12-alpine
docker save python:3.12-alpine -o python_3.12-alpine.tar

# Calico images
calico_images=(
  "quay.io/tigera/operator:${tigera_operator_version}"
  "docker.io/calico/node:${calico_image_version}"
  "docker.io/calico/cni:${calico_image_version}"
  "docker.io/calico/apiserver:${calico_image_version}"
  "docker.io/calico/kube-controllers:${calico_image_version}"
  "docker.io/calico/envoy-gateway:${calico_image_version}"
  "docker.io/calico/envoy-proxy:${calico_image_version}"
  "docker.io/calico/envoy-ratelimit:${calico_image_version}"
  "docker.io/calico/dikastes:${calico_image_version}"
  "docker.io/calico/pod2daemon-flexvol:${calico_image_version}"
  "docker.io/calico/key-cert-provisioner:${calico_image_version}"
  "docker.io/calico/goldmane:${calico_image_version}"
  "docker.io/calico/whisker:${calico_image_version}"
  "docker.io/calico/whisker-backend:${calico_image_version}"
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

# CSI and NFS images
for img in "${storage_images[@]}"; do
  base="$(basename "$img")"
  file="${base/:/_}.tar"
  docker pull "$img"
  docker save "$img" -o "$file"
  echo "Saved $img to $file"
done


# Calico manifest
curl -L \
  -o calico.yaml \
  "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/calico.yaml"

# Enable eBPF mode and host networking by default
cat <<'EOF' >> calico.yaml

---
apiVersion: crd.projectcalico.org/v1
kind: FelixConfiguration
metadata:
  name: default
spec:
  bpfEnabled: true
EOF

# Ensure networking environment variables match our defaults
sed -i '/name: CLUSTER_TYPE/{n;s/.*/              value: "k8s,bgp"/}' calico.yaml
sed -i '/name: CALICO_IPV4POOL_IPIP/{n;s/.*/              value: "Never"/}' calico.yaml
sed -i '/name: CALICO_IPV4POOL_VXLAN/{n;s/.*/              value: "Never"/}' calico.yaml

# Gateway API CRDs
curl -L -o "$gateway_files_dir/standard-install.yaml" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
curl -L -o "$gateway_files_dir/experimental-install.yaml" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml"

# Render Traefik chart using helm template
cat > "$gateway_files_dir/values.yaml" <<EOF
providers:
  kubernetesIngress:
    enabled: false
  kubernetesGateway:
    enabled: true
gateway:
  namespacePolicy: All
deployment:
  kind: DaemonSet
hostNetwork: true
service:
  enabled: false
image:
  registry: ${registry_host}:${registry_port}
  repository: traefik
  tag: v${traefik_version}
updateStrategy:
  rollingUpdate:
    maxUnavailable: 1
EOF

tmp_chart=$(mktemp -d)
helm repo add traefik https://traefik.github.io/charts >/dev/null
helm repo update >/dev/null
helm pull traefik/traefik --version ${traefik_chart_version} -d "$tmp_chart" --untar
tmp_chart_crds=$(mktemp -d)
helm pull traefik/traefik-crds --version ${traefik_crds_chart_version} -d "$tmp_chart_crds" --untar
chart_path="$tmp_chart/traefik"
helm template traefik "$chart_path" \
  --namespace traefik \
  --create-namespace \
  -f "$gateway_files_dir/values.yaml" \
  > "$gateway_files_dir/traefik.yaml"

# Concatenate Traefik CRDs into a single file
crds_dir="$tmp_chart_crds/traefik-crds/crds-files/traefik"
awk 'FNR==1 && NR>1{print "---"} {print}' "$crds_dir"/*.yaml > "$gateway_files_dir/traefik-crds.yaml"

# Remove maxSurge which is invalid for DaemonSet updateStrategy
sed -i '/maxSurge:/d' "$gateway_files_dir/traefik.yaml"
# Grant capability to bind privileged ports
sed -i '/drop:/a\            add:\n            - NET_BIND_SERVICE' "$gateway_files_dir/traefik.yaml"

# Include RBAC permissions for listing nodes when Traefik runs as a DaemonSet
awk '
/resources:/ && /nodes/ { inserted=1 }
/^- apiGroups:/ && $2 ~ /discovery.k8s.io/ && !inserted {
  print "  - apiGroups:";
  print "      - \"\"";
  print "    resources:";
  print "      - nodes";
  print "    verbs:";
  print "      - get";
  print "      - list";
  print "      - watch";
  inserted=1
}
{ print }' "$gateway_files_dir/traefik.yaml" > "$gateway_files_dir/traefik.yaml.tmp"
mv "$gateway_files_dir/traefik.yaml.tmp" "$gateway_files_dir/traefik.yaml"
rm -rf "$tmp_chart" "$tmp_chart_crds"
# Cleanup temporary download directory
rm -rf "$download_tmp"

echo "All assets saved under $offline_pkg_dir and $offline_image_dir"
