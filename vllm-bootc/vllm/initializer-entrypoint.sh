#!/usr/bin/env bash
set -euo pipefail

if [ -f "/etc/sysconfig/rhoim" ]; then
  # shellcheck disable=SC1091
  source /etc/sysconfig/rhoim
fi

# Force venv usage
VENV_DIR="${VENV_DIR:-/opt/vllm-venv}"
export VIRTUAL_ENV="${VENV_DIR}"
export PATH="${VENV_DIR}/bin:${PATH}"
export PYTHONUNBUFFERED=1

if [ -x "${VENV_DIR}/bin/python3.11" ]; then
  PYTHON_CMD="${VENV_DIR}/bin/python3.11"
else
  PYTHON_CMD="${VENV_DIR}/bin/python"
fi

VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
HOST="${HOST:-${VLLM_HOST:-0.0.0.0}}"
PORT="${PORT:-${VLLM_PORT:-8000}}"
MODEL_PATH="${MODEL_PATH:-/tmp/models}"
DTYPE="${DTYPE:-float32}"
VLLM_DEVICE_TYPE="${VLLM_DEVICE_TYPE:-auto}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

MAX_MODEL_LEN="${MAX_MODEL_LEN:-2048}"
VLLM_BLOCK_SIZE="${VLLM_BLOCK_SIZE:-16}"
VLLM_SWAP_SPACE="${VLLM_SWAP_SPACE:-1}"     # GiB
VLLM_CPU_OFFLOAD_GB="${VLLM_CPU_OFFLOAD_GB:-0}"

have_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

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

"${PYTHON_CMD}" -c "import sys; print('[RHOIM] python=', sys.executable);"
"${PYTHON_CMD}" -c "import vllm, torch; print('[RHOIM] vllm=', getattr(vllm,'__version__','?'), 'torch=', getattr(torch,'__version__','?'))" || true

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

if [ ! -d "${LOCAL_MODEL_DIR}" ] || [ -z "$(ls -A "${LOCAL_MODEL_DIR}" 2>/dev/null || true)" ]; then
  echo "[RHOIM] Downloading ${VLLM_MODEL} to ${LOCAL_MODEL_DIR}"

  export REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  export SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  export CURL_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

  if command -v hf >/dev/null 2>&1; then
    # `hf download` exists, but flags differ by version; keep it minimal.
    echo "[RHOIM] Running: hf download ${VLLM_MODEL}"
    hf download "${VLLM_MODEL}" \
      --local-dir "${LOCAL_MODEL_DIR}"
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