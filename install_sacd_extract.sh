#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "--- 1. Installing build dependencies ---"
sudo apt update
sudo apt install -y git build-essential cmake libssl-dev zlib1g-dev libxml2-dev

# Create a temporary directory for the build process
BUILD_DIR=$(mktemp -d)
cd "$BUILD_DIR"

echo "--- 2. Cloning the repository ---"
git clone https://github.com/Sound-Linux-More/sacd-extract.git
cd sacd-extract

echo "--- 3. Configuring the build environment ---"
mkdir build
cd build

# - CMAKE_POLICY_VERSION_MINIMUM=3.5: Prevents CMake 4.x from failing on legacy <3.5 policies
# - CMAKE_C_FLAGS: Downgrades strict pointer checks back to warnings on modern GCC
cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="-Wno-error=incompatible-pointer-types -Wno-error=int-conversion" ..

echo "--- 4. Compiling with $(nproc) threads ---"
make -j$(nproc)

echo "--- 5. Installing to /usr/local/bin ---"
sudo cp sacd_extract /usr/local/bin/

echo "--- 6. Cleaning up ---"
rm -rf "$BUILD_DIR"

echo "-------------------------------------------------------"
echo "Installation complete!"
echo "Verify the installation by running: sacd_extract --help"
echo "-------------------------------------------------------"
