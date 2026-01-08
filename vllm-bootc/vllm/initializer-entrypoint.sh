#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# RHOIM vLLM initializer (GPU-only, RHAIIS-based)
# - GPU is REQUIRED. Fail fast if not present.
# - Assumes vLLM + torch are provided by the base image (no /opt/vllm-venv).
# =============================================================================

# 1. Load /etc/sysconfig/rhoim if present
if [ -f "/etc/sysconfig/rhoim" ]; then
  # shellcheck disable=SC1091
  source /etc/sysconfig/rhoim
fi

# 2. Map old names -> new names (backward compatible)
VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
HOST="${HOST:-${VLLM_HOST:-0.0.0.0}}"
PORT="${PORT:-${VLLM_PORT:-8000}}"
MODEL_PATH="${MODEL_PATH:-/tmp/models}"
DTYPE="${DTYPE:-float32}"
# For GPU-only image, default should be cuda; allow explicit override for clarity
VLLM_DEVICE_TYPE="${VLLM_DEVICE_TYPE:-cuda}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

# 3. GPU detection (GPU-only: must pass)
have_gpu() {
  # Best signal: NVIDIA device nodes are present inside the container
  if ls /dev/nvidiactl /dev/nvidia0 >/dev/null 2>&1; then
    return 0
  fi

  # If nvidia-smi exists and works, also good
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    return 0
  fi

  # Last resort: ask torch (only works if torch is CUDA build and GPU is visible)
  python3 - <<'PY' >/dev/null 2>&1
import torch
raise SystemExit(0 if (torch.version.cuda is not None and torch.cuda.is_available()) else 1)
PY
}

if ! have_gpu; then
  echo "[RHOIM] ERROR: No NVIDIA GPU devices found (/dev/nvidia*)." >&2
  echo "[RHOIM]        This image is GPU-only." >&2
  echo "[RHOIM]        Ensure the host has NVIDIA drivers installed and GPU passthrough is enabled." >&2
  echo "[RHOIM]        (e.g. NVIDIA Container Toolkit / CDI, podman --device nvidia.com/gpu=all)" >&2
  exit 1
fi

# Enforce GPU-only mode (even if user sets something else)
if [[ "${VLLM_DEVICE_TYPE}" != "cuda" ]]; then
  echo "[RHOIM] WARNING: VLLM_DEVICE_TYPE=${VLLM_DEVICE_TYPE} requested, but this image is GPU-only." >&2
  echo "[RHOIM]          Forcing VLLM_DEVICE_TYPE=cuda." >&2
  VLLM_DEVICE_TYPE="cuda"
fi

echo "[RHOIM] VLLM_MODEL=${VLLM_MODEL}"
echo "[RHOIM] HOST=${HOST} PORT=${PORT}"
echo "[RHOIM] MODEL_PATH=${MODEL_PATH}"
echo "[RHOIM] Selected DEVICE=cuda (GPU-only)"

# 4. Ensure model is present
mkdir -p "${MODEL_PATH}"
LOCAL_MODEL_DIR="${MODEL_PATH}/${VLLM_MODEL}"

if [ ! -d "${LOCAL_MODEL_DIR}" ] || [ -z "$(ls -A "${LOCAL_MODEL_DIR}" 2>/dev/null || true)" ]; then
  echo "[RHOIM] Downloading ${VLLM_MODEL} to ${LOCAL_MODEL_DIR}"

  # huggingface-cli must be available in the image
  if ! command -v huggingface-cli >/dev/null 2>&1; then
    echo "[RHOIM] ERROR: huggingface-cli not found in PATH." >&2
    ech
