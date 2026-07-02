"""Runtime settings for the Streamlit app."""

from __future__ import annotations

import os
from dataclasses import dataclass

from app.manifest import ManifestError, load_manifest


@dataclass(frozen=True)
class Settings:
    title: str
    model: str
    vllm_base_url: str
    vllm_api_key: str


def load_settings() -> Settings:
    try:
        manifest = load_manifest()
    except ManifestError:
        manifest = {
            "title": "LLM Chat",
            "model": "Qwen/Qwen2.5-7B-Instruct",
            "vllm_host": "127.0.0.1",
            "vllm_port": 8000,
            "api_key_env": "VLLM_API_KEY",
        }

    model = os.environ.get("MODEL_ID", manifest["model"])
    base_url = os.environ.get("VLLM_BASE_URL")
    if not base_url:
        base_url = f"http://{manifest['vllm_host']}:{manifest['vllm_port']}/v1"

    api_key_env = manifest.get("api_key_env") or "VLLM_API_KEY"
    api_key = os.environ.get(api_key_env) or os.environ.get("VLLM_API_KEY") or "not-needed"

    return Settings(
        title=os.environ.get("APP_TITLE", manifest["title"]),
        model=model,
        vllm_base_url=base_url.rstrip("/"),
        vllm_api_key=api_key,
    )
