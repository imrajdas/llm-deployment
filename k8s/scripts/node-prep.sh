# Shared host prep for the Azure control plane and the JarvisLabs GPU worker.
# Source this file from a root shell. Do not execute it directly.

K8S_MINOR="${K8S_MINOR:-v1.37}"
FLANNEL_MANIFEST="${FLANNEL_MANIFEST:-https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml}"
LOCAL_PATH_MANIFEST="${LOCAL_PATH_MANIFEST:-https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml}"
NVIDIA_DEVICE_PLUGIN_MANIFEST="${NVIDIA_DEVICE_PLUGIN_MANIFEST:-https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.20.0/deployments/static/nvidia-device-plugin.yml}"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this script as root: sudo bash $0" >&2
    exit 1
  fi
}

prepare_os() {
  swapoff -a || true
  if [[ -f /etc/fstab ]]; then
    sed -i.bak '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
  fi

  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null
}

install_containerd() {
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gpg containerd conntrack socat
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd
  systemctl restart containerd
}

install_kubeadm() {
  install -d -m 0755 /etc/apt/keyrings
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt-get update
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet
}

cluster_node_ip() {
  if [[ -n "${CLUSTER_NODE_IP:-}" ]]; then
    printf '%s\n' "$CLUSTER_NODE_IP"
    return 0
  fi
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "Set CLUSTER_NODE_IP, or install Tailscale and run: sudo tailscale up" >&2
    return 1
  fi
  local ip
  ip="$(tailscale ip -4 | head -n 1)"
  if [[ -z "$ip" ]]; then
    echo "Tailscale has no IPv4 address yet. Finish login with: sudo tailscale up" >&2
    return 1
  fi
  printf '%s\n' "$ip"
}

cluster_iface() {
  if [[ -n "${CLUSTER_IFACE:-}" ]]; then
    printf '%s\n' "$CLUSTER_IFACE"
    return 0
  fi
  if [[ -n "${CLUSTER_NODE_IP:-}" ]]; then
    printf '%s\n' wg0
    return 0
  fi
  printf '%s\n' tailscale0
}

write_kubelet_args() {
  local node_ip="$1"
  shift
  local extra=("$@")
  local joined="${extra[*]:-}"
  if [[ -n "$joined" ]]; then
    echo "KUBELET_EXTRA_ARGS=--node-ip=${node_ip} ${joined}" >/etc/default/kubelet
  else
    echo "KUBELET_EXTRA_ARGS=--node-ip=${node_ip}" >/etc/default/kubelet
  fi
  systemctl daemon-reload
}
