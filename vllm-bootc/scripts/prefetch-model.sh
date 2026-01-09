#!/usr/bin/env bash
set -euo pipefail

source /etc/sysconfig/rhoim

: "${MODEL_ID:?MODEL_ID is required in /etc/sysconfig/rhoim}"
: "${MODELS_DIR:=/var/lib/rhoim/models}"
: "${HF_HOME:=/var/lib/rhoim/cache}"

TARGET_DIR="${MODELS_DIR}/${MODEL_ID}"

mkdir -p "${MODELS_DIR}" "${HF_HOME}"

# If model already present, skip
if [ -f "${TARGET_DIR}/config.json" ]; then
  echo "[prefetch] Model already present: ${TARGET_DIR}"
  exit 0
fi

echo "[prefetch] Downloading ${MODEL_ID} -> ${TARGET_DIR}"

# Use the RHAIIS image to perform the download so bootc OS doesn't need python tooling
podman run --rm \
  -v "${MODELS_DIR}:/models:Z" \
  -v "${HF_HOME}:/opt/app-root/src/.cache:Z" \
  --env-file /etc/sysconfig/rhoim \
  registry.redhat.io/rhaiis/vllm-cuda-rhel9:latest \
  bash -lc '
    set -euo pipefail
    mkdir -p "/models/${MODEL_ID}"
    huggingface-cli download "${MODEL_ID}" \
      --local-dir "/models/${MODEL_ID}" \
      --local-dir-use-symlinks False
  '

echo "[prefetch] Done."
