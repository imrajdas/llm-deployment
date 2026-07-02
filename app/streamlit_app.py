"""Chat UI in front of a local vLLM server."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import httpx
import streamlit as st
from openai import OpenAI

from app.settings import load_settings

settings = load_settings()
client = OpenAI(base_url=settings.vllm_base_url, api_key=settings.vllm_api_key)


def _health_root(base_url: str) -> str:
    if base_url.endswith("/v1"):
        return base_url[: -len("/v1")]
    return base_url


def server_status() -> tuple[bool, str]:
    root = _health_root(settings.vllm_base_url)
    try:
        response = httpx.get(f"{root}/health", timeout=2.0)
        response.raise_for_status()
    except Exception as exc:  # noqa: BLE001 - show the connection error in the UI
        return False, f"vLLM is not reachable at `{root}` ({exc.__class__.__name__})."
    return True, "vLLM is ready."


st.set_page_config(page_title=settings.title, page_icon=":speech_balloon:", layout="centered")
st.title(settings.title)
st.caption("Chat runs against vLLM on this machine. Prompts stay on the GPU instance.")

ready, status_text = server_status()

with st.sidebar:
    st.subheader("Server")
    if ready:
        st.success(status_text)
    else:
        st.error(status_text)
        st.markdown(
            "On the instance, read `logs/vllm.log`. "
            "The first boot installs vLLM and downloads the model before this turns green."
        )
    st.text_input("Model", value=settings.model, disabled=True)
    st.caption(settings.vllm_base_url)
    system_prompt = st.text_area("System prompt", value="You are a helpful assistant.", height=100)
    temperature = st.slider("Temperature", min_value=0.0, max_value=1.5, value=0.7, step=0.1)
    max_tokens = st.slider("Max tokens", min_value=64, max_value=2048, value=512, step=64)
    if st.button("Clear chat"):
        st.session_state.messages = []
        st.rerun()

if "messages" not in st.session_state:
    st.session_state.messages = []

for message in st.session_state.messages:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])

prompt = st.chat_input("Message" if ready else "vLLM is still starting")
if prompt:
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    request_messages = [{"role": "system", "content": system_prompt}]
    request_messages.extend(st.session_state.messages)

    with st.chat_message("assistant"):
        try:
            stream = client.chat.completions.create(
                model=settings.model,
                messages=request_messages,
                temperature=temperature,
                max_tokens=max_tokens,
                stream=True,
            )

            def tokens():
                for chunk in stream:
                    if not chunk.choices:
                        continue
                    text = chunk.choices[0].delta.content or ""
                    if text:
                        yield text

            answer = st.write_stream(tokens)
        except Exception as exc:  # noqa: BLE001 - surface API failures in the chat
            answer = ""
            st.error(f"Request failed: {exc}")

    if answer:
        st.session_state.messages.append({"role": "assistant", "content": answer})
