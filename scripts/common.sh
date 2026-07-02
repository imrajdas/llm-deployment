# Shared helpers for the operator scripts. Source this file; do not execute it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_manifest() {
  # shellcheck disable=SC1090
  eval "$(python3 "$ROOT/scripts/manifest_env.py")"
}

require_python_yaml() {
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo "Install operator dependencies: pip install -r requirements-operator.txt" >&2
    return 1
  fi
}

require_jl() {
  if ! command -v jl >/dev/null 2>&1; then
    echo "Install the JarvisLabs CLI, then sign in:" >&2
    echo "  pip install -r requirements-operator.txt" >&2
    echo "  jl setup" >&2
    return 1
  fi
}

resolve_machine_id() {
  local requested="${1:-}"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi
  if [[ -f "$ROOT/.deploy-state" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/.deploy-state"
    if [[ -n "${MACHINE_ID:-}" ]]; then
      printf '%s\n' "$MACHINE_ID"
      return 0
    fi
  fi
  echo "No machine id. Run scripts/launch.sh, or pass the id as an argument." >&2
  return 1
}

remote() {
  local machine_id="$1"
  shift
  jl exec "$machine_id" -- sh -lc "$*"
}

sync_code() {
  local machine_id="$1"
  local stage
  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required on your laptop to upload the repo." >&2
    return 1
  fi

  stage="$(mktemp -d)"
  rsync -a \
    --exclude '.git/' \
    --exclude '.venv/' \
    --exclude 'logs/' \
    --exclude '.cache/' \
    --exclude '.deploy-state' \
    --exclude '.k8s-gpu-state' \
    --exclude 'join.env' \
    --exclude '.env' \
    --exclude '__pycache__/' \
    --exclude '.pytest_cache/' \
    "$ROOT/" "$stage/payload/"
  if [[ -f "$ROOT/.env" ]]; then
    cp "$ROOT/.env" "$stage/payload/.env"
    chmod 600 "$stage/payload/.env"
  fi

  jl upload "$machine_id" "$stage/payload" /tmp/llm-payload
  rm -rf "$stage"

  remote "$machine_id" 'set -eu
    if [ -f /tmp/llm-payload/manifest.yaml ]; then SRC=/tmp/llm-payload
    elif [ -f /tmp/llm-payload/payload/manifest.yaml ]; then SRC=/tmp/llm-payload/payload
    else echo "Upload layout was not recognized." >&2; ls -la /tmp/llm-payload >&2; exit 1
    fi
    mkdir -p /home/llm-deployment
    cp -a "$SRC"/. /home/llm-deployment/
    rm -rf /tmp/llm-payload
    chmod +x /home/llm-deployment/scripts/*.sh
  '
}

start_remote() {
  local machine_id="$1"
  remote "$machine_id" "cd /home/llm-deployment && mkdir -p logs && nohup bash scripts/serve.sh > logs/serve.log 2>&1 & echo started"
}

wait_until_ready() {
  local machine_id="$1"
  local attempt
  echo "Waiting for vLLM and Streamlit. The first boot installs vLLM and downloads the model."
  for attempt in $(seq 1 80); do
    if remote "$machine_id" "bash /home/llm-deployment/scripts/healthcheck.sh"; then
      echo "The app is answering on the instance."
      return 0
    fi
    echo "Still starting (${attempt}/80). Follow logs with: bash scripts/logs.sh"
    sleep 30
  done
  echo "The app did not become healthy within 40 minutes. Recent logs:" >&2
  remote "$machine_id" "tail -n 40 /home/llm-deployment/logs/serve.log /home/llm-deployment/logs/vllm.log" || true
  echo "The instance is still running and still billing. Pause it with: bash scripts/pause.sh" >&2
  return 1
}
