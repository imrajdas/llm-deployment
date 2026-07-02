"""Load and validate manifest.yaml."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "manifest.yaml"

_NAME_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-")
_DTYPES = {"auto", "bfloat16", "float16", "half", "float32"}


class ManifestError(ValueError):
    """The manifest is missing or has a value this repo cannot deploy."""


def load_manifest(path: Path | None = None, *, require_gpu: bool = False) -> dict[str, Any]:
    manifest_path = path or MANIFEST_PATH
    if not manifest_path.is_file():
        raise ManifestError(f"Manifest not found: {manifest_path}")

    raw = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    if not isinstance(raw, dict):
        raise ManifestError("manifest.yaml must be a mapping at the top level.")

    jarvis = _section(raw, "jarvislabs")
    ports = _section(raw, "ports")
    vllm = _section(raw, "vllm")
    ui = _section(raw, "streamlit")

    name = _text(raw.get("name"), "name") or "llm-chat"
    _check_instance_name(name)

    model = _text(raw.get("model"), "model")
    if not model:
        raise ManifestError("Set `model` to a Hugging Face model id.")

    gpu = _text(jarvis.get("gpu"), "jarvislabs.gpu")
    if require_gpu and not gpu:
        raise ManifestError("Set `jarvislabs.gpu`. Run `jl gpus` for the current list.")

    num_gpus = _int(jarvis.get("num_gpus", 1), "jarvislabs.num_gpus", minimum=1, maximum=8)
    storage_gb = _int(jarvis.get("storage_gb", 100), "jarvislabs.storage_gb", minimum=20, maximum=2048)
    template = _text(jarvis.get("template"), "jarvislabs.template") or "pytorch"
    region = _text(jarvis.get("region"), "jarvislabs.region")
    if region and region not in {"IN2", "EU1"}:
        raise ManifestError("jarvislabs.region must be empty, IN2, or EU1.")

    startup_script_id = jarvis.get("startup_script_id", "")
    if startup_script_id in (None, ""):
        startup_script_id = ""
    else:
        startup_script_id = str(_int(startup_script_id, "jarvislabs.startup_script_id", minimum=1))

    extra_args = vllm.get("extra_args") or []
    if not isinstance(extra_args, list) or not all(isinstance(item, str) for item in extra_args):
        raise ManifestError("vllm.extra_args must be a list of strings.")

    dtype = _text(vllm.get("dtype"), "vllm.dtype") or "bfloat16"
    if dtype not in _DTYPES:
        raise ManifestError(f"vllm.dtype must be one of: {', '.join(sorted(_DTYPES))}.")

    return {
        "name": name,
        "title": _text(raw.get("title"), "title") or "LLM Chat",
        "model": model,
        "gpu": gpu,
        "num_gpus": num_gpus,
        "storage_gb": storage_gb,
        "template": template,
        "region": region,
        "startup_script_id": startup_script_id,
        "ui_port": _int(ports.get("ui", 6006), "ports.ui", minimum=1, maximum=65535),
        "ui_host": _text(ui.get("host"), "streamlit.host") or "0.0.0.0",
        "vllm_port": _int(ports.get("vllm", 8000), "ports.vllm", minimum=1, maximum=65535),
        "vllm_host": _text(vllm.get("host"), "vllm.host") or "127.0.0.1",
        "dtype": dtype,
        "max_model_len": _int(vllm.get("max_model_len", 8192), "vllm.max_model_len", minimum=256),
        "gpu_memory_utilization": _float(
            vllm.get("gpu_memory_utilization", 0.9),
            "vllm.gpu_memory_utilization",
            minimum=0.1,
            maximum=1.0,
        ),
        "api_key_env": _text(vllm.get("api_key_env"), "vllm.api_key_env"),
        "hf_token_env": _text(raw.get("hf_token_env"), "hf_token_env") or "HF_TOKEN",
        "trust_remote_code": bool(vllm.get("trust_remote_code", False)),
        "extra_args": list(extra_args),
    }


def _section(raw: dict[str, Any], key: str) -> dict[str, Any]:
    value = raw.get(key) or {}
    if not isinstance(value, dict):
        raise ManifestError(f"`{key}` must be a mapping.")
    return value


def _text(value: Any, label: str) -> str:
    if value is None:
        return ""
    if not isinstance(value, str):
        raise ManifestError(f"`{label}` must be a string.")
    return value.strip()


def _int(value: Any, label: str, *, minimum: int, maximum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ManifestError(f"`{label}` must be an integer.")
    if value < minimum or (maximum is not None and value > maximum):
        bounds = f">= {minimum}" if maximum is None else f"{minimum}..{maximum}"
        raise ManifestError(f"`{label}` must be {bounds}.")
    return value


def _float(value: Any, label: str, *, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ManifestError(f"`{label}` must be a number.")
    number = float(value)
    if number < minimum or number > maximum:
        raise ManifestError(f"`{label}` must be between {minimum} and {maximum}.")
    return number


def _check_instance_name(name: str) -> None:
    if len(name) > 40 or not name or any(char not in _NAME_CHARS for char in name):
        raise ManifestError(
            "`name` is the JarvisLabs instance name: 1-40 characters, "
            "letters, numbers, spaces, hyphens, and underscores."
        )
