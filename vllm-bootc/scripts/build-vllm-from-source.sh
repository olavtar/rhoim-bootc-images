#!/usr/bin/env bash
# Build vLLM from source for both amd64 and arm64 architectures
# This script handles the complete build process including NUMA stub creation

set -euo pipefail

echo "⚠️  DEPRECATED: build-vllm-from-source.sh"
echo "    This script is no longer used by the default RHOIM build."
echo "    RHOIM now consumes the supported RHAIIS vLLM images instead."
echo
echo "    This script is kept for reference only and may be removed in a future release."
echo "    Do NOT rely on it for production builds."
echo

exit 1

VLLM_VERSION="${1:-0.10.2}"
VLLM_SRC_DIR="/tmp/vllm-src"
NUMA_STUB_DIR="/tmp/numa_stub"

echo "[vLLM Build] Starting vLLM ${VLLM_VERSION} source build..."

# Clone vLLM repository
echo "[vLLM Build] Cloning vLLM repository..."
if ! git clone --depth 1 --branch "v${VLLM_VERSION}" https://github.com/vllm-project/vllm.git "${VLLM_SRC_DIR}" 2>/dev/null; then
    echo "[vLLM Build] Branch v${VLLM_VERSION} not found, using main branch..."
    git clone --depth 1 https://github.com/vllm-project/vllm.git "${VLLM_SRC_DIR}"
fi

cd "${VLLM_SRC_DIR}"

# Install build requirements
echo "[vLLM Build] Installing build requirements..."
pip install --no-cache-dir -r requirements/build.txt
pip install --no-cache-dir -r requirements/cpu.txt

# Handle NUMA: remove -lnuma from CMakeLists.txt and create stub if needed
# This works for both architectures and prevents linker errors
echo "[vLLM Build] Handling NUMA dependencies..."
find . -type f \( -name "*.py" -o -name "CMakeLists.txt" -o -name "*.cmake" \) \
    -exec sed -i 's/-lnuma//g' {} + 2>/dev/null || true

# Create NUMA stub library
echo "[vLLM Build] Creating NUMA stub library..."
mkdir -p "${NUMA_STUB_DIR}"
cat > "${NUMA_STUB_DIR}/numa_stub.c" << 'EOF'
#include <stdlib.h>
int numa_available(void) { return -1; }
void* numa_alloc_onnode(size_t size, int node) { return malloc(size); }
void numa_free(void *start, size_t size) { free(start); }
int numa_node_of_cpu(int cpu) { return 0; }
void numa_run_on_node(int node) {}
EOF

gcc -shared -fPIC -o "${NUMA_STUB_DIR}/libnuma.so" "${NUMA_STUB_DIR}/numa_stub.c" 2>/dev/null || true

# Build vLLM from source
echo "[vLLM Build] Building vLLM from source (this may take a while)..."
CC=/usr/bin/gcc \
CXX=/usr/bin/g++ \
CXXFLAGS="-Wno-error -Wno-psabi -DVLLM_NUMA_DISABLED" \
LDFLAGS="-Wl,--as-needed -L${NUMA_STUB_DIR}" \
CMAKE_BUILD_PARALLEL_LEVEL=1 \
MAX_JOBS=1 \
SETUPTOOLS_SCM_PRETEND_VERSION="${VLLM_VERSION}" \
VLLM_TARGET_DEVICE=cpu \
pip install --no-cache-dir . --no-build-isolation

# Cleanup
echo "[vLLM Build] Cleaning up build artifacts..."
rm -rf "${VLLM_SRC_DIR}" "${NUMA_STUB_DIR}"

echo "[vLLM Build] vLLM ${VLLM_VERSION} build completed successfully!"

