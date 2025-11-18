#!/usr/bin/env bash
set -euo pipefail

# Load env overrides
[ -f /etc/sysconfig/rhoim ] && source /etc/sysconfig/rhoim

: "${MODEL_ID:=TinyLlama/TinyLlama-1.1B-Chat-v1.0}"
: "${MODEL_PATH:=/opt/rhoim/models}"
: "${VLLM_HOST:=0.0.0.0}"
: "${VLLM_PORT:=8000}"
: "${RHOIM_ACCELERATOR_MODE:=auto}"   # auto | gpu | cpu
: "${MAX_MODEL_LEN:=2048}"
: "${VLLM_LOGGING_LEVEL:=INFO}"
: "${VLLM_TAG:=3.2.3}"

RHAIIS_IMG="registry.redhat.io/rhaiis/vllm-cuda-rhel9:${VLLM_TAG}"
VENV_PY="/opt/rhoim/venv/bin/python3"
HF="/opt/rhoim/venv/bin/huggingface-cli"

have_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

# Ensure model is present (used for both CPU and GPU paths)
mkdir -p "${MODEL_PATH}"
if [ ! -d "${MODEL_PATH}/${MODEL_ID}" ] || [ -z "$(ls -A "${MODEL_PATH}/${MODEL_ID}" 2>/dev/null || true)" ]; then
  echo "[RHOIM] Downloading ${MODEL_ID} to ${MODEL_PATH}/${MODEL_ID}"
  "${HF}" download "${MODEL_ID}" \
    --local-dir "${MODEL_PATH}/${MODEL_ID}" \
    --local-dir-use-symlinks False
fi

# Decide mode
MODE="cpu"
if [ "${RHOIM_ACCELERATOR_MODE}" = "gpu" ]; then
  MODE="gpu"
elif [ "${RHOIM_ACCELERATOR_MODE}" = "auto" ] && have_gpu; then
  MODE="gpu"
fi

if [ "${MODE}" = "gpu" ]; then
  echo "[RHOIM] Using GPU via RHAIIS image: ${RHAIIS_IMG}"
  # Pull requires registry.redhat.io auth; no-op if already logged in
  podman login -q registry.redhat.io || true

  exec podman run --rm --name rhoim-vllm \
    --network host \
    --security-opt=label=disable \
    --device nvidia.com/gpu=all \
    -e VLLM_LOGGING_LEVEL="${VLLM_LOGGING_LEVEL}" \
    -v "${MODEL_PATH}:${MODEL_PATH}:z" \
    "${RHAIIS_IMG}" \
      --model "${MODEL_PATH}/${MODEL_ID}" \
      --host "${VLLM_HOST}" \
      --port "${VLLM_PORT}" \
      --max-model-len "${MAX_MODEL_LEN}"
else
  echo "[RHOIM] Using CPU fallback (in-image vLLM)"
  export VLLM_NO_CUDA=1
  export VLLM_LOGGING_LEVEL
  exec "${VENV_PY}" -m vllm.entrypoints.openai.api_server \
      --model "${MODEL_PATH}/${MODEL_ID}" \
      --host "${VLLM_HOST}" \
      --port "${VLLM_PORT}" \
      --device cpu \
      --dtype float32 \
      --max-model-len "${MAX_MODEL_LEN}" \
      --enforce-eager \
      --disable-log-requests
fi
