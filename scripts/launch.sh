#!/usr/bin/env bash
# Create a JarvisLabs GPU instance, upload this repo, and start vLLM + Streamlit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

require_python_yaml
require_jl
load_manifest

if [[ -f "$ROOT/.deploy-state" ]]; then
  echo "This checkout already records an instance in .deploy-state." >&2
  echo "Resume it with scripts/resume.sh, or remove it with scripts/destroy.sh." >&2
  exit 1
fi

if [[ "$GPU_TYPE" == "H100" || "$GPU_TYPE" == "H200" || "$REGION" == "EU1" ]]; then
  if [[ "$NUM_GPUS" != "1" && "$NUM_GPUS" != "8" ]]; then
    echo "EU1 (H100 and H200) accepts 1 or 8 GPUs. Change jarvislabs.num_gpus." >&2
    exit 1
  fi
fi

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

echo "About to create a ${NUM_GPUS}x ${GPU_TYPE} instance named ${INSTANCE_NAME}."
echo "Billing for compute starts when the instance is running. Pause it when you stop using the app."
echo "Gated Hugging Face models need ${HF_TOKEN_ENV} in .env."

create_args=(
  jl create
  --gpu "$GPU_TYPE"
  --num-gpus "$NUM_GPUS"
  --storage "$STORAGE_GB"
  --name "$INSTANCE_NAME"
  --json
)
if [[ "$TEMPLATE" == "vm" ]]; then
  create_args+=(--vm)
else
  create_args+=(--template "$TEMPLATE")
fi
if [[ -n "$REGION" ]]; then
  create_args+=(--region "$REGION")
fi
if [[ -n "$STARTUP_SCRIPT_ID" ]]; then
  create_args+=(--script-id "$STARTUP_SCRIPT_ID")
fi
if [[ "${LAUNCH_YES:-}" == "1" ]]; then
  create_args+=(--yes)
fi

json="$("${create_args[@]}")"
printf '%s\n' "$json" >"$ROOT/.deploy-state.json"
if ! MID="$(printf '%s' "$json" | python3 "$ROOT/scripts/machine_id.py")"; then
  echo "The instance was created, but its id could not be read. See .deploy-state.json." >&2
  exit 1
fi

printf 'MACHINE_ID=%s\n' "$MID" >"$ROOT/.deploy-state"
echo "Instance ${MID} is running. Uploading this repo to /home/llm-deployment."

sync_code "$MID"

if [[ "$TEMPLATE" == "vm" ]]; then
  remote "$MID" "if command -v sudo >/dev/null 2>&1; then sudo ufw allow ${UI_PORT}/tcp; else ufw allow ${UI_PORT}/tcp; fi" || true
fi

start_remote "$MID"
if ! wait_until_ready "$MID"; then
  jl get "$MID" || true
  exit 1
fi

echo
echo "Instance ${MID} is serving ${MODEL_ID}."
if [[ "$TEMPLATE" == "vm" ]]; then
  echo "This is a VM. jl get prints the public IP. Open http://<public-ip>:${UI_PORT}"
else
  echo "In the JarvisLabs dashboard, open this instance and choose API."
  echo "That URL is the Streamlit app on port ${UI_PORT}."
fi
echo "Pause the GPU when you are finished: bash scripts/pause.sh"
jl get "$MID" || true
