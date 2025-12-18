#!/usr/bin/env bash
set -euo pipefail

# 0. Set CPU-only env vars early for arm64 to prevent CUDA detection during vLLM import
# This must happen BEFORE any vLLM imports (which happen during argument parsing)
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    export CUDA_VISIBLE_DEVICES=
    export VLLM_NO_CUDA=1
    export VLLM_CPU_ONLY=1
    export VLLM_PLATFORM=cpu
    export VLLM_SKIP_PLATFORM_CHECK=1
    export VLLM_USE_FLASHINFER=0
fi

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
VLLM_DEVICE_TYPE="${VLLM_DEVICE_TYPE:-auto}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

# 3. GPU detection
have_gpu() {
    # 1) Best signal: NVIDIA device nodes are present inside the container
    if ls /dev/nvidiactl /dev/nvidia0 >/dev/null 2>&1; then
        return 0
    fi

    # 2) If nvidia-smi exists and works, also good
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        return 0
    fi

    # 3) Last resort: ask torch (only works if torch is CUDA build and GPU is visible)
    /opt/vllm-venv/bin/python - <<'PY' >/dev/null 2>&1
import torch
raise SystemExit(0 if (torch.version.cuda is not None and torch.cuda.is_available()) else 1)
PY
}

DEVICE="cpu"
if [[ "${VLLM_DEVICE_TYPE}" == "cuda" ]]; then
    DEVICE="cuda"
elif [[ "${VLLM_DEVICE_TYPE}" == "auto" ]] && have_gpu; then
    DEVICE="cuda"
fi

echo "[RHOIM] VLLM_MODEL=${VLLM_MODEL}"
echo "[RHOIM] HOST=${HOST} PORT=${PORT}"
echo "[RHOIM] MODEL_PATH=${MODEL_PATH}"
echo "[RHOIM] Requested VLLM_DEVICE_TYPE=${VLLM_DEVICE_TYPE}, selected DEVICE=${DEVICE}"

# 4. Ensure model is present
mkdir -p "${MODEL_PATH}"
LOCAL_MODEL_DIR="${MODEL_PATH}/${VLLM_MODEL}"

if [ ! -d "${LOCAL_MODEL_DIR}" ] || [ -z "$(ls -A "${LOCAL_MODEL_DIR}" 2>/dev/null || true)" ]; then
    echo "[RHOIM] Downloading ${VLLM_MODEL} to ${LOCAL_MODEL_DIR}"

    # Prefer venv CLI, but fall back to PATH if needed
    HF_CLI="/opt/vllm-venv/bin/huggingface-cli"
    if [ ! -x "${HF_CLI}" ]; then
        if command -v huggingface-cli >/dev/null 2>&1; then
            HF_CLI="$(command -v huggingface-cli)"
        else
            echo "[RHOIM] ERROR: huggingface-cli not found (tried /opt/vllm-venv and PATH)" >&2
            exit 1
        fi
    fi

    "${HF_CLI}" download "${VLLM_MODEL}" \
        --local-dir "${LOCAL_MODEL_DIR}" \
        --local-dir-use-symlinks False
fi

# 5. Build vLLM args
ARGS=(
  --model "${LOCAL_MODEL_DIR}"
  --host "${HOST}"
  --port "${PORT}"
)

if [[ "${DEVICE}" == "cuda" ]]; then
    echo "[RHOIM] Starting vLLM in CUDA mode"
    # vLLM 0.10.2 doesn't support --device argument, rely on environment variables
else
    echo "[RHOIM] Starting vLLM in CPU mode"
    # vLLM 0.10.2 doesn't support --device argument, use environment variables and dtype
    ARGS+=(--dtype "${DTYPE}" --enforce-eager)
    export CUDA_VISIBLE_DEVICES=
    export VLLM_NO_CUDA=1
    export VLLM_CPU_ONLY=1
    export VLLM_PLATFORM=cpu
    export VLLM_SKIP_PLATFORM_CHECK=1
    export VLLM_USE_FLASHINFER=0
fi

if [[ -n "${VLLM_EXTRA_ARGS}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_ARR=(${VLLM_EXTRA_ARGS})
    ARGS+=("${EXTRA_ARR[@]}")
fi

# Use the venv's python executable
PYTHON_CMD="/opt/vllm-venv/bin/python"

echo "[RHOIM] Using Python: ${PYTHON_CMD}"
echo "[RHOIM] Final vLLM args: ${ARGS[*]}"

exec "${PYTHON_CMD}" -m vllm.entrypoints.openai.api_server "${ARGS[@]}"