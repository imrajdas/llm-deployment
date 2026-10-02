# Kubernetes on Azure, GPU node on JarvisLabs

From-scratch commands are in the README, under **Set up from scratch**. That path puts both machines on WireGuard: Azure is `10.200.0.1`, the GPU VM is `10.200.0.2`, and kubeadm advertises those addresses.

The control plane is one Azure VM, installed with kubeadm. The GPU worker is a JarvisLabs VM created with `jl create --vm`. vLLM runs only on that worker. Streamlit prefers the Azure node.

JarvisLabs template instances are containers. They cannot join a cluster. The GPU machine has to be a [VM](https://jarvislabs.ai/products/vm): root access, a public IP, and the NVIDIA driver already installed.

## Why Tailscale sits between them

An Azure VM's public IP is a NAT address. It is not configured on the NIC, so kubelet cannot advertise it as the node IP. A JarvisLabs VM has a real public address on `eth0`, and that address can change after a pause unless you reserve it. Pod traffic still has to flow both ways.

Put the laptop, the Azure VM, and the GPU VM on one Tailscale network. kubeadm advertises the Tailscale IPv4 addresses. Flannel's VXLAN uses `tailscale0`, with MTU 1230 so packets fit inside Tailscale's 1280-byte tunnel.

You do not open the Kubernetes API to the public internet. Tailscale carries:

| Port | Direction | Purpose |
| --- | --- | --- |
| TCP 6443 | GPU node to Azure | API server |
| TCP 10250 | Azure to GPU node | kubelet |
| UDP 8472 | both ways | Flannel VXLAN |

## What you need

- An Azure subscription and an Ubuntu 24.04 VM: 2 vCPUs, 8 GB RAM, a public IP, SSH from your IP.
- A JarvisLabs account, `jl setup`, and an SSH public key registered with `jl ssh-key add`.
- A Tailscale account and a reusable, pre-authorized auth key.
- `manifest.yaml` set to the GPU you want. `jl gpus` shows what is free. VMs need at least 100 GB of disk. H100 and H200 are in EU1 and accept 1 or 8 GPUs.

Passwordless sudo is required for `azureuser` on the Azure VM and for the default user on the JarvisLabs VM.

## 1. Azure control plane

Create the VM, then SSH to its public IP once.

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up
tailscale ip -4
```

Install Tailscale on your laptop as well, and confirm you can SSH to that Tailscale address:

```bash
ssh azureuser@<tailscale-ip>
```

On the Azure VM:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone <this-repo> llm-deployment
cd llm-deployment
sudo bash k8s/scripts/bootstrap-control-plane.sh
```

The script installs containerd and Kubernetes v1.37, runs `kubeadm init`, installs Flannel and a local-path volume provisioner, and applies the NVIDIA device plugin. The plugin stays pending until the GPU node exists. The script sets the hostname to `k8s-cp`.

Copy the Tailscale address. The laptop uses it as `AZURE_SSH`.

## 2. JarvisLabs GPU worker

On the laptop:

```bash
pip install -r requirements-operator.txt
jl setup
jl ssh-key add ~/.ssh/id_ed25519.pub --name laptop
export TAILSCALE_AUTHKEY=tskey-auth-...
export AZURE_SSH=azureuser@<tailscale-ip>
bash scripts/add-gpu-node.sh
```

`jl` asks you to confirm the VM. The script then:

1. Creates a VM with `jl create --vm` from `manifest.yaml` (name `k8s-gpu`).
2. Reads a fresh `kubeadm join` command from the Azure VM.
3. Installs Tailscale, containerd, kubeadm, and the NVIDIA container toolkit on the VM.
4. Joins the node as `jarvis-gpu` and labels it `gpu.jarvislabs.ai/node=true`.

Check from the Azure VM:

```bash
sudo kubectl get nodes -o wide
sudo kubectl describe node jarvis-gpu | grep nvidia.com/gpu
```

`nvidia.com/gpu` appears in Allocatable after the device plugin starts. That can take a minute after the node is Ready.

## 3. Deploy vLLM and Streamlit

Build the UI image and push it somewhere both nodes can pull. vLLM uses the public `vllm/vllm-openai` image.

```bash
docker build -f docker/Dockerfile -t ghcr.io/you/llm-chat-ui:latest .
docker push ghcr.io/you/llm-chat-ui:latest
```

On the Azure VM, in the repo:

```bash
export UI_IMAGE=ghcr.io/you/llm-chat-ui:latest
# optional, for a gated model
cp .env.example .env   # set HF_TOKEN
bash scripts/k8s-apply.sh
```

`scripts/k8s-apply.sh` reads `manifest.yaml`, requests that many GPUs, and applies `k8s/`. vLLM is pinned to `jarvis-gpu` with `runtimeClassName: nvidia`. Streamlit prefers the control-plane node and calls `http://vllm.llm.svc.cluster.local:8000/v1`.

The model download is the slow part:

```bash
sudo kubectl -n llm get pods
sudo kubectl -n llm logs -f deploy/vllm
```

Weights land on a persistent volume on the GPU node, created by the local-path provisioner.

## 4. Open the chat page

The Streamlit Service is a NodePort on **30066**. Allow that TCP port from your IP in the Azure network security group, then open:

```text
http://<azure-public-ip>:30066
```

Or, with no security-group change, from the Azure VM:

```bash
sudo kubectl -n llm port-forward svc/streamlit 6006:80
```

and an SSH tunnel from the laptop: `ssh -L 6006:127.0.0.1:6006 azureuser@<azure-public-ip>`.

`k8s/ingress.yaml` is an optional ingress-nginx rule. It is not applied by default. Edit the host, install a controller, then `kubectl apply -f k8s/ingress.yaml`. The annotations keep the Streamlit websocket open.

## Day to day

| Command | Where | Effect |
| --- | --- | --- |
| `bash scripts/gpu-pause.sh` | laptop | Pause the GPU VM. `jarvis-gpu` becomes NotReady. Compute billing stops |
| `bash scripts/gpu-resume.sh` | laptop | Resume the VM. Tailscale and kubelet start with the OS |
| `bash scripts/gpu-destroy.sh` | laptop | Delete the VM and `kubectl delete node jarvis-gpu` when `AZURE_SSH` is set |
| `bash scripts/k8s-apply.sh` | Azure VM | Re-apply after a `manifest.yaml` or image change |

Pause keeps the disk, including the Hugging Face cache. Resume does not re-run `kubeadm join`. Destroy deletes that disk.

A JarvisLabs public IP can change across pause and resume. The cluster does not use that address. It uses the Tailscale address recorded at join time, which stays with the node.

Changing `model` or `vllm.max_model_len` in `manifest.yaml` needs another `scripts/k8s-apply.sh`. The vLLM Deployment uses `Recreate`, so the old pod is removed before the new one asks for the GPU.

## Troubleshooting

**`kubeadm init` cannot find a container runtime**
The control-plane script writes `/etc/containerd/config.toml` and enables containerd. Re-run it only on a machine that does not already have `/etc/kubernetes/admin.conf`.

**GPU node stays NotReady**
On the GPU VM, `tailscale ip -4` must return an address, and `systemctl status kubelet` should be active. From Azure, `sudo kubectl describe node jarvis-gpu`. Flannel must be using `tailscale0`. If pod CIDR traffic dies silently, the Flannel MTU was not set to 1230; re-run is not automatic once `admin.conf` exists, so patch the `kube-flannel-cfg` ConfigMap and restart the Flannel DaemonSet.

**`nvidia.com/gpu` is missing**
On the GPU VM, `nvidia-smi` and `nvidia-ctk runtime configure --runtime=containerd --set-as-default` must have succeeded. Then `sudo kubectl -n kube-system logs -l name=nvidia-device-plugin-ds` (the label varies by plugin version). The DaemonSet is selected onto `gpu.jarvislabs.ai/node=true`.

**vLLM pending**
The node label or the GPU resource is missing, or `jarvislabs.num_gpus` asks for more GPUs than the VM has. The Deployment requests that count.

**ImagePullBackOff on Streamlit**
`UI_IMAGE` must be a registry the Azure node can pull. `llm-deployment-ui:latest` is only a placeholder inside the manifest.

**Streamlit loads and then the socket drops**
Use the NodePort or port-forward path above. An ingress in front of Streamlit needs the long proxy timeouts in `k8s/ingress.yaml`.
