#!/usr/bin/env bash
# Bootstrap a single-node kubeadm control plane on the Azure VM.
# WireGuard (README default):
#   sudo env CLUSTER_NODE_IP=10.200.0.1 CLUSTER_IFACE=wg0 \
#     bash k8s/scripts/bootstrap-control-plane.sh
# Tailscale:
#   sudo tailscale up
#   sudo bash k8s/scripts/bootstrap-control-plane.sh
# NetBird:
#   sudo env CLUSTER_MESH=netbird NETBIRD_SETUP_KEY=... \
#     bash k8s/scripts/bootstrap-control-plane.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/k8s/scripts/node-prep.sh"
require_root

if [[ -f /etc/kubernetes/admin.conf ]]; then
  echo "This machine already has a kubeadm control plane (/etc/kubernetes/admin.conf)."
  echo "Join command for a new worker:"
  kubeadm token create --print-join-command
  exit 0
fi

ensure_cluster_mesh k8s-cp
NODE_IP="$(cluster_node_ip)"
CLUSTER_IFACE="$(cluster_iface)"
echo "Using ${NODE_IP} on ${CLUSTER_IFACE} ($(cluster_mesh)) as the Kubernetes API address."

hostnamectl set-hostname k8s-cp
prepare_os
install_containerd
install_kubeadm
write_kubelet_args "$NODE_IP"

kubeadm init \
  --apiserver-advertise-address="$NODE_IP" \
  --control-plane-endpoint="$NODE_IP:6443" \
  --pod-network-cidr=10.244.0.0/16 \
  --node-name=k8s-cp \
  --cri-socket=unix:///var/run/containerd/containerd.sock

export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  install -d -o "$SUDO_USER" -g "$SUDO_USER" -m 0755 "${user_home}/.kube"
  cp /etc/kubernetes/admin.conf "${user_home}/.kube/config"
  chown "$SUDO_USER:$SUDO_USER" "${user_home}/.kube/config"
  chmod 600 "${user_home}/.kube/config"
fi

echo "Installing Flannel over ${CLUSTER_IFACE}."
kubectl apply -f "$FLANNEL_MANIFEST"

FLANNEL_NS=""
for ns in kube-flannel kube-system; do
  if kubectl -n "$ns" get ds kube-flannel-ds >/dev/null 2>&1; then
    FLANNEL_NS="$ns"
    break
  fi
done
if [[ -z "$FLANNEL_NS" ]]; then
  echo "Flannel was applied, but kube-flannel-ds was not found." >&2
  exit 1
fi

kubectl -n "$FLANNEL_NS" patch ds kube-flannel-ds --type=json \
  -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--iface=${CLUSTER_IFACE}\"}]"

FLANNEL_MTU="$(cluster_flannel_mtu)"
python3 - "$FLANNEL_NS" "$FLANNEL_MTU" <<'PY'
import json, subprocess, sys
ns, mtu = sys.argv[1], int(sys.argv[2])
raw = subprocess.check_output([
    "kubectl", "-n", ns, "get", "cm", "kube-flannel-cfg",
    "-o", "jsonpath={.data.net-conf\\.json}",
])
net = json.loads(raw)
backend = net.setdefault("Backend", {"Type": "vxlan"})
# Tailscale and NetBird tunnels are 1280. VXLAN needs about 50 bytes.
backend["MTU"] = mtu
patch = json.dumps({"data": {"net-conf.json": json.dumps(net)}})
subprocess.run([
    "kubectl", "-n", ns, "patch", "cm", "kube-flannel-cfg",
    "--type=merge", "-p", patch,
], check=True)
PY
kubectl -n "$FLANNEL_NS" rollout restart ds/kube-flannel-ds
kubectl -n "$FLANNEL_NS" rollout status ds/kube-flannel-ds --timeout=180s

echo "Installing a local volume provisioner for the model cache."
kubectl apply -f "$LOCAL_PATH_MANIFEST"
for _ in 1 2 3 4 5 6; do
  if kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'; then
    break
  fi
  sleep 5
done

echo "Installing the NVIDIA device plugin. It stays pending until the GPU node is labeled."
kubectl apply -f "$NVIDIA_DEVICE_PLUGIN_MANIFEST"
patched=0
for name in nvidia-device-plugin-daemonset nvidia-device-plugin; do
  if kubectl -n kube-system get ds "$name" >/dev/null 2>&1; then
    kubectl -n kube-system patch ds "$name" --type=merge -p \
      '{"spec":{"template":{"spec":{"nodeSelector":{"gpu.jarvislabs.ai/node":"true"}}}}}'
    patched=1
    break
  fi
done
if [[ "$patched" != "1" ]]; then
  echo "The device plugin DaemonSet name was not recognized. Set its nodeSelector to gpu.jarvislabs.ai/node=true." >&2
fi

kubectl wait --for=condition=Ready "node/k8s-cp" --timeout=180s
echo
echo "Control plane is Ready at https://${NODE_IP}:6443"
case "$(cluster_mesh)" in
  netbird)
    echo "From the laptop, export AZURE_SSH to a user that can SSH to this NetBird address."
    ;;
  tailscale)
    echo "From the laptop, export AZURE_SSH to a user that can SSH to this Tailscale address."
    ;;
  *)
    echo "From the laptop, export AZURE_SSH to a user that can SSH to this VM."
    ;;
esac
echo "Example: export AZURE_SSH=${SUDO_USER:-azureuser}@${NODE_IP}"
echo
kubeadm token create --print-join-command
