#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# RHOIM initializer-entrypoint.sh
# - Loads env overrides from /etc/sysconfig/rhoim
# - Ensures we actually use the venv (PATH + VIRTUAL_ENV)
# - Downloads model if missing (prefers `hf`, falls back to `huggingface-cli`)
# - Selects GPU if available (or forced), otherwise CPU
# - Adds "worker stuff" / CPU safety knobs to avoid known vLLM CPU worker crashes
#   (block_size=None -> NoneType * int) and reduce swap-space warnings.
# ------------------------------------------------------------------------------

if [ -f "/etc/sysconfig/rhoim" ]; then
  # shellcheck disable=SC1091
  source /etc/sysconfig/rhoim
fi

# ---- Force venv to be used (not "activated", but equivalent for runtime) -------
VENV_DIR="${VENV_DIR:-/opt/vllm-venv}"
export VIRTUAL_ENV="${VENV_DIR}"
export PATH="${VENV_DIR}/bin:${PATH}"
export PYTHONUNBUFFERED=1

# Prefer python3.11 if present
if [ -x "${VENV_DIR}/bin/python3.11" ]; then
  PYTHON_CMD="${VENV_DIR}/bin/python3.11"
else
  PYTHON_CMD="${VENV_DIR}/bin/python"
fi

# ---- Config -------------------------------------------------------------------
VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
HOST="${HOST:-${VLLM_HOST:-0.0.0.0}}"
PORT="${PORT:-${VLLM_PORT:-8000}}"
MODEL_PATH="${MODEL_PATH:-/tmp/models}"
DTYPE="${DTYPE:-float32}"
VLLM_DEVICE_TYPE="${VLLM_DEVICE_TYPE:-auto}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

# CPU “worker stuff” / safety knobs (env-overridable)
MAX_MODEL_LEN="${MAX_MODEL_LEN:-2048}"
VLLM_BLOCK_SIZE="${VLLM_BLOCK_SIZE:-16}"     # Avoid block_size=None issues
VLLM_SWAP_SPACE="${VLLM_SWAP_SPACE:-1}"      # GiB; reduce “too large swap space” warning
VLLM_CPU_OFFLOAD_GB="${VLLM_CPU_OFFLOAD_GB:-0}"

# ---- Helpers ------------------------------------------------------------------
have_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

is_port_free() {
  local p="$1"
  ! (ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$") \
    && ! (netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$") \
    && ! (lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk '{print $9}' | grep -qE "[:.]${p}\$")
}

pick_free_port() {
  local p="$1"
  local tries=20
  while [ "${tries}" -gt 0 ]; do
    if is_port_free "${p}"; then
      echo "${p}"
      return 0
    fi
    p=$((p+1))
    tries=$((tries-1))
  done
  echo "[RHOIM] ERROR: could not find a free port starting at ${PORT}" >&2
  exit 1
}

# ---- Device selection ----------------------------------------------------------
DEVICE="cpu"
if [[ "${VLLM_DEVICE_TYPE}" == "cuda" ]]; then
  DEVICE="cuda"
elif [[ "${VLLM_DEVICE_TYPE}" == "auto" ]] && have_gpu; then
  DEVICE="cuda"
fi

echo "[RHOIM] Using Python: ${PYTHON_CMD}"
echo "[RHOIM] VLLM_MODEL=${VLLM_MODEL}"
echo "[RHOIM] HOST=${HOST} PORT=${PORT}"
echo "[RHOIM] MODEL_PATH=${MODEL_PATH}"
echo "[RHOIM] Requested VLLM_DEVICE_TYPE=${VLLM_DEVICE_TYPE}, selected DEVICE=${DEVICE}"
echo "[RHOIM] CPU knobs: MAX_MODEL_LEN=${MAX_MODEL_LEN} VLLM_BLOCK_SIZE=${VLLM_BLOCK_SIZE} VLLM_SWAP_SPACE=${VLLM_SWAP_SPACE}GiB"

# ---- Quick sanity: show vLLM + torch versions (useful in journald) -------------
"${PYTHON_CMD}" -c "import sys; print('[RHOIM] python=', sys.executable);"
"${PYTHON_CMD}" -c "import vllm, torch; print('[RHOIM] vllm=', getattr(vllm,'__version__','?'), 'torch=', getattr(torch,'__version__','?'))" || true

# ---- SSL sanity check ----------------------------------------------------------
echo "[RHOIM] Testing Python SSL configuration..."
"${PYTHON_CMD}" -c "
import requests, os
os.environ['REQUESTS_CA_BUNDLE'] = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'
os.environ['SSL_CERT_FILE'] = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'
resp = requests.get('https://huggingface.co', timeout=10)
print(f'[RHOIM] SSL test successful: HTTP {resp.status_code}')
"

# ---- Model download ------------------------------------------------------------
mkdir -p "${MODEL_PATH}"
LOCAL_MODEL_DIR="${MODEL_PATH}/${VLLM_MODEL}"

if [ ! -d "${LOCAL_MODEL_DIR}" ] || [ -z "$(ls -A "${LOCAL_MODEL_DIR}" 2>/dev/null || true)" ]; then
  echo "[RHOIM] Downloading ${VLLM_MODEL} to ${LOCAL_MODEL_DIR}"

  export REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  export SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  export CURL_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

  # Prefer `hf` (new CLI), fallback to `huggingface-cli`
  if command -v hf >/dev/null 2>&1; then
    echo "[RHOIM] Running: hf download ${VLLM_MODEL}"
    hf download "${VLLM_MODEL}" \
      --local-dir "${LOCAL_MODEL_DIR}" \
      --local-dir-use-symlinks False
  else
    HF_CLI="${VENV_DIR}/bin/huggingface-cli"
    if [ ! -x "${HF_CLI}" ]; then
      if command -v huggingface-cli >/dev/null 2>&1; then
        HF_CLI="$(command -v huggingface-cli)"
      else
        echo "[RHOIM] ERROR: neither 'hf' nor 'huggingface-cli' found" >&2
        exit 1
      fi
    fi
    echo "[RHOIM] Running: ${HF_CLI} download ${VLLM_MODEL}"
    "${HF_CLI}" download "${VLLM_MODEL}" \
      --local-dir "${LOCAL_MODEL_DIR}" \
      --local-dir-use-symlinks False
  fi
fi

# ---- Port selection (avoid vLLM auto-bumping inside and confusing systemd) -----
PORT="$(pick_free_port "${PORT}")"
echo "[RHOIM] Selected free PORT=${PORT}"

# ---- Build args ----------------------------------------------------------------
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

  # CPU “worker stuff”:
  # - Force CPUWorker
  # - Disable async output proc
  # - Disable frontend multiprocessing
  # - Force a non-null block size (avoids NoneType * int crash you’re seeing)
  # - Keep swap-space sane for small VMs
  ARGS+=(
    --device cpu
    --dtype "${DTYPE}"
    --max-model-len "${MAX_MODEL_LEN}"
    --block-size "${VLLM_BLOCK_SIZE}"
    --swap-space "${VLLM_SWAP_SPACE}"
    --cpu-offload-gb "${VLLM_CPU_OFFLOAD_GB}"
    --enforce-eager
    --disable-async-output-proc
    --disable-frontend-multiprocessing
    --worker-cls vllm.worker.cpu_worker.CPUWorker
  )

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