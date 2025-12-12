#!/usr/bin/env bash
set -euo pipefail

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

# Test Python SSL configuration before downloads
echo "[RHOIM] Testing Python SSL configuration..."
/opt/vllm-venv/bin/python -c "
import ssl, requests, os
# Ensure we use system CA certificates
os.environ['REQUESTS_CA_BUNDLE'] = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'
os.environ['SSL_CERT_FILE'] = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'
try:
    resp = requests.get('https://huggingface.co', timeout=10)
    print(f'[RHOIM] SSL test successful: HTTP {resp.status_code}')
except Exception as e:
    print(f'[RHOIM] ERROR: SSL test failed: {e}')
    exit(1)
"

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

    # Set SSL environment variables for huggingface-cli
    export REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    export SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    export CURL_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    
    echo "[RHOIM] Running: ${HF_CLI} download ${VLLM_MODEL}"
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
    ARGS+=(--device cuda)
else
    echo "[RHOIM] Starting vLLM in CPU mode"
    ARGS+=(--device cpu --dtype "${DTYPE}" --enforce-eager)
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

# Prefer python3.11 if our symlink exists, otherwise python
if [ -x "/opt/vllm-venv/bin/python3.11" ]; then
    PYTHON_CMD="/opt/vllm-venv/bin/python3.11"
else
    PYTHON_CMD="/opt/vllm-venv/bin/python"
fi

echo "[RHOIM] Using Python: ${PYTHON_CMD}"
echo "[RHOIM] Final vLLM args: ${ARGS[*]}"

exec "${PYTHON_CMD}" -m vllm.entrypoints.openai.api_server "${ARGS[@]}"