# RHOIM Bootc Image (GPU-only, RHAIIS-based)

This directory contains the files required to build a **bootc OS image** (convertible to `qcow2` / `raw` / `vhd` via `bootc-image-builder`) that **serves an LLM using the official RHAIIS vLLM container**, managed by **systemd (Quadlet)**.

> **Key design choice:**  
> vLLM, PyTorch, CUDA, and model serving **run inside the RHAIIS container**, not on the bootc OS layer.  
> The bootc image acts as a minimal, reproducible host that starts the container automatically at boot.

---

## Overview

- **Bootc OS base**: `registry.redhat.io/rhel9/rhel-bootc:latest`
- **Model server runtime**: `registry.redhat.io/rhaiis/vllm-cuda-rhel9:*`
- **Architecture**: `linux/amd64` (x86_64) **only**
- **GPU-only** (no CPU fallback)

### What this image provides
- vLLM **OpenAI-compatible API server**
- Systemd-managed container startup via **Podman Quadlet**
- Persistent model + cache storage on the host OS
- Automatic startup on boot (VM / disk image)
- No Python / vLLM installed on the OS layer

---

## Design Summary

| Layer | Responsibility |
|-----|----------------|
| bootc OS | systemd, podman, Quadlet, persistent storage |
| RHAIIS container | vLLM, PyTorch, CUDA, OpenAI API |
| systemd | lifecycle management (`container-rhoim-vllm.service`) |

---

## Prerequisites

### Build
- Podman
- Access to `registry.redhat.io`

```bash
podman login registry.redhat.io
```

### Runtime (GPU)
- NVIDIA GPU
- NVIDIA drivers installed on the host
- GPU passthrough configured for Podman:
  - **Preferred**: NVIDIA CDI
  - **Legacy**: OCI hooks

---

## Build Instructions

### 1) Build the bootc OS container image

```bash
cd vllm-bootc

sudo podman build --no-cache   -t localhost/rhoim-bootc-rhaiis:latest   -f Containerfile .
```

---

### 2) (Optional) Build a bootable VM disk image

```bash
mkdir -p images

podman run --rm --privileged   -v /var/lib/containers/storage:/var/lib/containers/storage   -v "$(pwd)/images":/output   quay.io/centos-bootc/bootc-image-builder:latest   --type qcow2   localhost/rhoim-bootc-rhaiis:latest
```

---

## Runtime Behavior

On boot, systemd will automatically start:

```
container-rhoim-vllm.service
```

---

## Configuration

Edit `/etc/sysconfig/rhoim` on the booted VM:

```bash
VLLM_MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
VLLM_HOST="0.0.0.0"
VLLM_PORT="8000"
VLLM_EXTRA_ARGS=""
```

---

## Testing

```bash
curl http://127.0.0.1:8000/v1/models
```

---