#!/usr/bin/env bash
# Delete the JarvisLabs instance and the files stored on it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

require_jl
MID="$(resolve_machine_id "${1:-}")"
echo "This deletes instance ${MID} and the disk, including the downloaded model."
args=(jl destroy "$MID")
if [[ "${LAUNCH_YES:-}" == "1" ]]; then
  args+=(--yes)
fi
"${args[@]}"
rm -f "$ROOT/.deploy-state"
echo "Removed .deploy-state."
