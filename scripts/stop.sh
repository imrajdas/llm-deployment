#!/usr/bin/env bash
# Stop vLLM and Streamlit started by scripts/serve.sh.
# On the instance: bash scripts/stop.sh --local
# From a laptop:   bash scripts/stop.sh [machine_id]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

stop_local() {
  local app_dir="$ROOT"
  local pidfile pid
  for pidfile in "$app_dir/logs/vllm.pid" "$app_dir/logs/streamlit.pid"; do
    if [[ -f "$pidfile" ]]; then
      pid="$(cat "$pidfile")"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$pidfile"
    fi
  done

  local candidate pattern
  if command -v pgrep >/dev/null 2>&1; then
    local patterns=("vllm serve" "streamlit run app/streamlit_app.py")
    # serve.sh calls this while it is still the parent. Do not kill that parent.
    if [[ "${STOP_KEEP_SERVE:-}" != "1" ]]; then
      patterns+=("scripts/serve.sh")
    fi
    for pattern in "${patterns[@]}"; do
      for candidate in $(pgrep -f "$pattern" || true); do
        if [[ "$candidate" != "$$" && "$candidate" != "$PPID" ]]; then
          kill "$candidate" 2>/dev/null || true
        fi
      done
    done
  fi
  echo "Stopped local vLLM and Streamlit processes."
}

if [[ "${1:-}" == "--local" ]]; then
  stop_local
  exit 0
fi

# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"
require_jl
MID="$(resolve_machine_id "${1:-}")"
remote "$MID" "cd /home/llm-deployment && bash scripts/stop.sh --local"
