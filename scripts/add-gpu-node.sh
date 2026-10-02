#!/usr/bin/env bash
# Create a JarvisLabs GPU VM and join it to the kubeadm cluster on Azure.
# The GPU node has to use the same mesh as the control plane.
#
# Tailscale:
#   export TAILSCALE_AUTHKEY=tskey-auth-...
#   export AZURE_SSH=azureuser@100.x.y.z
#   bash scripts/add-gpu-node.sh
#
# NetBird:
#   export CLUSTER_MESH=netbird
#   export NETBIRD_SETUP_KEY=...
#   export AZURE_SSH=azureuser@100.x.y.z
#   bash scripts/add-gpu-node.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

require_python_yaml
require_jl
load_manifest

if [[ -z "${CLUSTER_MESH:-}" ]]; then
  if [[ -n "${NETBIRD_SETUP_KEY:-}" && -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "Both NETBIRD_SETUP_KEY and TAILSCALE_AUTHKEY are set. Export CLUSTER_MESH=netbird or CLUSTER_MESH=tailscale." >&2
    exit 1
  fi
  if [[ -n "${NETBIRD_SETUP_KEY:-}" ]]; then
    CLUSTER_MESH=netbird
  else
    CLUSTER_MESH=tailscale
  fi
fi
case "$CLUSTER_MESH" in
  netbird)
    if [[ -z "${NETBIRD_SETUP_KEY:-}" ]]; then
      echo "Export NETBIRD_SETUP_KEY from the NetBird dashboard (a reusable setup key)." >&2
      exit 1
    fi
    ;;
  tailscale)
    if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
      echo "Export TAILSCALE_AUTHKEY from the Tailscale admin console (reusable, preauthorized)." >&2
      echo "To use NetBird instead: export CLUSTER_MESH=netbird NETBIRD_SETUP_KEY=..." >&2
      exit 1
    fi
    ;;
  *)
    echo "scripts/add-gpu-node.sh supports CLUSTER_MESH=tailscale or CLUSTER_MESH=netbird." >&2
    echo "WireGuard uses the manual steps in the README." >&2
    exit 1
    ;;
esac
if [[ -z "${AZURE_SSH:-}" ]]; then
  echo "Export AZURE_SSH, for example azureuser@<mesh-ip-of-the-azure-vm>." >&2
  exit 1
fi
if [[ -f "$ROOT/.k8s-gpu-state" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.k8s-gpu-state"
  MID="$MACHINE_ID"
  echo "Reusing JarvisLabs VM ${MID} from .k8s-gpu-state."
else
  MID=""
fi

if [[ "$GPU_TYPE" == "H100" || "$GPU_TYPE" == "H200" || "$REGION" == "EU1" ]]; then
  if [[ "$NUM_GPUS" != "1" && "$NUM_GPUS" != "8" ]]; then
    echo "EU1 (H100 and H200) accepts 1 or 8 GPUs. Change jarvislabs.num_gpus." >&2
    exit 1
  fi
fi

storage="$STORAGE_GB"
if [[ "$storage" -lt 100 ]]; then
  echo "JarvisLabs VMs need at least 100 GB. Using 100."
  storage=100
fi

if [[ -z "$MID" ]]; then
  echo "The GPU VM must be a real VM. Template containers cannot run kubelet."
  echo "Creating ${NUM_GPUS}x ${GPU_TYPE} VM named k8s-gpu. An SSH key must already be registered (jl ssh-key add)."

  create_args=(
    jl create
    --vm
    --gpu "$GPU_TYPE"
    --num-gpus "$NUM_GPUS"
    --storage "$storage"
    --name "k8s-gpu"
    --json
  )
  if [[ -n "$REGION" ]]; then
    create_args+=(--region "$REGION")
  fi
  if [[ "${LAUNCH_YES:-}" == "1" ]]; then
    create_args+=(--yes)
  fi

  json="$("${create_args[@]}")"
  printf '%s\n' "$json" >"$ROOT/.k8s-gpu-state.json"
  if ! MID="$(printf '%s' "$json" | python3 "$ROOT/scripts/machine_id.py")"; then
    echo "The VM was created, but its id could not be read. See .k8s-gpu-state.json." >&2
    exit 1
  fi
  printf 'MACHINE_ID=%s\n' "$MID" >"$ROOT/.k8s-gpu-state"
fi

echo "Fetching a fresh kubeadm join command from ${AZURE_SSH}."
JOIN="$(ssh -o StrictHostKeyChecking=accept-new "$AZURE_SSH" sudo kubeadm token create --print-join-command)"

sync_code "$MID"

join_file="$(mktemp)"
chmod 600 "$join_file"
{
  printf 'CLUSTER_MESH=%q\n' "$CLUSTER_MESH"
  printf 'JOIN_COMMAND=%q\n' "$JOIN"
  if [[ "$CLUSTER_MESH" == "netbird" ]]; then
    printf 'NETBIRD_SETUP_KEY=%q\n' "$NETBIRD_SETUP_KEY"
    if [[ -n "${NETBIRD_MANAGEMENT_URL:-}" ]]; then
      printf 'NETBIRD_MANAGEMENT_URL=%q\n' "$NETBIRD_MANAGEMENT_URL"
    fi
  else
    printf 'TAILSCALE_AUTHKEY=%q\n' "$TAILSCALE_AUTHKEY"
  fi
} >"$join_file"
jl upload "$MID" "$join_file" /home/llm-deployment/join.env
rm -f "$join_file"

echo "Installing Kubernetes and joining the cluster. This takes several minutes."
remote "$MID" "sudo bash /home/llm-deployment/k8s/scripts/bootstrap-gpu-node.sh"

echo "Labeling jarvis-gpu and waiting for the NVIDIA device plugin."
ssh -o StrictHostKeyChecking=accept-new "$AZURE_SSH" \
  "sudo kubectl label node jarvis-gpu gpu.jarvislabs.ai/node=true --overwrite"
ssh -o StrictHostKeyChecking=accept-new "$AZURE_SSH" \
  "sudo kubectl wait --for=condition=Ready node/jarvis-gpu --timeout=300s"

echo
echo "GPU node jarvis-gpu is Ready. JarvisLabs machine id ${MID}."
echo "Build the Streamlit image, then on the Azure VM run: bash scripts/k8s-apply.sh"
echo "Pause the GPU when you are finished: bash scripts/gpu-pause.sh"
