#!/usr/bin/env bash
# Start vLLM, wait until it answers, then run Streamlit in the foreground.
# Intended for a JarvisLabs GPU instance. The repo lives at /home/llm-deployment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/logs"

http_ok() {
  python - "$1" <<'PY'
import sys
import urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=3)
except Exception:
    sys.exit(1)
PY
}

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

if [[ ! -d "$ROOT/.venv" ]]; then
  python3 -m venv "$ROOT/.venv"
fi
# shellcheck disable=SC1091
source "$ROOT/.venv/bin/activate"
python -c "import yaml" >/dev/null 2>&1 || python -m pip install "pyyaml>=6.0"

# shellcheck disable=SC1091
eval "$(python "$ROOT/scripts/manifest_env.py")"

export HF_HOME="${HF_HOME:-$ROOT/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME}"
export HF_TOKEN="${HF_TOKEN:-}"
if [[ -n "$HF_TOKEN" ]]; then
  export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
fi

API_KEY_VALUE=""
if [[ -n "${API_KEY_ENV}" && -n "${!API_KEY_ENV:-}" ]]; then
  API_KEY_VALUE="${!API_KEY_ENV}"
  export VLLM_API_KEY="$API_KEY_VALUE"
fi

if command -v flock >/dev/null 2>&1; then
  exec 9>"$ROOT/logs/serve.lock"
  if ! flock -n 9; then
    echo "serve.sh is already running."
    exit 0
  fi
fi

health_url="http://127.0.0.1:${VLLM_PORT}/health"
ui_health="http://127.0.0.1:${UI_PORT}/_stcore/health"

if http_ok "$health_url" && http_ok "$ui_health"; then
  echo "vLLM and Streamlit are already up."
  exit 0
fi

STOP_KEEP_SERVE=1 bash "$ROOT/scripts/stop.sh" --local || true

need_install=0
if [[ "${SERVE_REINSTALL:-}" == "1" || ! -x "$ROOT/.venv/bin/vllm" ]]; then
  need_install=1
fi
if ! python -c "import streamlit, openai, yaml" >/dev/null 2>&1; then
  need_install=1
fi

if [[ "$need_install" == "1" ]]; then
  avail_kb="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -lt 30000000 ]]; then
    echo "Less than 30 GB free on this disk. Raise jarvislabs.storage_gb in manifest.yaml." >&2
    exit 1
  fi
  echo "Installing Python packages. The vLLM wheel can take several minutes."
  python -m pip install --upgrade pip
  python -m pip install -r "$ROOT/requirements.txt" -r "$ROOT/requirements-vllm.txt"
fi

cmd=(
  "$ROOT/.venv/bin/vllm" serve "$MODEL_ID"
  --host "$VLLM_HOST"
  --port "$VLLM_PORT"
  --dtype "$VLLM_DTYPE"
  --max-model-len "$MAX_MODEL_LEN"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --tensor-parallel-size "$TENSOR_PARALLEL_SIZE"
)
if [[ -n "$API_KEY_VALUE" ]]; then
  cmd+=(--api-key "$API_KEY_VALUE")
fi
if [[ -n "$TRUST_REMOTE_CODE" ]]; then
  cmd+=(--trust-remote-code)
fi
if [[ ${#VLLM_EXTRA_ARGS[@]} -gt 0 ]]; then
  cmd+=("${VLLM_EXTRA_ARGS[@]}")
fi

echo "Starting vLLM: ${cmd[*]}"
nohup "${cmd[@]}" >"$ROOT/logs/vllm.log" 2>&1 &
echo $! >"$ROOT/logs/vllm.pid"

echo "Waiting for ${health_url} (model download happens on first boot)."
ready=0
for _ in $(seq 1 120); do
  if http_ok "$health_url"; then
    ready=1
    break
  fi
  if ! kill -0 "$(cat "$ROOT/logs/vllm.pid")" 2>/dev/null; then
    echo "vLLM exited. Last log lines:" >&2
    tail -n 40 "$ROOT/logs/vllm.log" >&2 || true
    exit 1
  fi
  sleep 10
done

if [[ "$ready" != "1" ]]; then
  echo "vLLM did not become healthy in 20 minutes. See logs/vllm.log." >&2
  exit 1
fi

echo "vLLM is healthy. Starting Streamlit on ${UI_HOST}:${UI_PORT}."
export MODEL_ID APP_TITLE
export VLLM_BASE_URL="http://127.0.0.1:${VLLM_PORT}/v1"
exec "$ROOT/.venv/bin/streamlit" run "$ROOT/app/streamlit_app.py" \
  --server.address "$UI_HOST" \
  --server.port "$UI_PORT" \
  --server.headless true \
  --browser.gatherUsageStats false
