# RHOIM Bootc Image (GPU-only) - RHEL 9 + RHAIIS vLLM

This directory contains the **Containerfile** and configuration files for building a **bootc-compatible** RHEL 9 image that serves an LLM via **vLLM**.

This variant is **GPU-only** and is built **on top of the supported RHAIIS vLLM CUDA image** (instead of building vLLM/Torch from source).

## Overview

- **Base Image**: `registry.redhat.io/rhaiis/vllm-cuda-rhel9:latest`
- **Target Architecture**: `linux/amd64` (x86_64) **only**
- **Features**
  - vLLM OpenAI-compatible API server
  - Systemd service management (`rhoim-vllm.service`)
  - Hugging Face model download to a local model directory on first start
  - **GPU-only**: fails fast if an NVIDIA GPU is not visible inside the container/VM

## Prerequisites

### Build prerequisites
- Podman
- Access to `registry.redhat.io` (login required to pull the RHAIIS base image)

### Runtime prerequisites (GPU)
- NVIDIA GPU + compatible NVIDIA drivers on the host
- Container runtime configured for GPU passthrough:
  - **Preferred (modern)**: NVIDIA CDI
  - **Legacy**: OCI hooks (`/usr/share/containers/oci/hooks.d`)

## Build Instructions

### 1) Build the bootc container image

```bash
cd /path/to/rhoim-bootc-images/vllm-bootc

# Login if needed (required for registry.redhat.io)
podman login registry.redhat.io

podman build   --platform linux/amd64   -t localhost/rhoim-bootc-rhaiis-gpu:latest   -f ./Containerfile .
```

### 2) (Optional) Build a bootc VM image (qcow2)

Convert the container image to a bootable VM disk image using bootc-image-builder:

```bash
mkdir -p images

podman run --rm --privileged   -v /var/lib/containers/storage:/var/lib/containers/storage   -v "$(pwd)/images":/output   quay.io/centos-bootc/bootc-image-builder:latest   --type qcow2   localhost/rhoim-bootc-rhaiis-gpu:latest
```

The bootc VM image will be created at: `images/qcow2/disk.qcow2`

> Note: `bootc-image-builder` is just a converter; it does not change the OS inside the image.

## Running (GPU-only)

### Run the container directly (recommended for quick testing)

#### Preferred: NVIDIA CDI

```bash
podman run --rm -it   --name rhoim-bootc-test   --privileged   --systemd=always   --device nvidia.com/gpu=all   -p 8000:8000   localhost/rhoim-bootc-rhaiis-gpu:latest
```

#### Legacy: OCI hooks

```bash
podman run --rm -it   --name rhoim-bootc-test   --privileged   --systemd=always   --hooks-dir=/usr/share/containers/oci/hooks.d   -p 8000:8000   localhost/rhoim-bootc-rhaiis-gpu:latest
```

### Verify GPU visibility (inside the container)

```bash
nvidia-smi
```

If GPUs are not visible, the service will fail fast with an error like:

```
[RHOIM] ERROR: No NVIDIA GPU devices found (/dev/nvidia*). This image is GPU-only.
```

## Testing and Verification

### 1) Check vLLM service status

```bash
systemctl status rhoim-vllm.service
```

### 2) View service logs

```bash
journalctl -u rhoim-vllm.service -f
```

### 3) Test the OpenAI-compatible API

Wait for the service to fully start (model loading can take 1–3 minutes), then:

```bash
# List available models
curl http://127.0.0.1:8000/v1/models

# Health check (if available)
curl http://127.0.0.1:8000/health

# Chat completion example
curl http://127.0.0.1:8000/v1/chat/completions   -H "Content-Type: application/json"   -d '{
    "model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Configuration

Edit `/etc/sysconfig/rhoim` inside the VM/container (or rebuild with changes). For this GPU-only image:

```bash
MODEL_ID="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
MODEL_PATH="/tmp/models"
VLLM_PORT="8000"
VLLM_HOST="0.0.0.0"

# GPU-only
VLLM_DEVICE_TYPE="cuda"
RHOIM_ACCELERATOR_MODE="gpu"
```

After modifying, restart the service:

```bash
systemctl restart rhoim-vllm.service
```

## Troubleshooting

### Cannot pull the base image (registry.redhat.io auth)

```bash
podman login registry.redhat.io
podman pull registry.redhat.io/rhaiis/vllm-cuda-rhel9:latest
```

### Service fails immediately: “GPU-only” / no NVIDIA devices

- Ensure the host has NVIDIA drivers installed
- Ensure GPU passthrough is enabled:
  - CDI: `--device nvidia.com/gpu=all`
  - Hooks: `--hooks-dir=/usr/share/containers/oci/hooks.d`
- Confirm inside container: `nvidia-smi`

## Deprecations

- `scripts/build-vllm-from-source.sh` is **deprecated** for this RHAIIS-based GPU-only image path.
  - This repo no longer builds vLLM/Torch from source for the default GPU image.
  - The script is kept for reference/legacy experimentation and may be removed in a future release.

## File Structure

```
vllm-bootc/
├── Containerfile
├── scripts/
│   └── build-vllm-from-source.sh        # DEPRECATED (legacy path)
├── etc/
│   ├── sysconfig/
│   │   └── rhoim                         # Environment defaults (GPU-only)
│   ├── systemd/
│   │   └── system/
│   │       └── rhoim-vllm.service        # Systemd service unit (GPU-only)
│   └── sysusers.d/
│       └── rhoim.conf                    # User creation for rhoim service
├── vllm/
│   └── initializer-entrypoint.sh         # vLLM startup script (GPU-only)
└── README.md
```

## Additional Resources

- bootc: https://github.com/containers/bootc
- vLLM: https://docs.vllm.ai/
