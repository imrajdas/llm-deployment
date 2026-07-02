# Operator guide

The cluster path is an Azure VM running kubeadm, plus a JarvisLabs GPU VM joined as the worker. Follow [docs/K8S.md](K8S.md) for that setup.

The rest of this page is the single-machine path: one JarvisLabs instance runs vLLM and Streamlit without Kubernetes.

This repo deploys a chat app on [JarvisLabs](https://jarvislabs.ai/):

- **vLLM** serves an open-weight model with an OpenAI-compatible HTTP API.
- **Streamlit** is the browser UI and calls that API on localhost.
- **`manifest.yaml`** is the config other people should edit.
- **`scripts/`** creates the GPU, uploads the code, and starts or stops the processes.

Read [the README](../README.md) for the short path. This page is the rest: accounts, GPU choice, day-2 commands, the VM path, and failures you are likely to hit.

## Before you start

1. Create a JarvisLabs account and add credit. `jl gpus` shows the hourly price of each GPU before you launch.
2. Create an API token at [jarvislabs.ai settings / API keys](https://jarvislabs.ai/settings/api-keys).
3. On your laptop (macOS or Linux, Python 3.10+):

```bash
pip install -r requirements-operator.txt
jl setup
```

`jl setup` stores the token for the `jl` CLI and the `jarvislabs` Python SDK. You can also set `JL_API_KEY` in the environment.

4. Add an SSH key if you want a shell on the instance. The dashboard and `jl ssh-key add` both do this. `scripts/launch.sh` itself uses `jl upload` and `jl exec`, so a key is optional for the happy path.
5. Copy the env file. Leave the token blank unless the model is gated.

```bash
cp .env.example .env
```

`.env` is a list of `KEY=value` lines. The scripts source it. Keep tokens there and out of git.

## Pick a model and a GPU

Edit `manifest.yaml`. The default is `Qwen/Qwen2.5-7B-Instruct` on one A100, with an 8192-token context. That model is public, so it does not need a Hugging Face token.

Weights below are approximate bf16 sizes. vLLM also needs memory for the KV cache, which grows with `vllm.max_model_len` and with concurrent requests. Run `jl gpus` and pick a type that has free devices.

| Model | Approx. weights | GPU to try | Notes |
| --- | --- | --- | --- |
| `Qwen/Qwen2.5-3B-Instruct` | 6 GB | L4 | Cheapest comfortable fit |
| `Qwen/Qwen2.5-7B-Instruct` | 15 GB | A100 | Default. An L4 can work if you set `max_model_len` to 4096 |
| `Qwen/Qwen2.5-14B-Instruct` | 28 GB | A100 | Tight on a 40 GB card if the context is long |
| `Qwen/Qwen2.5-32B-Instruct` | 65 GB | A100-80GB or H100 | |
| `meta-llama/Llama-3.1-8B-Instruct` | 16 GB | A100 | Accept the license on Hugging Face and set `HF_TOKEN` |

Regions matter:

| Region | GPUs for new instances |
| --- | --- |
| `IN2` | L4, A100, A100-80GB |
| `EU1` | H100, H200. 1 or 8 GPUs only, and storage is raised to at least 100 GB |

Leave `jarvislabs.region` empty. The CLI routes the GPU to a region that has it. Pin `IN2` or `EU1` only when you need a specific site.

`jarvislabs.storage_gb` holds the model cache, the vLLM install, and the virtualenv. 100 GB is the default because a CUDA wheel plus a 7B model is larger than the platform's 40 GB default disk.

Set `jarvislabs.num_gpus` above 1 to shard the model. The serve script passes that value as `--tensor-parallel-size`. On EU1 the only multi-GPU choice is 8.

Other fields you will actually change:

- `vllm.max_model_len` — lower it when vLLM dies while profiling GPU memory.
- `vllm.gpu_memory_utilization` — fraction of the GPU reserved for weights and cache. `0.90` leaves a little headroom.
- `vllm.extra_args` — extra `vllm serve` tokens, such as `--quantization` / `awq`.
- `vllm.trust_remote_code` — set `true` only for models that require custom Hugging Face code.
- `ports.ui` — keep `6006` on template instances. That is the port JarvisLabs maps to the dashboard API button.
- `vllm.host` — `127.0.0.1` keeps the raw API off the public endpoint.

`name` is the instance name. JarvisLabs allows 1–40 characters: letters, numbers, spaces, hyphens, underscores.

Check the file before spending money:

```bash
python3 scripts/manifest_env.py --check
```

## Deploy

From the repo root:

```bash
bash scripts/launch.sh
```

What that does:

1. Reads `manifest.yaml`.
2. Runs `jl create` and waits until the instance is running. Confirm the prompt unless you exported `LAUNCH_YES=1`.
3. Writes the machine id to `.deploy-state` (gitignored).
4. Uploads this repo to `/home/llm-deployment` on the instance. `.git`, `.venv`, logs, and caches stay behind. `.env` is copied if it exists, mode `600`.
5. Starts `scripts/serve.sh` in the background.
6. Polls until vLLM's `/health` and Streamlit's `/_stcore/health` both answer, up to about 40 minutes.

`scripts/serve.sh` on the instance:

1. Creates `/home/llm-deployment/.venv` so packages survive pause. Installs outside `/home` disappear on pause.
2. Installs `requirements.txt` and `requirements-vllm.txt` when `vllm` or Streamlit is missing.
3. Downloads the model into `/home/llm-deployment/.cache/huggingface`.
4. Starts `vllm serve` on `127.0.0.1:8000`.
5. Replaces itself with Streamlit on `0.0.0.0:6006`.

Open the app from the dashboard: instance menu, **API**. The URL is the Streamlit process.

Anyone who has that URL can send prompts and consume GPU time. Treat the URL as private, and pause the instance when you are done.

## Use the app

The sidebar shows whether vLLM is healthy, the model id, the system prompt, temperature, and max tokens. The first reply waits until the status line says vLLM is ready. A red status during the first boot is normal; the weights are still downloading.

Clear the transcript with **Clear chat**. That only clears the browser session.

### Call vLLM directly

The UI is the supported public surface. The API is on localhost so you can still use it from a shell on the box, or through an SSH tunnel.

```bash
bash scripts/status.sh
# use the printed ssh command, and add a local forward:
ssh -L 8000:127.0.0.1:8000 <the rest of the ssh command>
```

In another terminal:

```bash
pip install openai
VLLM_BASE_URL=http://127.0.0.1:8000/v1 python examples/chat.py "Write a haiku about GPUs."
```

`examples/chat.py` uses the official OpenAI SDK. `VLLM_API_KEY` defaults to a dummy value because local vLLM ignores it unless you set a real key.

To require a key, put one in `.env`:

```bash
VLLM_API_KEY=choose-a-long-secret
```

Redeploy with `scripts/resume.sh`. The serve script passes `--api-key` and Streamlit sends the same value. This locks the localhost API. It does not password-protect the Streamlit page.

### Publish the raw API

Change `vllm.host` to `0.0.0.0` and, when you create the instance, expose port 8000. The launch script reads `ports.vllm` but it does not add extra public ports for you. Create the instance with an extra port only if you want that exposure:

```bash
jl create --gpu A100 --http-ports 8000 ...
```

Prefer the SSH tunnel when the API only needs to be reachable from your laptop.

## Day to day

| Command | Effect |
| --- | --- |
| `bash scripts/status.sh` | `jl get` for the saved machine id |
| `bash scripts/logs.sh` | Follow `logs/vllm.log` and `logs/serve.log` |
| `bash scripts/pause.sh` | Stop the GPU. Disk contents remain. Compute billing stops |
| `bash scripts/resume.sh` | Resume, upload this checkout, restart vLLM and Streamlit |
| `bash scripts/stop.sh` | Stop the processes and leave the instance running |
| `bash scripts/destroy.sh` | Delete the instance and everything on its disk |
| `make check` | Validate the manifest, compile the Python, and syntax-check the shell |

Pass a machine id when `.deploy-state` is missing:

```bash
bash scripts/pause.sh 12345
```

Resume can issue a new machine id. `scripts/resume.sh` writes the new id into `.deploy-state` when `jl` returns one. Later commands use that file.

Pause when you leave. Destroy when you do not need the downloaded weights anymore. Destroy is irreversible.

### Change the model

Edit `model` (and usually `jarvislabs.gpu` or `vllm.max_model_len`) in `manifest.yaml`, then:

```bash
bash scripts/resume.sh
```

The old weights stay in the Hugging Face cache until you delete `.cache/huggingface` on the instance or destroy it.

Force a clean virtualenv install:

```bash
# on the instance
SERVE_REINSTALL=1 bash scripts/serve.sh
```

From the laptop, the same flag can be exported in the remote command. Deleting `/home/llm-deployment/.venv` and running `scripts/resume.sh` is the straightforward version.

### Start the app on dashboard Resume

JarvisLabs can run one startup script every time an instance boots. Register the one in this repo:

```bash
bash scripts/register-startup.sh
```

The command prints a numeric id. Set `jarvislabs.startup_script_id` in `manifest.yaml` to that id. The next `scripts/launch.sh` passes it to `jl create`. An account holds at most three startup scripts.

The startup script no-ops until `/home/llm-deployment/scripts/serve.sh` exists, then it starts the app. `scripts/serve.sh` uses a lock and returns immediately when both ports are already healthy, so a second start does not launch two copies.

`scripts/resume.sh` does not depend on that script. It stops and starts the processes itself after uploading.

## VM and Docker

Use this path when you want containers. Template instances cannot run Docker.

1. In `manifest.yaml`, set `jarvislabs.template` to `vm`. VM storage is at least 100 GB. Register an SSH key first (`jl ssh-key add`).
2. `bash scripts/launch.sh` still uploads the repo and can start the native `scripts/serve.sh` path. For containers, SSH in and use compose instead:

```bash
jl ssh <machine_id>
cd /home/llm-deployment
bash scripts/vm-up.sh
sudo ufw allow 6006/tcp
```

`scripts/vm-up.sh` writes `docker/.env` from the manifest and runs `docker compose up -d --build` in `docker/`.

- The vLLM service is the official `vllm/vllm-openai` image plus `docker/vllm-entrypoint.sh`.
- It is attached to the GPU (`--gpus` via the compose device reservation) and a 16 GB shared-memory size.
- It has no published host port. Only the Streamlit container is published, on the manifest UI port (default 6006).
- Weights sit in a compose volume named `huggingface`.

A VM is reachable on its public IP. `jl get` and the dashboard show that address. Open `http://<public-ip>:6006`.

If compose cannot see the GPU, the NVIDIA container toolkit is missing or the daemon needs a restart. The same server can be started without compose:

```bash
sg docker -c "docker run -d --gpus all --name vllm --shm-size 16g \
  -v hf:/root/.cache/huggingface \
  vllm/vllm-openai:latest \
  --model Qwen/Qwen2.5-7B-Instruct --host 0.0.0.0 --port 8000"
```

Then run Streamlit from the virtualenv with `VLLM_BASE_URL=http://127.0.0.1:8000/v1`.

## Troubleshooting

**`manifest.yaml: ...`**
`python3 scripts/manifest_env.py --check` prints the field that failed. Instance names and the EU1 GPU count are the usual ones.

**`Install the JarvisLabs CLI`**
`pip install -r requirements-operator.txt` and `jl setup`.

**Launch sits on "Still starting"**
First boot is slow. In another terminal, `bash scripts/logs.sh`. `logs/vllm.log` is the model load. `logs/serve.log` is pip output and Streamlit. The instance is billing the whole time. If you need to stop and think, `bash scripts/pause.sh`.

**vLLM exits during GPU memory profiling**
Lower `vllm.max_model_len`, or move to a larger GPU, or set a smaller model. Then `bash scripts/resume.sh`.

**`401` or "access denied" while downloading**
The model is gated. Create a Hugging Face token, accept the model license on the model page, put `HF_TOKEN=...` in `.env`, and resume.

**Less than 30 GB free**
Raise `jarvislabs.storage_gb`. Storage can be increased on resume (`jl resume <id> --storage 200`); it cannot be shrunk.

**The API button shows a blank page or a connection error**
Streamlit must listen on `0.0.0.0:6006`. Confirm with `bash scripts/logs.sh` and, on the instance, `bash scripts/healthcheck.sh`. `.streamlit/config.toml` turns off CORS, XSRF, and websocket compression so the dashboard proxy can carry the Streamlit websocket.

**`serve.sh is already running`**
A previous start still holds `logs/serve.lock`. `bash scripts/stop.sh` clears it. Resume does that before it starts again.

**Dashboard Resume does not bring the chat back**
Processes die across pause. Register the startup script, or always resume with `bash scripts/resume.sh`.

**Docker build or `docker compose` fails on a template instance**
That instance is a container. Switch `jarvislabs.template` to `vm`, or keep using `scripts/serve.sh`, which does not need Docker.

## Security

- `.env` is gitignored. `scripts/launch.sh` uploads it to the instance when the file exists.
- vLLM binds to `127.0.0.1` unless you change `vllm.host`.
- The Streamlit port is the public one. Pause the instance to take the app offline.
- `VLLM_API_KEY` protects the OpenAI API only.
- Startup scripts and `scripts/serve.sh` run as root on template instances. Review changes before you launch them on a shared account.

## Further reading

- [JarvisLabs CLI](https://docs.jarvislabs.ai/cli/)
- [Serving LLMs on JarvisLabs](https://docs.jarvislabs.ai/tutorials/getting-started/serving-llms)
- [Streamlit on JarvisLabs](https://docs.jarvislabs.ai/deploy/streamlit)
- [JarvisLabs VMs](https://docs.jarvislabs.ai/vm/)
- [vLLM OpenAI-compatible server](https://docs.vllm.ai/)
