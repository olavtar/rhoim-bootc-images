#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# RHOIM vLLM initializer (GPU-only, RHAIIS-based)
# - GPU is REQUIRED. Fail fast if not present.
# - Assumes vLLM + torch are provided by the base image.
# - Downloads model to MODEL_PATH if not present (requires outbound network unless HF is cached).
# =============================================================================

log()  { echo "[RHOIM] $*"; }
err()  { echo "[RHOIM] ERROR: $*" >&2; }
warn() { echo "[RHOIM] WARNING: $*" >&2; }

# 1) Load /etc/sysconfig/rhoim if present
if [ -f "/etc/sysconfig/rhoim" ]; then
  # shellcheck disable=SC1091
  source /etc/sysconfig/rhoim
fi

# 2) Map old names -> new names (backward compatible)
VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
HOST="${HOST:-${VLLM_HOST:-0.0.0.0}}"
PORT="${PORT:-${VLLM_PORT:-8000}}"
MODEL_PATH="${MODEL_PATH:-/tmp/models}"
DTYPE="${DTYPE:-float32}"
# GPU-only image: default cuda; allow override but we'll force cuda below.
VLLM_DEVICE_TYPE="${VLLM_DEVICE_TYPE:-cuda}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

# Optional: allow turning off downloads (useful for offline envs)
# If true, we require model to already exist locally.
RHOIM_OFFLINE="${RHOIM_OFFLINE:-false}"

# 3) GPU detection (GPU-only: must pass)
have_gpu() {
  # Best signal: NVIDIA device nodes are present inside the container
  if ls /dev/nvidiactl /dev/nvidia0 >/dev/null 2>&1; then
    return 0
  fi

  # If nvidia-smi exists and works, also good
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    return 0
  fi

  # Last resort: ask torch
  python3 - <<'PY' >/dev/null 2>&1
import torch
raise SystemExit(0 if (torch.version.cuda is not None and torch.cuda.is_available()) else 1)
PY
}

if ! have_gpu; then
  err "No NVIDIA GPU devices found (/dev/nvidia*)."
  err "This image is GPU-only."
  err "Ensure NVIDIA drivers + GPU passthrough are enabled (CDI / NVIDIA Container Toolkit)."
  exit 1
fi

# Enforce GPU-only mode
if [[ "${VLLM_DEVICE_TYPE}" != "cuda" ]]; then
  warn "VLLM_DEVICE_TYPE=${VLLM_DEVICE_TYPE} requested, but this image is GPU-only. Forcing cuda."
  VLLM_DEVICE_TYPE="cuda"
fi

log "VLLM_MODEL=${VLLM_MODEL}"
log "HOST=${HOST} PORT=${PORT}"
log "MODEL_PATH=${MODEL_PATH}"
log "Selected DEVICE=cuda (GPU-only)"

# 4) Ensure model is present
mkdir -p "${MODEL_PATH}"

# If VLLM_MODEL contains slashes (HF repo id), create nested dirs safely.
LOCAL_MODEL_DIR="${MODEL_PATH}/${VLLM_MODEL}"

is_dir_populated() {
  local d="$1"
  [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null || true)" ]
}

if ! is_dir_populated "${LOCAL_MODEL_DIR}"; then
  log "Model not found locally at ${LOCAL_MODEL_DIR}"

  if [[ "${RHOIM_OFFLINE}" == "true" ]]; then
    err "RHOIM_OFFLINE=true and model is not present locally. Refusing to download."
    exit 1
  fi

  log "Downloading ${VLLM_MODEL} to ${LOCAL_MODEL_DIR}"

  # Intentionally do NOT depend on `huggingface-cli` (the [cli] extra pulls InquirerPy).
  # Instead, use the python module which is available with the base huggingface_hub package.
  if ! python3 -c "import huggingface_hub" >/dev/null 2>&1; then
    err "huggingface_hub is not installed."
    err "Install huggingface_hub (>=0.34.0,<1.0) in the image or pre-populate ${LOCAL_MODEL_DIR}."
    exit 1
  fi

  # Use the built-in CLI module entrypoint (no extra deps like InquirerPy)
  python3 -m huggingface_hub.cli.download "${VLLM_MODEL}" \
    --local-dir "${LOCAL_MODEL_DIR}" \
    --local-dir-use-symlinks False

  log "Download complete: ${LOCAL_MODEL_DIR}"
else
  log "Using cached model at ${LOCAL_MODEL_DIR}"
fi

# 5) Start vLLM OpenAI-compatible server
# NOTE: on RHAIIS image, vLLM is typically installed system-wide and available to python3.
# Add any extra args via VLLM_EXTRA_ARGS in /etc/sysconfig/rhoim (or env override).
exec python3 -m vllm.entrypoints.openai.api_server \
  --model "${LOCAL_MODEL_DIR}" \
  --host "${HOST}" \
  --port "${PORT}" \
  --dtype "${DTYPE}" \
  --device "${VLLM_DEVICE_TYPE}" \
  ${VLLM_EXTRA_ARGS}
