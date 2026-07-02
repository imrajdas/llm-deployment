#!/usr/bin/env bash
# Apply the chat stack. Run this where kubectl talks to the Azure cluster.
#
#   export UI_IMAGE=ghcr.io/you/llm-chat-ui:latest
#   bash scripts/k8s-apply.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${UI_IMAGE:-}" ]]; then
  echo "Set UI_IMAGE to a registry path the cluster can pull." >&2
  echo "  docker build -f docker/Dockerfile -t ghcr.io/you/llm-chat-ui:latest ." >&2
  echo "  docker push ghcr.io/you/llm-chat-ui:latest" >&2
  echo "  export UI_IMAGE=ghcr.io/you/llm-chat-ui:latest" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required. On the Azure VM it is installed by the control-plane script." >&2
  exit 1
fi

python3 "$ROOT/k8s/render_configmap.py"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -a "$ROOT/k8s/." "$work/k8s/"

python3 - "$work/k8s/vllm.yaml" "$ROOT/manifest.yaml" "$UI_IMAGE" "$work/k8s/streamlit.yaml" <<'PY'
import re, sys
from pathlib import Path

vllm_path, manifest_path, image, ui_path = sys.argv[1:]
sys.path.insert(0, str(Path(manifest_path).resolve().parent))
from app.manifest import load_manifest

manifest = load_manifest(require_gpu=True)
count = str(manifest["num_gpus"])
text = Path(vllm_path).read_text(encoding="utf-8")
text = re.sub(
    r'(nvidia.com/gpu:\s*)"\d+"(\s*# manifest.num_gpus)',
    rf'\1"{count}"\2',
    text,
)
Path(vllm_path).write_text(text, encoding="utf-8")
ui = Path(ui_path).read_text(encoding="utf-8")
ui = ui.replace("image: llm-deployment-ui:latest", f"image: {image}", 1)
Path(ui_path).write_text(ui, encoding="utf-8")
PY

kubectl apply -k "$work/k8s"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
if [[ -n "${HF_TOKEN:-}" || -n "${VLLM_API_KEY:-}" ]]; then
  kubectl -n llm create secret generic hf-token \
    --from-literal="HF_TOKEN=${HF_TOKEN:-}" \
    --from-literal="VLLM_API_KEY=${VLLM_API_KEY:-}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n llm rollout restart deployment/vllm deployment/streamlit
fi

echo
echo "vLLM is scheduled only on the JarvisLabs GPU node. The first pull and model download take a while."
echo "Follow it with: kubectl -n llm logs -f deploy/vllm"
echo "Open the UI from the Azure VM public IP, port 30066, or:"
echo "  kubectl -n llm port-forward svc/streamlit 6006:80"
