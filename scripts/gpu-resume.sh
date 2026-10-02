#!/usr/bin/env bash
# Resume the JarvisLabs GPU worker. kubelet and Tailscale start again with the VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"
require_jl
MID="${1:-}"
if [[ -z "$MID" && -f "$ROOT/.k8s-gpu-state" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.k8s-gpu-state"
  MID="$MACHINE_ID"
fi
if [[ -z "$MID" ]]; then
  echo "No machine id. Run scripts/add-gpu-node.sh or pass the id." >&2
  exit 1
fi
args=(jl resume "$MID")
if [[ "${LAUNCH_YES:-}" == "1" ]]; then
  args+=(--yes)
fi
"${args[@]}"
echo "Resumed ${MID}. On the Azure VM: sudo kubectl get nodes"
echo "jarvis-gpu should become Ready after the mesh client (WireGuard, Tailscale, or NetBird) and kubelet reconnect."
