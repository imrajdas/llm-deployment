#!/usr/bin/env bash
# Resume the instance, upload the current checkout, and start vLLM + Streamlit again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

require_python_yaml
require_jl
load_manifest
MID="$(resolve_machine_id "${1:-}")"

args=(jl resume "$MID" --json)
if [[ "${LAUNCH_YES:-}" == "1" ]]; then
  args+=(--yes)
fi
json="$("${args[@]}")"
printf '%s\n' "$json" >"$ROOT/.deploy-state.json"
NEW_MID="$(printf '%s' "$json" | python3 "$ROOT/scripts/machine_id.py" || true)"
if [[ -z "$NEW_MID" ]]; then
  echo "Could not read a machine id from jl resume. Continuing with ${MID}." >&2
elif [[ "$NEW_MID" != "$MID" ]]; then
  echo "JarvisLabs assigned a new machine id: ${NEW_MID}"
  MID="$NEW_MID"
  printf 'MACHINE_ID=%s\n' "$MID" >"$ROOT/.deploy-state"
fi

echo "Uploading the current checkout and restarting the app."
sync_code "$MID"
remote "$MID" "cd /home/llm-deployment && bash scripts/stop.sh --local" || true
start_remote "$MID"
wait_until_ready "$MID"

echo "In the JarvisLabs dashboard, choose API for instance ${MID}."
echo "Pause when you are finished: bash scripts/pause.sh"
