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
        registry_version containerd_version calico_version calico_image_version \
        device_plugin_version traefik_version helm_version registry_host registry_port <<< "$(python3 - <<PY
import yaml,sys
with open('$VARS_FILE') as f:
    data = yaml.safe_load(f)
fields = ['offline_pkg_dir','offline_image_dir','kube_version',
          'kube_version_pkgs','registry_version','containerd_version','calico_version',
          'calico_image_version','device_plugin_version','traefik_version',
          'helm_version','registry_host','registry_port']
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

# cunoFS CSI Helm chart and images
chart_dir="$ROOT_DIR/roles/cunofs-csi-driver/files/chart"
mkdir -p "$chart_dir"
helm pull --untar oci://registry-1.docker.io/cunofs/cunofs-csi-chart -d "$chart_dir"

# Rewrite image references in the fetched cunoFS manifests to use the
# local registry. This keeps the deployment fully offline.
find "$chart_dir" -type f -name '*.yaml' -print0 \
  | xargs -0 sed -i "s#docker.io/cunofs#${registry_host}:${registry_port}/cunofs#g"

cunofs_images=(
  "docker.io/cunofs/csi-controller:latest"
  "docker.io/cunofs/csi-node:latest"
)
for img in "${cunofs_images[@]}"; do
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

# Traefik Gateway controller manifest
cat > "$gateway_files_dir/traefik-controller.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-controller
  namespace: traefik
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: traefik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik-lb
  template:
    metadata:
      labels:
        app: traefik-lb
    spec:
      serviceAccountName: traefik-controller
      containers:
        - name: traefik
          image: ${registry_host}:${registry_port}/traefik:v${traefik_version}
          args:
            - --entryPoints.web.address=:80
            - --entryPoints.websecure.address=:443
            - --experimental.kubernetesgateway
            - --providers.kubernetesgateway
          ports:
            - name: web
              containerPort: 80
            - name: websecure
              containerPort: 443
---
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: traefik
spec:
  type: LoadBalancer
  selector:
    app: traefik-lb
  ports:
    - protocol: TCP
      port: 80
      targetPort: web
      name: web
    - protocol: TCP
      port: 443
      targetPort: websecure
# Last line of controller manifest
      name: websecure
EOF

# GatewayClass and Gateway definitions
cat > "$gateway_files_dir/gatewayclass.yaml" <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik-gw-class
spec:
  controllerName: traefik.io/gateway-controller
EOF

cat > "$gateway_files_dir/gateway.yaml" <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: traefik-gateway
  namespace: traefik
spec:
  gatewayClassName: traefik-gw-class
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
        - kind: Secret
          name: traefik-cert
    allowedRoutes:
      namespaces:
        from: All
EOF
# Cleanup temporary download directory
rm -rf "$download_tmp"

echo "All assets saved under $offline_pkg_dir and $offline_image_dir"
