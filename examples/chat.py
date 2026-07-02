"""Call a running vLLM server with the OpenAI SDK.

On the instance:

    python examples/chat.py "Explain paged attention in two sentences."

From a laptop, after forwarding port 8000:

    ssh -L 8000:127.0.0.1:8000 <ssh command from `jl ssh ID --print-command`>
    VLLM_BASE_URL=http://127.0.0.1:8000/v1 python examples/chat.py "Hello"
"""

from __future__ import annotations

import os
import sys

from openai import OpenAI


def main() -> int:
    prompt = " ".join(sys.argv[1:]).strip() or "Say hello in one sentence."
    model = os.environ.get("MODEL_ID", "Qwen/Qwen2.5-7B-Instruct")
    base_url = os.environ.get("VLLM_BASE_URL", "http://127.0.0.1:8000/v1")
    api_key = os.environ.get("VLLM_API_KEY", "not-needed")

    client = OpenAI(base_url=base_url, api_key=api_key)
    stream = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        max_tokens=300,
        stream=True,
    )
    for chunk in stream:
        if not chunk.choices:
            continue
        text = chunk.choices[0].delta.content or ""
        if text:
            print(text, end="", flush=True)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
