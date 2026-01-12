# RHOIM Bootc Image - RHEL 9 Base

This directory contains the Containerfile and configuration files for building a bootc-compatible image for serving LLM models using vLLM on RHEL 9.

## Overview

- **Base Image**: `registry.redhat.io/rhel9/rhel-bootc:latest`
- **Builder Base**: `registry.access.redhat.com/ubi9/ubi:latest`
- **vLLM**: Installed via `pip` in a Python virtualenv (default `0.10.2`)
- **Python**: 3.9 (pinned in the `Containerfile`)
- **Target Architecture**: `linux/amd64` (x86_64)
- **Features**:
  - vLLM OpenAI-compatible API server
  - Systemd service management (`rhoim-vllm.service`)
  - NVIDIA GPU support via CUDA-enabled PyTorch in the builder stage

## Prerequisites

1. **Build Tools**
   - Podman

2. **macOS Setup** (if building on macOS)
   ```bash
   # Ensure Podman machine is rootful
   podman machine stop
   podman machine set --rootful=true
   podman machine start
   ```

## Build Instructions

### 1. Build Container Image

Build the bootc container image with vLLM.

```bash
cd /path/to/rhoim-bootc-images/vllm-bootc

podman build --no-cache -t localhost/rhoim-vllm-bootc:latest -f Containerfile .
```

## Run and Verify (GPU Container)

Run the image directly with Podman (systemd-in-container), exposing port 8000:

```bash
podman run -d --name rhoim-test --replace \
  --device nvidia.com/gpu=all \
  --privileged --security-opt label=disable \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
  -p 8000:8000 \
  localhost/rhoim-vllm-bootc:latest /sbin/init
```

Wait for the service to fully start (model download/load can take 1-3 minutes), then:

```bash
# Check service status
podman exec rhoim-test systemctl status rhoim-vllm.service

# View service logs
podman exec rhoim-test journalctl -u rhoim-vllm.service -f
```

Test the API:

```bash
# List available models
curl http://127.0.0.1:8000/v1/models

# Health check (if available)
curl http://127.0.0.1:8000/health

# Chat completion example
curl http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
    "messages": [{"role": "user", "content": "Hello, what the weather today in Aruba!"}]
  }'
```

## Configuration

### Environment Variables

Edit `/etc/sysconfig/rhoim` inside the container / bootc image (or rebuild with changes):

```bash
# Model configuration
MODEL_ID="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
VLLM_PORT="8000"
VLLM_HOST="0.0.0.0"

# Device type (GPU-only)
VLLM_DEVICE_TYPE="cuda"
```

After modifying, restart the service:
```bash
systemctl restart rhoim-vllm.service
```

### Service Management

```bash
# Start service
systemctl start rhoim-vllm.service

# Stop service
systemctl stop rhoim-vllm.service

# Restart service
systemctl restart rhoim-vllm.service

# View logs
journalctl -u rhoim-vllm.service -f
```

## Troubleshooting

### Service Not Accessible via API

**Check**:
1. Service is running: `systemctl status rhoim-vllm.service`
2. Port is listening: `netstat -tlnp | grep 8000` or `ss -tlnp | grep 8000`
3. Model is still loading (check logs for "Application startup complete")
4. If service shows JSON decode errors:
   - Clear Hugging Face cache: `rm -rf ~/.cache/huggingface`
   - Restart service: `systemctl restart rhoim-vllm.service`

### Build Fails with NUMA Linking Error

This README no longer documents a vLLM source-build flow. If you see NUMA linker errors, they are likely coming from a custom/local change; try rebuilding with `--no-cache`:

```bash
podman build --no-cache -t localhost/rhoim-vllm-bootc:latest -f Containerfile .
```

### Out of Memory During Build

If build fails with `g++: fatal error: Killed`, reduce parallelism:
- Increase available memory for the build environment (Podman machine / builder).
- Rebuild with `--no-cache` to ensure you’re not hitting a bad cached layer.

## File Structure

```
vllm-bootc/
├── Containerfile                  # Multi-stage build definition
├── scripts/
│   └── build-vllm-from-source.sh # Helper script (not used by the default Containerfile flow)
├── etc/
│   ├── sysconfig/
│   │   └── rhoim                  # Environment defaults
│   ├── systemd/
│   │   └── system/
│   │       └── rhoim-vllm.service # Systemd service unit
│   └── sysusers.d/
│       └── rhoim.conf             # User creation for rhoim service
├── vllm/
│   └── initializer-entrypoint.sh  # vLLM startup script
└── README.md
```

## Production Deployment

For production deployment:

1. **Build on target architecture**: Build the image on the same architecture as deployment target
2. **NVIDIA GPU required**: Run on a host with NVIDIA drivers and expose GPUs to the container (see the run command above)
3. **Secure access**: Configure appropriate authentication and access controls
4. **Configure networking**: Set up proper networking and firewall rules for your environment
5. **Monitor logs**: Set up log aggregation and monitoring

For cloud deployment specifics, see the [Cloud Deployment Guide](../docs/CLOUD_DEPLOYMENT.md).

## Additional Resources

- [bootc Documentation](https://github.com/containers/bootc)
- [vLLM Documentation](https://docs.vllm.ai/)
- [RHEL Bootc Images](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_containers/using-bootc)