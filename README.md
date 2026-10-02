# LLM deployment

Chat with an open model. vLLM runs on a JarvisLabs GPU VM. The Streamlit page runs on an Azure VM.

Model, GPU, and context length are in [`manifest.yaml`](manifest.yaml).

## How it fits together

![Laptop, Azure control plane, and JarvisLabs GPU node](docs/architecture.png)

## Start and stop

The GPU bills while it is running. Resume it when you want to chat, and pause it when you stop.

```bash
bash scripts/gpu-resume.sh
```

Open `http://<azure-public-ip>:30066`. Allow TCP 30066 from your IP in the Azure network security group. The sidebar turns green when vLLM is ready. After a pause, that takes a few minutes.

```bash
bash scripts/gpu-pause.sh
```

Pause stops compute billing and keeps the disk, so the model stays downloaded. `jarvis-gpu` shows NotReady until you resume. The Azure VM stays up, and the page loads again after resume.

`jl resume` can print a new machine id. Write that id into `.k8s-gpu-state`. On the GPU VM, set the hostname back to `jarvis-gpu` if it came up as `jl-vm-<id>`, then restart kubelet. With WireGuard, also point Azure's peer at the GPU VM's new public IP. Those steps are in [docs/K8S.md](docs/K8S.md).

Delete the GPU VM and its disk:

```bash
bash scripts/gpu-destroy.sh
```

Pause and resume need the JarvisLabs CLI (`pip install -r requirements-operator.txt`, then `jl setup` or `JL_API_KEY`). They use the machine id in `.k8s-gpu-state`.

## kubectl

From this repo, on your laptop:

```bash
bash scripts/k8s-access.sh
kubectl get nodes
kubectl -n llm get pods
kubectl -n llm logs -f deploy/vllm
```

`scripts/k8s-access.sh` reads `.k8s-cp-state` and opens an SSH tunnel to the API on `127.0.0.1:16443`. If `kubectl` says that connection was refused, run `bash scripts/k8s-access.sh` again.

`kubectl get nodes -o wide` shows the address the cluster is using in `INTERNAL-IP`. `10.200.0.1` and `10.200.0.2` are WireGuard. A NetBird or Tailscale address is the one on `wt0` or `tailscale0`. The cluster address is kubelet's `--node-ip`. On each VM, `grep node-ip /etc/default/kubelet` prints it. `sudo netbird status` reports the NetBird tunnel on its own.

## Change the model

Edit `model` in `manifest.yaml`. For a gated Hugging Face model, copy `.env.example` to `.env` and set `HF_TOKEN`.

```bash
export UI_IMAGE=llm-deployment-ui:latest
bash scripts/k8s-apply.sh
```

`UI_IMAGE` is the Streamlit image the cluster can run. vLLM uses the public `vllm/vllm-openai` image and is scheduled only on the GPU node.

## Call the API

Inside the cluster the OpenAI-compatible API is `http://vllm.llm.svc.cluster.local:8000/v1`.

```bash
kubectl -n llm port-forward svc/vllm 8000:8000
VLLM_BASE_URL=http://127.0.0.1:8000/v1 python examples/chat.py "Hello"
```

## Set up from scratch

You need an Azure Ubuntu VM (2 vCPUs, 8 GB RAM, a public IP, SSH as `azureuser`) and a JarvisLabs account. On the laptop:

```bash
pip install -r requirements-operator.txt
jl setup
jl ssh-key add ~/.ssh/id_ed25519.pub --name laptop
```

`jl gpus` shows which GPUs are free. Set `jarvislabs.gpu` in `manifest.yaml`. The GPU machine must be a VM (`jl create --vm`) with at least 100 GB of disk. A JarvisLabs template container cannot run kubelet.

### 1. WireGuard

Kubernetes uses a private network, because the Azure public IP is a NAT address and is not on the VM's NIC.

Install WireGuard on both VMs (`sudo apt-get install -y wireguard`). Azure is `10.200.0.1`. The GPU VM is `10.200.0.2`. Both listen on UDP `51820`. In the Azure network security group, allow that UDP port from the GPU VM's public IP.

On each VM, `wg genkey | tee /tmp/wg.key | wg pubkey` prints the public key. Azure's `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <azure-private-key>

[Peer]
PublicKey = <gpu-public-key>
AllowedIPs = 10.200.0.2/32
Endpoint = <gpu-public-ip>:51820
PersistentKeepalive = 25
```

On the GPU VM, swap the addresses: `10.200.0.2/24`, the Azure public key, `AllowedIPs = 10.200.0.1/32`, and `Endpoint = <azure-public-ip>:51820`.

```bash
sudo systemctl enable --now wg-quick@wg0
```

From the GPU VM, `ping -c 3 10.200.0.1` should succeed. Delete `/tmp/wg.key` after the config is in place.

WireGuard is the default. Tailscale and NetBird are optional. Use one mesh for both VMs, and choose it before `kubeadm init`. Tailscale and NetBird setup, including the GPU node, is in [docs/K8S.md](docs/K8S.md).

### 2. Control plane

Copy this repo to the Azure VM and run:

```bash
sudo env CLUSTER_NODE_IP=10.200.0.1 CLUSTER_IFACE=wg0 \
  bash k8s/scripts/bootstrap-control-plane.sh
```

The script installs containerd and Kubernetes 1.37, runs `kubeadm init`, and installs Flannel, a local-path volume provisioner, and the NVIDIA device plugin. The plugin stays pending until the GPU node exists. Keep the `kubeadm join` command it prints.

On the laptop, create `.k8s-cp-state` (this file is gitignored):

```
AZURE_SSH=azureuser@<azure-public-ip>
CLUSTER_API=10.200.0.1:6443
```

```bash
bash scripts/k8s-access.sh
kubectl get nodes
```

### 3. GPU node

Create the VM and record its id:

```bash
jl create --vm --gpu <type-from-jl-gpus> --num-gpus 1 --storage 100 --name k8s-gpu
```

Write `.k8s-gpu-state` with `MACHINE_ID=<id printed by jl>`. Copy this repo to the VM and write `join.env` in the repo root:

```
JOIN_COMMAND='kubeadm join 10.200.0.1:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>'
```

On the GPU VM:

```bash
sudo env CLUSTER_NODE_IP=10.200.0.2 CLUSTER_IFACE=wg0 \
  bash k8s/scripts/bootstrap-gpu-node.sh
```

The node joins as `jarvis-gpu` with the label `gpu.jarvislabs.ai/node=true`.

```bash
kubectl get nodes
kubectl get node jarvis-gpu -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

`1` means the device plugin sees the GPU.

### 4. vLLM and Streamlit

Build the UI image on an amd64 machine (the GPU VM is fine) and load it into containerd on both nodes:

```bash
sudo podman build -t docker.io/library/llm-deployment-ui:latest -f docker/Dockerfile .
sudo podman save docker.io/library/llm-deployment-ui:latest | sudo ctr -n k8s.io images import -
```

From the laptop, with `kubectl` pointed at the cluster:

```bash
export UI_IMAGE=llm-deployment-ui:latest
bash scripts/k8s-apply.sh
```

For a gated model, copy `.env.example` to `.env` and set `HF_TOKEN` before that command. Allow TCP `30066` from your IP, then open `http://<azure-public-ip>:30066`. The first start downloads the model onto the GPU node's disk.

More detail is in [docs/K8S.md](docs/K8S.md), including Tailscale and NetBird. `scripts/add-gpu-node.sh` joins the GPU VM over whichever of those two the control plane already uses. To run vLLM and Streamlit on a single JarvisLabs machine, use [docs/GUIDE.md](docs/GUIDE.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
