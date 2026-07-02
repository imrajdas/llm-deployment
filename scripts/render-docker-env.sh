#!/usr/bin/env bash
# Write docker/.env from manifest.yaml for the VM compose path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "Install operator dependencies: pip install -r requirements-operator.txt" >&2
  exit 1
fi

python3 "$ROOT/scripts/manifest_env.py" --format docker >"$ROOT/docker/.env"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

if [[ -n "${HF_TOKEN:-}" ]]; then
  printf 'HF_TOKEN=%s\n' "$HF_TOKEN" >>"$ROOT/docker/.env"
fi
if [[ -n "${VLLM_API_KEY:-}" ]]; then
  printf 'VLLM_API_KEY=%s\n' "$VLLM_API_KEY" >>"$ROOT/docker/.env"
fi

echo "Wrote docker/.env"
