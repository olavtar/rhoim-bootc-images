#!/usr/bin/env bash
set -euo pipefail

if [ -f "/etc/sysconfig/rhoim" ]; then
  # shellcheck disable=SC1091
  source /etc/sysconfig/rhoim
fi

VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
HOST="${HOST:-${VLLM_HOST:-0.0.0.0}}"
PORT="${PORT:-${VLLM_PORT:-8000}}"
MODEL_PATH="${MODEL_PATH:-/tmp/models}"
DTYPE="${DTYPE:-float32}"
VLLM_DEVICE_TYPE="${VLLM_DEVICE_TYPE:-auto}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

have_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
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

echo "[RHOIM] Testing Python SSL configuration..."
/opt/vllm-venv/bin/python -c "
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

  HF_CLI="/opt/vllm-venv/bin/huggingface-cli"
  if [ ! -x "${HF_CLI}" ]; then
    if command -v huggingface-cli >/dev/null 2>&1; then
      HF_CLI="$(command -v huggingface-cli)"
    else
      echo "[RHOIM] ERROR: huggingface-cli not found (tried /opt/vllm-venv and PATH)" >&2
      exit 1
    fi
  fi

  export REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  export SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  export CURL_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

  echo "[RHOIM] Running: ${HF_CLI} download ${VLLM_MODEL}"
  "${HF_CLI}" download "${VLLM_MODEL}" \
    --local-dir "${LOCAL_MODEL_DIR}" \
    --local-dir-use-symlinks False
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

  # IMPORTANT: avoid worker_cls='auto' crash in vLLM 0.6.6 CPU executor
  ARGS+=(
    --device cpu
    --dtype "${DTYPE}"
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

if [ -x "/opt/vllm-venv/bin/python3.11" ]; then
  PYTHON_CMD="/opt/vllm-venv/bin/python3.11"
else
  PYTHON_CMD="/opt/vllm-venv/bin/python"
fi

echo "[RHOIM] Using Python: ${PYTHON_CMD}"
echo "[RHOIM] Final vLLM args: ${ARGS[*]}"

exec "${PYTHON_CMD}" -m vllm.entrypoints.openai.api_server "${ARGS[@]}"