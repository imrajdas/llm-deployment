"""Manifest loader checks. Run: python3 tests/test_manifest.py"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.manifest import ManifestError, load_manifest  # noqa: E402


def expect_error(text: str, fragment: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "manifest.yaml"
        path.write_text(text, encoding="utf-8")
        try:
            load_manifest(path, require_gpu=True)
        except ManifestError as exc:
            if fragment not in str(exc):
                raise SystemExit(f"expected {fragment!r} in {exc}") from exc
            return
    raise SystemExit(f"expected ManifestError containing {fragment!r}")


def main() -> int:
    manifest = load_manifest(require_gpu=True)
    assert manifest["model"] == "Qwen/Qwen2.5-7B-Instruct"
    assert manifest["gpu"] == "A100"
    assert manifest["ui_port"] == 6006
    assert manifest["vllm_host"] == "127.0.0.1"
    assert manifest["num_gpus"] == 1
    assert manifest["extra_args"] == []
    assert manifest["trust_remote_code"] is False

    expect_error("name: 'bad name!'\nmodel: Qwen/Qwen2.5-7B-Instruct\njarvislabs:\n  gpu: A100\n", "instance name")
    expect_error("name: llm-chat\nmodel: ''\njarvislabs:\n  gpu: A100\n", "model")
    expect_error(
        "name: llm-chat\nmodel: Qwen/Qwen2.5-7B-Instruct\njarvislabs:\n  gpu: H100\n  region: IN1\n",
        "region",
    )
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
