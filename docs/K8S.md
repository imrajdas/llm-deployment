# Kubernetes on Azure, GPU node on JarvisLabs

From-scratch commands are in the README, under **Set up from scratch**. That path puts both machines on WireGuard: Azure is `10.200.0.1`, the GPU VM is `10.200.0.2`, and kubeadm advertises those addresses.

The control plane is one Azure VM, installed with kubeadm. The GPU worker is a JarvisLabs VM created with `jl create --vm`. vLLM runs only on that worker. Streamlit prefers the Azure node.

JarvisLabs template instances are containers. They cannot join a cluster. The GPU machine has to be a [VM](https://jarvislabs.ai/products/vm): root access, a public IP, and the NVIDIA driver already installed.

## Why a private mesh sits between them

An Azure VM's public IP is a NAT address. It is not configured on the NIC, so kubelet cannot advertise it as the node IP. A JarvisLabs VM has a real public address on `eth0`, and that address can change after a pause unless you reserve it. Pod traffic still has to flow both ways.

The README uses a WireGuard tunnel (`wg0`, Azure `10.200.0.1`, GPU VM `10.200.0.2`). Tailscale and NetBird are optional substitutes. Pick one before `kubeadm init`. The GPU node has to join on the same mesh the API was advertised on.

| Mesh | Interface | How to select it |
| --- | --- | --- |
| WireGuard | `wg0` | `CLUSTER_NODE_IP` and `CLUSTER_IFACE=wg0` (README) |
| Tailscale | `tailscale0` | `sudo tailscale up`, then the scripts below |
| NetBird | `wt0` | `CLUSTER_MESH=netbird` or `NETBIRD_SETUP_KEY` |

kubeadm advertises that mesh IPv4 address. Flannel's VXLAN uses the mesh interface, with MTU 1230 so packets fit inside a 1280-byte Tailscale or NetBird tunnel.

You do not open the Kubernetes API to the public internet. The mesh carries:

| Port | Direction | Purpose |
| --- | --- | --- |
| TCP 6443 | GPU node to Azure | API server |
| TCP 10250 | Azure to GPU node | kubelet |
| UDP 8472 | both ways | Flannel VXLAN |

## What you need

- An Azure subscription and an Ubuntu 22.04 or 24.04 VM: 2 vCPUs, 8 GB RAM, a public IP, SSH from your IP.
- A JarvisLabs account, `jl setup`, and an SSH public key registered with `jl ssh-key add`.
- A Tailscale account and a reusable, pre-authorized auth key, or a NetBird account and a reusable setup key. WireGuard needs neither.
- `manifest.yaml` set to the GPU you want. `jl gpus` shows what is free. VMs need at least 100 GB of disk. H100 and H200 are in EU1 and accept 1 or 8 GPUs.

Passwordless sudo is required for `azureuser` on the Azure VM and for the default user on the JarvisLabs VM.

## 1. Azure control plane

These commands use Tailscale. NetBird is the subsection below. WireGuard is in the README.

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

### NetBird instead of Tailscale

Skip `tailscale up`. Install NetBird on the laptop as well (`netbird up`) so you can SSH to the Azure VM's NetBird address. Clone the repo on the Azure VM the same way as above.

Create a reusable setup key in the NetBird dashboard. A new network lets every peer reach every other peer. If you changed access control, allow TCP 6443, TCP 10250, and UDP 8472 between the VMs. Self-hosted NetBird also needs `NETBIRD_MANAGEMENT_URL`.

```bash
sudo env CLUSTER_MESH=netbird NETBIRD_SETUP_KEY=<setup-key> \
  bash k8s/scripts/bootstrap-control-plane.sh
```

The script installs NetBird, runs `netbird up` on `wt0`, and advertises that address. DNS on the VM is left alone (`--disable-dns`). If NetBird is already connected, the setup key is not required:

```bash
sudo netbird up --hostname k8s-cp
sudo env CLUSTER_MESH=netbird bash k8s/scripts/bootstrap-control-plane.sh
```

`ip -4 addr show wt0` is the address to use as `AZURE_SSH`. Sections 3 and 4 below are the same after the GPU node is up.

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
3. Installs the mesh client (Tailscale or NetBird), containerd, kubeadm, and the NVIDIA container toolkit on the VM.
4. Joins the node as `jarvis-gpu` and labels it `gpu.jarvislabs.ai/node=true`.

To join that VM with NetBird instead, use the same script and a setup key. The control plane must already be advertising its NetBird address.

```bash
export CLUSTER_MESH=netbird
export NETBIRD_SETUP_KEY=<setup-key>
export AZURE_SSH=azureuser@<netbird-ip>
# self-hosted only:
# export NETBIRD_MANAGEMENT_URL=https://netbird.example.com:443
bash scripts/add-gpu-node.sh
```

The GPU VM installs NetBird, connects as `jarvis-gpu`, and joins over `wt0`. The client starts again with the OS after pause and resume, same as Tailscale.

Check from the Azure VM:

```bash
sudo kubectl get nodes -o wide
sudo kubectl describe node jarvis-gpu | grep nvidia.com/gpu
```

`nvidia.com/gpu` appears in Allocatable after the device plugin starts. That can take a minute after the node is Ready.

## See which mesh the cluster uses

From the laptop, after `bash scripts/k8s-access.sh`:

```bash
kubectl get nodes -o wide
```

`INTERNAL-IP` is the address kubeadm advertised.

| INTERNAL-IP | Mesh |
| --- | --- |
| `10.200.0.1` and `10.200.0.2` | WireGuard (`wg0`) |
| the address on `tailscale0` | Tailscale |
| the address on `wt0` | NetBird |

On a node, `grep node-ip /etc/default/kubelet` prints the same address. `sudo netbird status` can say `Connected` while kubelet still uses `wg0`. That means NetBird is up beside the cluster, and pod traffic stays on WireGuard. Switching meshes means a new `kubeadm init`. The control-plane script leaves an existing `/etc/kubernetes/admin.conf` alone.

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
| `bash scripts/gpu-resume.sh` | laptop | Resume the VM. The mesh client and kubelet start with the OS |
| `bash scripts/gpu-destroy.sh` | laptop | Delete the VM and `kubectl delete node jarvis-gpu` when `AZURE_SSH` is set |
| `bash scripts/k8s-apply.sh` | Azure VM | Re-apply after a `manifest.yaml` or image change |

Pause keeps the disk, including the Hugging Face cache. Resume does not re-run `kubeadm join`. Destroy deletes that disk.

`jl resume` can print a new machine id. Put that id in `.k8s-gpu-state` or the next pause will target the old VM. The public IP can change too. Tailscale and NetBird addresses stay with the node. WireGuard's node addresses (`10.200.0.1`, `10.200.0.2`) also stay, but Azure's peer `Endpoint` is the GPU public IP, so update it or the tunnel stays down:

```bash
sudo wg set wg0 peer <gpu-public-key> endpoint <new-gpu-public-ip>:51820
```

Write the same `Endpoint` into `/etc/wireguard/wg0.conf` on Azure so a reboot keeps it. From the GPU VM, `ping -c 3 10.200.0.1` should succeed.

JarvisLabs may set the hostname to `jl-vm-<id>` on resume. kubelet then looks for that name and leaves `jarvis-gpu` NotReady. On the GPU VM:

```bash
sudo hostnamectl set-hostname jarvis-gpu
sudo systemctl restart kubelet
```

Changing `model` or `vllm.max_model_len` in `manifest.yaml` needs another `scripts/k8s-apply.sh`. The vLLM Deployment uses `Recreate`, so the old pod is removed before the new one asks for the GPU.

## Troubleshooting

**`kubectl` cannot reach `127.0.0.1:16443`**
The laptop kubeconfig uses an SSH tunnel. Run `bash scripts/k8s-access.sh` again. `.k8s-cp-state` supplies `AZURE_SSH` and `CLUSTER_API`.

**`kubeadm init` cannot find a container runtime**
The control-plane script writes `/etc/containerd/config.toml` and enables containerd. Re-run it only on a machine that does not already have `/etc/kubernetes/admin.conf`.

**GPU node stays NotReady**
On the GPU VM the mesh address must exist (`tailscale ip -4`, or `ip -4 addr show wt0` for NetBird, or `10.200.0.2` for WireGuard), and `systemctl status kubelet` should be active. `hostname` must be `jarvis-gpu`. From Azure, `sudo kubectl describe node jarvis-gpu`. Flannel must be using the same interface as kubelet (`tailscale0`, `wt0`, or `wg0`). If pod CIDR traffic dies silently, the Flannel MTU was not set to 1230; re-run is not automatic once `admin.conf` exists, so patch the `kube-flannel-cfg` ConfigMap and restart the Flannel DaemonSet.

With WireGuard, a failed `ping 10.200.0.1` from the GPU VM means Azure still has the previous public IP as the peer endpoint. Update it as in **Day to day**. NetBird uses UDP while WireGuard holds `51820`; the client picks another port and can run beside `wg0` without becoming the cluster network.

**`nvidia.com/gpu` is missing**
On the GPU VM, `nvidia-smi` and `nvidia-ctk runtime configure --runtime=containerd --set-as-default` must have succeeded. Then `sudo kubectl -n kube-system logs -l name=nvidia-device-plugin-ds` (the label varies by plugin version). The DaemonSet is selected onto `gpu.jarvislabs.ai/node=true`.

**vLLM pending**
The node label or the GPU resource is missing, or `jarvislabs.num_gpus` asks for more GPUs than the VM has. The Deployment requests that count.

**ImagePullBackOff on Streamlit**
`UI_IMAGE` must be a registry the Azure node can pull. `llm-deployment-ui:latest` is only a placeholder inside the manifest.

**Streamlit loads and then the socket drops**
Use the NodePort or port-forward path above. An ingress in front of Streamlit needs the long proxy timeouts in `k8s/ingress.yaml`.
