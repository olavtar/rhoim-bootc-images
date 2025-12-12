#!/usr/bin/env bash
set -euo pipefail

if [ -f "/etc/sysconfig/rhoim" ]; then
  # shellcheck disable=SC1091
  source /etc/sysconfig/rhoim
fi

# -----------------------------
# Defaults / env overrides
# -----------------------------
VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
HOST="${HOST:-${VLLM_HOST:-0.0.0.0}}"
PORT="${PORT:-${VLLM_PORT:-8000}}"
MODEL_PATH="${MODEL_PATH:-/tmp/models}"
DTYPE="${DTYPE:-float32}"
VLLM_DEVICE_TYPE="${VLLM_DEVICE_TYPE:-auto}"      # auto|cuda|cpu
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

# CPU stability knobs (safe defaults)
MAX_MODEL_LEN="${MAX_MODEL_LEN:-2048}"
VLLM_BLOCK_SIZE="${VLLM_BLOCK_SIZE:-16}"
# vLLM expects swap_space in GiB (float)
VLLM_SWAP_SPACE_GB="${VLLM_SWAP_SPACE_GB:-1.0}"

VENV_BIN="/opt/vllm-venv/bin"
PYTHON_CMD="${VENV_BIN}/python3.11"
if [ ! -x "${PYTHON_CMD}" ]; then
  PYTHON_CMD="${VENV_BIN}/python"
fi

# Prefer venv tools, but allow PATH fallback
HF_BIN="${VENV_BIN}/hf"
HF_CLI="${VENV_BIN}/huggingface-cli"

have_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

port_in_use() {
  # returns 0 if port is in use
  if command -v ss >/dev/null 2>&1; then
    ss -lnt | awk '{print $4}' | grep -qE "(:|\\[::\\]:)${PORT}$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | awk '{print $9}' | grep -q ":${PORT}$"
  else
    # can't reliably detect; assume free
    return 1
  fi
}

echo "[RHOIM] python=${PYTHON_CMD}"
echo "[RHOIM] VLLM_MODEL=${VLLM_MODEL}"
echo "[RHOIM] HOST=${HOST} PORT=${PORT}"
echo "[RHOIM] MODEL_PATH=${MODEL_PATH}"
echo "[RHOIM] Requested VLLM_DEVICE_TYPE=${VLLM_DEVICE_TYPE}"

# Show package versions (helps debug “venv not used”)
"${PYTHON_CMD}" -c 'import sys; print("[RHOIM] python_version=", sys.version.split()[0])'
"${PYTHON_CMD}" -c 'import pkgutil; import importlib; 
import vllm, torch
print("[RHOIM] vllm=", getattr(vllm, "__version__", "unknown"), "torch=", getattr(torch, "__version__", "unknown"))'

# Decide device
DEVICE="cpu"
if [[ "${VLLM_DEVICE_TYPE}" == "cuda" ]]; then
  DEVICE="cuda"
elif [[ "${VLLM_DEVICE_TYPE}" == "auto" ]] && have_gpu; then
  DEVICE="cuda"
fi
echo "[RHOIM] selected DEVICE=${DEVICE}"

# If systemd restarts too fast, you can get the “Port 8000 already in use” loop.
if port_in_use; then
  echo "[RHOIM] ERROR: Port ${PORT} is already in use. Refusing to auto-increment ports under systemd." >&2
  exit 1
fi

# SSL sanity check (your environment needs CA wiring)
echo "[RHOIM] Testing Python SSL configuration..."
"${PYTHON_CMD}" -c "
import requests, os
os.environ['REQUESTS_CA_BUNDLE'] = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'
os.environ['SSL_CERT_FILE'] = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'
resp = requests.get('https://huggingface.co', timeout=10)
print(f'[RHOIM] SSL test successful: HTTP {resp.status_code}')
"

mkdir -p "${MODEL_PATH}"
LOCAL_MODEL_DIR="${MODEL_PATH}/${VLLM_MODEL}"

# -----------------------------
# Model download
# -----------------------------
download_with_hf() {
  # IMPORTANT: do NOT pass --local-dir-use-symlinks (your hf doesn't accept it)
  "${HF_BIN}" download "${VLLM_MODEL}" --local-dir "${LOCAL_MODEL_DIR}"
}

download_with_huggingface_cli() {
  # deprecated but works across more versions
  "${HF_CLI}" download "${VLLM_MODEL}" \
    --local-dir "${LOCAL_MODEL_DIR}" \
    --local-dir-use-symlinks False
}

if [ ! -d "${LOCAL_MODEL_DIR}" ] || [ -z "$(ls -A "${LOCAL_MODEL_DIR}" 2>/dev/null || true)" ]; then
  echo "[RHOIM] Downloading ${VLLM_MODEL} to ${LOCAL_MODEL_DIR}"

  export REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  export SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  export CURL_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

  if [ -x "${HF_BIN}" ]; then
    echo "[RHOIM] Running: hf download ${VLLM_MODEL}"
    if ! download_with_hf; then
      echo "[RHOIM] hf download failed, trying huggingface-cli..." >&2
      if [ -x "${HF_CLI}" ]; then
        download_with_huggingface_cli
      elif command -v huggingface-cli >/dev/null 2>&1; then
        HF_CLI="$(command -v huggingface-cli)"
        download_with_huggingface_cli
      else
        echo "[RHOIM] ERROR: neither hf nor huggingface-cli succeeded/exists" >&2
        exit 1
      fi
    fi
  else
    # no hf in venv; try huggingface-cli
    if [ -x "${HF_CLI}" ]; then
      echo "[RHOIM] Running: huggingface-cli download ${VLLM_MODEL}"
      download_with_huggingface_cli
    elif command -v huggingface-cli >/dev/null 2>&1; then
      HF_CLI="$(command -v huggingface-cli)"
      echo "[RHOIM] Running: huggingface-cli download ${VLLM_MODEL}"
      download_with_huggingface_cli
    else
      echo "[RHOIM] ERROR: hf/huggingface-cli not found" >&2
      exit 1
    fi
  fi
fi

# -----------------------------
# vLLM args
# -----------------------------
ARGS=(
  --model "${LOCAL_MODEL_DIR}"
  --host "${HOST}"
  --port "${PORT}"
)

if [[ "${DEVICE}" == "cuda" ]]; then
  echo "[RHOIM] Starting vLLM in CUDA mode"
  ARGS+=(--device cuda)
else
  echo "[RHOIM] Starting vLLM in CPU mode"
  echo "[RHOIM] CPU knobs: MAX_MODEL_LEN=${MAX_MODEL_LEN} VLLM_BLOCK_SIZE=${VLLM_BLOCK_SIZE} VLLM_SWAP_SPACE_GB=${VLLM_SWAP_SPACE_GB}"

  ARGS+=(
    --device cpu
    --dtype "${DTYPE}"
    --max-model-len "${MAX_MODEL_LEN}"
    --block-size "${VLLM_BLOCK_SIZE}"
    --swap-space "${VLLM_SWAP_SPACE_GB}"
    --enforce-eager
    --disable-async-output-proc
    --disable-frontend-multiprocessing
  )

  # Hard-disable CUDA discovery in CPU mode
  export CUDA_VISIBLE_DEVICES=""
  export VLLM_NO_CUDA=1
  export VLLM_TARGET_DEVICE=cpu
fi

if [[ -n "${VLLM_EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_ARR=(${VLLM_EXTRA_ARGS})
  ARGS+=("${EXTRA_ARR[@]}")
fi

echo "[RHOIM] Final vLLM args: ${ARGS[*]}"
exec "${PYTHON_CMD}" -m vllm.entrypoints.openai.api_server "${ARGS[@]}"