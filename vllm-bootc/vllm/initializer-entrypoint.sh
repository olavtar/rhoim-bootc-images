#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# RHOIM vLLM initializer (GPU-only, RHAIIS-based)
# - GPU is REQUIRED. Fail fast if not present.
# - Assumes vLLM + torch are provided by the base image.
# - Downloads model to MODEL_PATH if not present (requires outbound network unless HF is cached).
# - Uses python module for HF download (no huggingface-cli / no InquirerPy dependency).
# - Explicitly prefers /opt/app-root/bin/python3 because systemd PATH may not include it.
# =============================================================================

log()  { echo "[RHOIM] $*"; }
err()  { echo "[RHOIM] ERROR: $*" >&2; }
warn() { echo "[RHOIM] WARNING: $*" >&2; }

# 1) Load /etc/sysconfig/rhoim if present
if [ -f "/etc/sysconfig/rhoim" ]; then
  # shellcheck disable=SC1091
  source /etc/sysconfig/rhoim
fi

# 1.5) Choose the right Python (RHAIIS images commonly use /opt/app-root/bin/python3)
PYTHON_BIN="/opt/app-root/bin/python3"
if [ ! -x "${PYTHON_BIN}" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi
if [ -z "${PYTHON_BIN}" ] || [ ! -x "${PYTHON_BIN}" ]; then
  err "python3 not found"
  exit 1
fi

# Make sure the preferred python location is on PATH (helps subprocesses and vLLM)
export PATH="/opt/app-root/bin:${PATH}"

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

  # Last resort: ask torch (using the selected python)
  "${PYTHON_BIN}" - <<'PY' >/dev/null 2>&1
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
log "Using PYTHON_BIN=${PYTHON_BIN}"

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

  # Use huggingface_hub python module (no huggingface-cli extra dependency)
  if ! "${PYTHON_BIN}" -c "import huggingface_hub" >/dev/null 2>&1; then
    err "huggingface_hub is not installed for ${PYTHON_BIN}."
    err "Install huggingface_hub (>=0.34.0,<1.0) in the image or pre-populate ${LOCAL_MODEL_DIR}."
    exit 1
  fi

  # If a token is required, user can pass HF_TOKEN or have it in ~/.cache/huggingface.
  # Use `--local-dir-use-symlinks False` to avoid symlink issues across filesystems.
  "${PYTHON_BIN}" -m huggingface_hub.cli.download "${VLLM_MODEL}" \
    --local-dir "${LOCAL_MODEL_DIR}" \
    --local-dir-use-symlinks False

  log "Download complete: ${LOCAL_MODEL_DIR}"
else
  log "Using cached model at ${LOCAL_MODEL_DIR}"
fi

# 5) Start vLLM OpenAI-compatible server
# IMPORTANT: Don't exec `vllm` directly because its shebang may point to a different python.
# Run the CLI script explicitly with the selected interpreter.
VLLM_CLI="/opt/app-root/bin/vllm"

if [ -x "${VLLM_CLI}" ]; then
  exec "${PYTHON_BIN}" "${VLLM_CLI}" serve "${LOCAL_MODEL_DIR}" \
    --host "${HOST}" \
    --port "${PORT}" \
    --dtype "${DTYPE}" \
    --device "${VLLM_DEVICE_TYPE}" \
    ${VLLM_EXTRA_ARGS}
fi

# Fallback: call the CLI module directly if the script isn't present
exec "${PYTHON_BIN}" -m vllm.entrypoints.cli.main serve "${LOCAL_MODEL_DIR}" \
  --host "${HOST}" \
  --port "${PORT}" \
  --dtype "${DTYPE}" \
  --device "${VLLM_DEVICE_TYPE}" \
  ${VLLM_EXTRA_ARGS}


