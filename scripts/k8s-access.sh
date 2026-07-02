#!/usr/bin/env bash
# Point local kubectl at the Azure control plane.
# The API listens on the overlay address, so this opens an SSH tunnel
# and writes ~/.kube/config to use it.
#
#   bash scripts/k8s-access.sh
#
# Connection details come from .k8s-cp-state when that file exists:
#   AZURE_SSH=azureuser@<public-ip>
#   CLUSTER_API=10.200.0.1:6443
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/.k8s-cp-state" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.k8s-cp-state"
fi

AZURE_SSH="${AZURE_SSH:-}"
AZURE_SSH_KEY="${AZURE_SSH_KEY:-$HOME/.ssh/id_ed25519}"
CLUSTER_API="${CLUSTER_API:-10.200.0.1:6443}"
LOCAL_API_PORT="${LOCAL_API_PORT:-16443}"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

if [[ -z "$AZURE_SSH" ]]; then
  echo "Set AZURE_SSH, for example azureuser@<azure-public-ip>." >&2
  echo "Or write it to ${ROOT}/.k8s-cp-state" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not on PATH." >&2
  exit 1
fi
if [[ ! -f "$AZURE_SSH_KEY" ]]; then
  echo "SSH key not found: ${AZURE_SSH_KEY}" >&2
  exit 1
fi

API_HOST="${CLUSTER_API%%:*}"
API_PORT="${CLUSTER_API##*:}"
SOCK="${HOME}/.ssh/llm-k8s-api.sock"
SSH_OPTS=(
  -i "$AZURE_SSH_KEY"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o ExitOnForwardFailure=yes
)

tunnel_up() {
  ssh "${SSH_OPTS[@]}" -S "$SOCK" -O check "$AZURE_SSH" >/dev/null 2>&1
}

if tunnel_up; then
  echo "SSH tunnel already open on 127.0.0.1:${LOCAL_API_PORT}."
else
  echo "Opening SSH tunnel to ${API_HOST}:${API_PORT} via ${AZURE_SSH}."
  ssh "${SSH_OPTS[@]}" -f -N -M -S "$SOCK" \
    -L "127.0.0.1:${LOCAL_API_PORT}:${API_HOST}:${API_PORT}" \
    "$AZURE_SSH"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
ssh "${SSH_OPTS[@]}" "$AZURE_SSH" 'cat ~/.kube/config' >"$tmp"
chmod 600 "$tmp"

cluster="$(kubectl --kubeconfig="$tmp" config view -o jsonpath='{.clusters[0].name}')"
context="$(kubectl --kubeconfig="$tmp" config view -o jsonpath='{.contexts[0].name}')"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
install -m 600 "$tmp" "$KUBECONFIG_PATH"

kubectl --kubeconfig="$KUBECONFIG_PATH" config set-cluster "$cluster" \
  --server="https://127.0.0.1:${LOCAL_API_PORT}" \
  --tls-server-name="$API_HOST" >/dev/null
if [[ "$context" != "llm-deployment" ]]; then
  kubectl --kubeconfig="$KUBECONFIG_PATH" config rename-context "$context" llm-deployment >/dev/null
fi
kubectl --kubeconfig="$KUBECONFIG_PATH" config use-context llm-deployment >/dev/null
chmod 600 "$KUBECONFIG_PATH"

echo "Kubeconfig: ${KUBECONFIG_PATH} (context llm-deployment)"
kubectl --kubeconfig="$KUBECONFIG_PATH" get nodes
