#!/usr/bin/env python3
"""Write k8s/configmap.yaml from manifest.yaml."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.manifest import ManifestError, load_manifest  # noqa: E402


def render(manifest: dict) -> str:
    extra = " ".join(manifest["extra_args"])
    lines = [
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        "  name: llm-config",
        "  namespace: llm",
        "data:",
        f"  MODEL_ID: {yaml_quote(manifest['model'])}",
        f"  APP_TITLE: {yaml_quote(manifest['title'])}",
        f"  VLLM_DTYPE: {yaml_quote(manifest['dtype'])}",
        f"  MAX_MODEL_LEN: {yaml_quote(str(manifest['max_model_len']))}",
        f"  GPU_MEMORY_UTILIZATION: {yaml_quote(format_float(manifest['gpu_memory_utilization']))}",
        f"  TENSOR_PARALLEL_SIZE: {yaml_quote(str(manifest['num_gpus']))}",
        f"  TRUST_REMOTE_CODE: {yaml_quote('1' if manifest['trust_remote_code'] else '')}",
        f"  VLLM_EXTRA_ARGS: {yaml_quote(extra)}",
        f"  UI_PORT: {yaml_quote(str(manifest['ui_port']))}",
        "",
    ]
    return "\n".join(lines)


def yaml_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def format_float(value: float) -> str:
    return f"{value:.2f}".rstrip("0").rstrip(".")


def main() -> int:
    try:
        manifest = load_manifest(require_gpu=True)
    except ManifestError as exc:
        print(f"manifest.yaml: {exc}", file=sys.stderr)
        return 1
    path = ROOT / "k8s" / "configmap.yaml"
    path.write_text(render(manifest), encoding="utf-8")
    print(f"Wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
