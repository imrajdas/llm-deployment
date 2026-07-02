#!/usr/bin/env bash
# Exit 0 when vLLM and Streamlit are both answering.
# On the instance: bash scripts/healthcheck.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VLLM_PORT=8000
UI_PORT=6006

if [[ -x "$ROOT/.venv/bin/python" ]] && "$ROOT/.venv/bin/python" -c "import yaml" >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  eval "$("$ROOT/.venv/bin/python" "$ROOT/scripts/manifest_env.py")"
elif python3 -c "import yaml" >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  eval "$(python3 "$ROOT/scripts/manifest_env.py")"
fi

http_ok() {
  python3 - "$1" <<'PY'
import sys
import urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=3)
except Exception:
    sys.exit(1)
PY
}

vllm_ok=0
ui_ok=0

if http_ok "http://127.0.0.1:${VLLM_PORT}/health"; then
  vllm_ok=1
  echo "vllm: ok"
else
  echo "vllm: down"
fi

if http_ok "http://127.0.0.1:${UI_PORT}/_stcore/health"; then
  ui_ok=1
  echo "streamlit: ok"
else
  echo "streamlit: down"
fi

if [[ "$vllm_ok" == "1" && "$ui_ok" == "1" ]]; then
  exit 0
fi
exit 1
