#!/usr/bin/env bash
# Pause the JarvisLabs GPU worker. The node goes NotReady. Compute billing stops.
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
args=(jl pause "$MID")
if [[ "${LAUNCH_YES:-}" == "1" ]]; then
  args+=(--yes)
fi
"${args[@]}"
echo "Paused ${MID}. The cluster will show jarvis-gpu as NotReady until you resume it."
