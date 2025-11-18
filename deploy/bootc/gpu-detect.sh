#!/usr/bin/env bash
set -euo pipefail
# Return 0 if NVIDIA GPUs are usable (driver + toolkit expose nvidia-smi)
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  exit 0
fi
exit 1
