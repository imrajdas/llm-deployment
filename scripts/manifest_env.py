#!/usr/bin/env python3
"""Print manifest.yaml as shell assignments or a docker env file.

  eval "$(python3 scripts/manifest_env.py)"
  python3 scripts/manifest_env.py --format docker > docker/.env
"""

from __future__ import annotations

import argparse
import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.manifest import ManifestError, load_manifest  # noqa: E402


def _shell(manifest: dict) -> str:
    lines = [
        _assign("INSTANCE_NAME", manifest["name"]),
        _assign("APP_TITLE", manifest["title"]),
        _assign("MODEL_ID", manifest["model"]),
        _assign("GPU_TYPE", manifest["gpu"]),
        _assign("NUM_GPUS", manifest["num_gpus"]),
        _assign("STORAGE_GB", manifest["storage_gb"]),
        _assign("TEMPLATE", manifest["template"]),
        _assign("REGION", manifest["region"]),
        _assign("STARTUP_SCRIPT_ID", manifest["startup_script_id"]),
        _assign("UI_PORT", manifest["ui_port"]),
        _assign("UI_HOST", manifest["ui_host"]),
        _assign("VLLM_PORT", manifest["vllm_port"]),
        _assign("VLLM_HOST", manifest["vllm_host"]),
        _assign("VLLM_DTYPE", manifest["dtype"]),
        _assign("MAX_MODEL_LEN", manifest["max_model_len"]),
        _assign("GPU_MEMORY_UTILIZATION", _format_float(manifest["gpu_memory_utilization"])),
        _assign("TENSOR_PARALLEL_SIZE", manifest["num_gpus"]),
        _assign("API_KEY_ENV", manifest["api_key_env"]),
        _assign("HF_TOKEN_ENV", manifest["hf_token_env"]),
        _assign("TRUST_REMOTE_CODE", "1" if manifest["trust_remote_code"] else ""),
        "VLLM_EXTRA_ARGS=()",
    ]
    for arg in manifest["extra_args"]:
        lines.append(f"VLLM_EXTRA_ARGS+=({shlex.quote(arg)})")
    return "\n".join(lines) + "\n"


def _docker(manifest: dict) -> str:
    values = {
        "MODEL_ID": manifest["model"],
        "APP_TITLE": manifest["title"],
        "VLLM_DTYPE": manifest["dtype"],
        "MAX_MODEL_LEN": str(manifest["max_model_len"]),
        "GPU_MEMORY_UTILIZATION": _format_float(manifest["gpu_memory_utilization"]),
        "TENSOR_PARALLEL_SIZE": str(manifest["num_gpus"]),
        "UI_PORT": str(manifest["ui_port"]),
        "TRUST_REMOTE_CODE": "1" if manifest["trust_remote_code"] else "",
        "VLLM_EXTRA_ARGS": " ".join(manifest["extra_args"]),
    }
    return "".join(f"{key}={_dotenv(str(value))}\n" for key, value in values.items())


def _assign(name: str, value: object) -> str:
    return f"{name}={shlex.quote(str(value))}"


def _format_float(value: float) -> str:
    return f"{value:.2f}".rstrip("0").rstrip(".")


def _dotenv(value: str) -> str:
    if value == "":
        return ""
    if any(char in value for char in " #\n\t\"'"):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description="Render manifest.yaml for shell or Docker.")
    parser.add_argument("--format", choices=("shell", "docker"), default="shell")
    parser.add_argument("--check", action="store_true", help="Validate the manifest and exit.")
    args = parser.parse_args()

    try:
        manifest = load_manifest(require_gpu=True)
    except ManifestError as exc:
        print(f"manifest.yaml: {exc}", file=sys.stderr)
        return 1

    if args.check:
        print(f"ok {manifest['name']} model={manifest['model']} gpu={manifest['gpu']}")
        return 0

    sys.stdout.write(_docker(manifest) if args.format == "docker" else _shell(manifest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
