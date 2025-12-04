## RHOIM Inference Platform – Images for OpenShift, Kubernetes, and bootc

This repo provides container images and a bootc image for running an OpenAI‑compatible
LLM gateway based on vLLM. It supports:

- **Two‑container mode** on OpenShift/vanilla Kubernetes (gateway + vLLM)
- **Single‑container appliance** (gateway + vLLM together, GPU or CPU‑only)
- **bootc VM image** (off‑Kubernetes, systemd‑managed vLLM + gateway)

The gateway implements RHOAI‑compatible chat completions and metrics; vLLM can run
either CPU‑only or on GPU via RHAIIS.

---

## Repo layout

- `gateway/` – FastAPI/OpenAI‑style gateway (`app/`) and its `Dockerfile`.
- `runtimes/vllm/` – GPU vLLM runtime image.
- `runtimes/vllm-cpu/` – CPU‑only vLLM runtime image.
- `deploy/appliance/` – Single‑container GPU appliance (gateway + vLLM + model pull).
- `deploy/appliance-cpu/` – Single‑container CPU‑only appliance.
- `deploy/bootc/` – RHEL 9 bootc image (vLLM + gateway via systemd).
- `deploy/helm/rhoim/` – Helm chart for OpenShift/vanilla Kubernetes.
- `scripts/model_pull.sh` – Model pre‑pull helper for the GPU appliance.

---

## Single‑container CPU appliance (local, no registry, TinyLlama)

The simplest way to try RHOIM locally is the CPU‑only appliance image. It uses
`TinyLlama/TinyLlama-1.1B-Chat-v1.0` by default (public, no HF token required).

```bash
# Build only the single appliance image locally (tagged 'rhoim:latest')
make build-appliance-cpu-local TAG=latest

# Run single‑container CPU appliance
podman run --rm -p 8080:8080 \
  -e API_KEYS="devkey1,devkey2" \
  -e MODEL_URI="TinyLlama/TinyLlama-1.1B-Chat-v1.0" \
  rhoim:latest

# Health
curl http://localhost:8080/healthz

# Chat (RHOAI‑style)
curl -H "Authorization: Bearer devkey1" -H 'Content-Type: application/json' \
  --data '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","messages":[{"role":"user","content":"hello"}]}' \
  http://localhost:8080/api/rhoai/v1/chat/completions

# Metrics
curl http://localhost:8080/metrics
```

### Package the appliance image as a tarball

```bash
# Save the 'rhoim:latest' appliance image under ./image/
make package-appliance-cpu TAG=latest

# On another machine:
podman load -i image/rhoim-latest.tar
podman run --rm -p 8080:8080 \
  -e API_KEYS="devkey1,devkey2" \
  -e MODEL_URI="TinyLlama/TinyLlama-1.1B-Chat-v1.0" \
  rhoim:latest
```

---

## Building CPU images for registries (vLLM CPU + appliance CPU)

To build and push CPU‑only images for use with the Helm chart (or other tooling):

```bash
# Build and push CPU images to your registry
REG=quay.io/you TAG=latest make build-cpu push-cpu

# Or, build without pushing:
REG=quay.io/you TAG=latest make build-cpu
```

This produces:

- `$(REG)/rhoim-vllm-cpu:$(TAG)` – vLLM CPU runtime
- `$(REG)/rhoim-appliance-cpu:$(TAG)` – single‑container CPU appliance

You can also build local‑tagged variants without a registry prefix:

```bash
TAG=latest make build-cpu-local
```

---

## Helm deployment on OpenShift / Kubernetes

The Helm chart in `deploy/helm/rhoim/` supports:

- **Two‑container mode** – gateway + vLLM runtime
- **Single‑container appliance mode** – one pod running both gateway + vLLM

The image names are configured in `deploy/helm/rhoim/values.yaml`:

- `image.gateway`
- `image.vllm`
- `image.appliance`

Install/upgrade the chart:

```bash
REG=quay.io/you TAG=latest NS=rhoim

# (Assumes you have pushed the matching images to $(REG))
make helm-install REG=$REG TAG=$TAG NS=$NS
```

Uninstall:

```bash
NS=rhoim make helm-uninstall
```

To switch between two‑container and single‑container modes, set `singleContainer`
in `values.yaml` (or via `--set singleContainer=true`).

---

## bootc VM image (off‑Kubernetes)

The `deploy/bootc/Containerfile` defines a bootc image that:

- Creates a Python venv with CPU vLLM and gateway dependencies.
- Installs systemd units for:
  - `rhoim-vllm` – runs `deploy/bootc/launch-vllm.sh` (CPU or GPU via RHAIIS).
  - `rhoim-gateway` – runs the FastAPI gateway with Uvicorn.
- Uses `/etc/sysconfig/rhoim` (`deploy/bootc/rhoim.env` as a template) for config.

### Requirements

- Podman (rootful mode) and `quay.io/centos-bootc/bootc-image-builder:latest`
- QEMU to boot the qcow2 locally (or use the generated VMDK/OVF elsewhere)

### 1) Build the bootc container image

From this repo root:

```bash
podman build -t localhost/rhoim-bootc:latest -f deploy/bootc/Containerfile .
```

On macOS, ensure the Podman machine is rootful:

```bash
podman machine stop
podman machine set --rootful=true
podman machine start
```

### 2) Create a qcow2 with bootc‑image‑builder

```bash
mkdir -p image
podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$PWD/image":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-bootc:latest
```

Artifacts will be created under `./image/` (for example, `image/qcow2/disk.qcow2`).

### 3) Boot the VM

- **Apple Silicon (ARM64)** – recommended to build and run natively:

  ```bash
  podman build --platform linux/arm64 -t localhost/rhoim-bootc:arm64 -f deploy/bootc/Containerfile .
  rm -rf image && mkdir -p image
  podman run --rm --privileged \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$PWD/image":/output \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    --target-arch aarch64 \
    localhost/rhoim-bootc:arm64

  BIOS="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd"
  qemu-system-aarch64 -accel hvf -machine virt -cpu host \
    -m 8G -smp 4 -bios "$BIOS" \
    -drive if=virtio,format=qcow2,file="$PWD/image/qcow2/disk.qcow2" \
    -netdev user,id=n1,hostfwd=tcp::8080-:8080,hostfwd=tcp::8000-:8000 \
    -device virtio-net-pci,netdev=n1 -serial mon:stdio
  ```

- **x86_64 (Intel/AMD)**:

  ```bash
  BIOS_X64="$(brew --prefix qemu)/share/qemu/edk2-x86_64-code.fd"
  qemu-system-x86_64 -m 8G -smp 4 \
    -bios "$BIOS_X64" \
    -drive if=virtio,format=qcow2,file="$PWD/image/qcow2/disk.qcow2" \
    -net nic,model=virtio -net user,hostfwd=tcp::8080-:8080,hostfwd=tcp::8000-:8000 \
    -serial mon:stdio
  ```

### 4) Test the endpoints

```bash
# vLLM (OpenAI list‑models)
curl http://localhost:8000/v1/models

# Gateway
curl http://localhost:8080/healthz
curl -H "Authorization: Bearer devkey1" -H 'Content-Type: application/json' \
  --data '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","messages":[{"role":"user","content":"hello"}]}' \
  http://localhost:8080/api/rhoai/v1/chat/completions
```

### Configuring the model and accelerator mode

Edit `deploy/bootc/rhoim.env` before building the bootc image, for example:

```bash
MODEL_ID=TinyLlama/TinyLlama-1.1B-Chat-v1.0
MODEL_PATH=/opt/rhoim/models
RHOIM_ACCELERATOR_MODE=auto   # auto | gpu | cpu
MAX_MODEL_LEN=2048
VLLM_LOGGING_LEVEL=INFO
VLLM_TAG=3.2.3                # RHAIIS vLLM image tag for GPU mode
```

At runtime, `launch-vllm.sh`:

- Downloads the model into `${MODEL_PATH}/${MODEL_ID}` using `huggingface-cli`.
- Selects CPU vs GPU based on `RHOIM_ACCELERATOR_MODE`, GPU presence, and `podman`.
- For GPU, runs the RHAIIS vLLM image (`registry.redhat.io/rhaiis/vllm-cuda-rhel9:${VLLM_TAG}`).
- For CPU, runs in‑image vLLM via the Python venv.

### Troubleshooting

- If `curl :8080` resets, wait 1–3 minutes for the first model download or
  pre‑pull the model.
- Inside the VM, check logs:

  ```bash
  journalctl -u rhoim-vllm -e
  journalctl -u rhoim-gateway -e
  ```

- On macOS, ensure QEMU is installed (`brew install qemu`) and Podman is rootful.

