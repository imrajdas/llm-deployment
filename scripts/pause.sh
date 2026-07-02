#!/usr/bin/env bash
# Pause the instance recorded in .deploy-state. Compute billing stops; storage billing continues.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

require_jl
MID="$(resolve_machine_id "${1:-}")"
args=(jl pause "$MID")
if [[ "${LAUNCH_YES:-}" == "1" ]]; then
  args+=(--yes)
fi
"${args[@]}"
echo "Paused ${MID}. Resume with: bash scripts/resume.sh"
