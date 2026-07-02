#!/usr/bin/env bash
# Stream vLLM and Streamlit logs from the instance. Ctrl-C closes the stream.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

require_jl
MID="$(resolve_machine_id "${1:-}")"
remote "$MID" "cd /home/llm-deployment && mkdir -p logs && touch logs/vllm.log logs/serve.log && tail -n 80 -f logs/vllm.log logs/serve.log"
