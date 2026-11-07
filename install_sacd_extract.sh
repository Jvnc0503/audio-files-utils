#!/usr/bin/env bash

# Strict mode:
# -e: Exit immediately if a command fails
# -u: Treat unset variables as an error
# -o pipefail: Return the exit status of the last failed command in a pipeline
set -euo pipefail

REPO_URL="https://github.com/Sound-Linux-More/sacd-extract.git"
INSTALL_PATH="/usr/local/bin/sacd_extract"
JOBS="$(nproc)"

# Create a temporary directory and register an EXIT trap for guaranteed cleanup
BUILD_DIR="$(mktemp -d)"
cleanup() {
    if [[ -d "${BUILD_DIR}" ]]; then
        echo "--- 6. Cleaning up temporary build directory ---"
        rm -rf "${BUILD_DIR}"
    fi
}
trap cleanup EXIT

echo "--- 1. Installing build dependencies ---"
sudo apt-get update
sudo apt-get install -y \
    git \
    build-essential \
    cmake \
    libssl-dev \
    zlib1g-dev \
    libxml2-dev

echo "--- 2. Cloning the repository ---"
# --depth 1 fetches only the latest commit, saving bandwidth and time
git clone --depth 1 "${REPO_URL}" "${BUILD_DIR}/sacd-extract"
cd "${BUILD_DIR}/sacd-extract"

echo "--- 3. Configuring the build environment ---"
# - CMAKE_POLICY_VERSION_MINIMUM=3.5: Prevents CMake 4.x from failing on legacy <3.5 policies
# - CMAKE_C_FLAGS: Downgrades strict pointer/int checks back to warnings on GCC 14+
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_FLAGS="-Wno-error=incompatible-pointer-types -Wno-error=int-conversion"

echo "--- 4. Compiling with ${JOBS} threads ---"
cmake --build build --parallel "${JOBS}"

echo "--- 5. Installing to ${INSTALL_PATH} ---"
# 'install' sets explicit ownership (root:root) and executable permissions (0755)
sudo install -m 0755 build/sacd_extract "${INSTALL_PATH}"

echo "-------------------------------------------------------"
echo "Installation complete!"
echo "Verify the installation by running: sacd_extract --help"
echo "-------------------------------------------------------"
