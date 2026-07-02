#!/bin/sh
# Container entrypoint. Reads the env written by scripts/render-docker-env.sh.
set -eu

: "${MODEL_ID:?MODEL_ID is required}"
: "${VLLM_DTYPE:=bfloat16}"
: "${MAX_MODEL_LEN:=8192}"
: "${GPU_MEMORY_UTILIZATION:=0.90}"
: "${TENSOR_PARALLEL_SIZE:=1}"

set -- serve "$MODEL_ID" \
  --host 0.0.0.0 \
  --port 8000 \
  --dtype "$VLLM_DTYPE" \
  --max-model-len "$MAX_MODEL_LEN" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --tensor-parallel-size "$TENSOR_PARALLEL_SIZE"

if [ "${TRUST_REMOTE_CODE:-}" = "1" ]; then
  set -- "$@" --trust-remote-code
fi

if [ -n "${VLLM_API_KEY:-}" ]; then
  set -- "$@" --api-key "$VLLM_API_KEY"
fi

if [ -n "${VLLM_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2086
  set -- "$@" $VLLM_EXTRA_ARGS
fi

exec vllm "$@"
