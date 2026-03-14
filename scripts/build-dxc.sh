#!/bin/bash
set -e

# Build script for DXC (DirectX Shader Compiler)
# Builds from source for all platforms (especially macOS where Microsoft doesn't provide binaries)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"
DXC_VERSION="${DXC_VERSION:-v1.8.2407}"

# Detect platform
if [[ "$OSTYPE" == "darwin"* ]]; then
    PLATFORM="darwin-$(uname -m)"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux-$(uname -m)"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    PLATFORM="windows-$(uname -m)"
fi

# Normalize architecture names
PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')

echo "Building DXC for $PLATFORM..."

# Detect number of CPU cores
if [[ "$OSTYPE" == "darwin"* ]]; then
    NCPU=$(sysctl -n hw.ncpu)
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    NCPU=$(nproc)
else
    NCPU=4
fi

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone DXC
if [ ! -d "dxc" ]; then
    echo "Cloning DirectXShaderCompiler..."
    git clone --depth 1 --branch "$DXC_VERSION" https://github.com/microsoft/DirectXShaderCompiler.git dxc
fi

cd dxc

# Initialize submodules
if [ ! -f "external/SPIRV-Headers/README.md" ]; then
    echo "Initializing submodules..."
    git submodule update --init --recursive
fi

# Build DXC
mkdir -p build
cd build

# Set up architecture for cross-compilation on Windows
CMAKE_ARCH_FLAG=""
if [ -n "$CMAKE_ARCH" ]; then
    CMAKE_ARCH_FLAG="-A $CMAKE_ARCH"
fi

echo "Configuring DXC..."
# DXC only needs DXIL target, not full LLVM targets
# Setting to "None" avoids the default AMDGPU target that doesn't exist in DXC
cmake .. \
    $CMAKE_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD="None" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DCLANG_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DENABLE_SPIRV_CODEGEN=ON \
    -DSPIRV_BUILD_TESTS=OFF

echo "Building DXC (this may take 10-20 minutes)..."
cmake --build . --config Release --target dxc -j$NCPU

# Package output
PACKAGE_DIR="$OUTPUT_DIR/dxc-$PLATFORM"
mkdir -p "$PACKAGE_DIR/bin"

# Copy DXC binary
echo "Packaging DXC..."
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    cp bin/Release/dxc.exe "$PACKAGE_DIR/bin/"
    # Copy required DLLs
    find bin/Release -name "*.dll" -exec cp {} "$PACKAGE_DIR/bin/" \;
else
    cp bin/dxc "$PACKAGE_DIR/bin/"
    # Copy shared libraries if they exist
    find bin -name "*.so" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null || true
    find bin -name "*.dylib" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null || true
fi

# Create archive
cd "$OUTPUT_DIR"
if [[ "$PLATFORM" == windows-* ]]; then
    # Use PowerShell Compress-Archive on Windows (zip not available in Git Bash)
    powershell -Command "Compress-Archive -Path 'dxc-$PLATFORM' -DestinationPath 'dxc-${PLATFORM}.zip' -Force"
    echo "Created: dxc-${PLATFORM}.zip"
else
    tar -czf "dxc-${PLATFORM}.tar.gz" "dxc-$PLATFORM"
    echo "Created: dxc-${PLATFORM}.tar.gz"
fi

echo "Build complete!"
