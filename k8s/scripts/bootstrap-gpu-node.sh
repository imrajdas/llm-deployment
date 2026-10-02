#!/usr/bin/env bash
# Join this JarvisLabs GPU VM to the Azure kubeadm control plane.
# The laptop script uploads /home/llm-deployment/join.env before calling this.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/k8s/scripts/node-prep.sh"
require_root

JOIN_ENV="${JOIN_ENV:-$ROOT/join.env}"
if [[ ! -f "$JOIN_ENV" ]]; then
  found="$(find /home/llm-deployment /tmp -name join.env -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    JOIN_ENV="$found"
  fi
fi
if [[ -f "$JOIN_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$JOIN_ENV"
  trap 'rm -f "$JOIN_ENV"' EXIT
fi

install_nvidia_runtime() {
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi failed. JarvisLabs GPU VMs should already have the driver." >&2
    exit 1
  fi
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      >/etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
  fi
  # Default runtime on this worker only, so the device plugin can see the GPU.
  nvidia-ctk runtime configure --runtime=containerd --set-as-default
  systemctl restart containerd
}

ensure_cluster_mesh jarvis-gpu
NODE_IP="$(cluster_node_ip)"
echo "GPU node cluster address ${NODE_IP} on $(cluster_iface) ($(cluster_mesh))"

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "This VM is already joined to a cluster."
  rm -f "$JOIN_ENV"
  exit 0
fi

: "${JOIN_COMMAND:?JOIN_COMMAND is missing. Run scripts/add-gpu-node.sh from the laptop.}"

hostnamectl set-hostname jarvis-gpu
prepare_os
install_containerd
install_nvidia_runtime
install_kubeadm
write_kubelet_args "$NODE_IP" "--node-labels=gpu.jarvislabs.ai/node=true"

# shellcheck disable=SC2086
bash -lc "$JOIN_COMMAND --node-name=jarvis-gpu --cri-socket=unix:///var/run/containerd/containerd.sock"
rm -f "$JOIN_ENV"
echo "Joined the cluster as jarvis-gpu (${NODE_IP})."
nvidia-smi -L || true
