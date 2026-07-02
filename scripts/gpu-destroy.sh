#!/usr/bin/env bash
# Delete the JarvisLabs GPU VM and drop it from the cluster.
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
  echo "No machine id. Pass one: bash scripts/gpu-destroy.sh <id>" >&2
  exit 1
fi

if [[ -n "${AZURE_SSH:-}" ]]; then
  ssh -o StrictHostKeyChecking=accept-new "$AZURE_SSH" \
    "sudo kubectl delete node jarvis-gpu --ignore-not-found"
fi

echo "This deletes JarvisLabs VM ${MID} and the model cache stored on its disk."
args=(jl destroy "$MID")
if [[ "${LAUNCH_YES:-}" == "1" ]]; then
  args+=(--yes)
fi
"${args[@]}"
rm -f "$ROOT/.k8s-gpu-state" "$ROOT/.k8s-gpu-state.json"
echo "Removed .k8s-gpu-state."
