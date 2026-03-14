#!/bin/bash
set -e

# Build script for SPIRV-Cross
# Outputs a relocatable package with libraries and headers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"
SPIRV_CROSS_VERSION="${SPIRV_CROSS_VERSION:-main}"

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

echo "Building SPIRV-Cross for $PLATFORM..."

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

# Clone SPIRV-Cross
if [ ! -d "spirv-cross" ]; then
    echo "Cloning SPIRV-Cross..."
    git clone --depth 1 --branch "$SPIRV_CROSS_VERSION" https://github.com/KhronosGroup/SPIRV-Cross.git spirv-cross
fi

# Build SPIRV-Cross
cd spirv-cross
mkdir -p build
cd build

# Set up architecture for cross-compilation
CMAKE_ARCH_FLAG=""
CMAKE_OSX_ARCH_FLAG=""

# Windows cross-compilation
if [ -n "$CMAKE_ARCH" ]; then
    CMAKE_ARCH_FLAG="-A $CMAKE_ARCH"
fi

# macOS cross-compilation (arm64 runner can build x86_64)
if [ -n "$MACOS_ARCH" ]; then
    CMAKE_OSX_ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCH"
fi

cmake .. \
    $CMAKE_ARCH_FLAG \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DSPIRV_CROSS_SHARED=OFF \
    -DSPIRV_CROSS_STATIC=ON \
    -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF

cmake --build . --config Release -j$NCPU

# Package output
PACKAGE_DIR="$OUTPUT_DIR/spirv-cross-$PLATFORM"
mkdir -p "$PACKAGE_DIR"

# Copy libraries
echo "Packaging libraries..."
find . -name "*.a" -exec cp {} "$PACKAGE_DIR/" \;
find . -name "*.lib" -exec cp {} "$PACKAGE_DIR/" \;
find . -name "*.so" -exec cp {} "$PACKAGE_DIR/" \;
find . -name "*.dylib" -exec cp {} "$PACKAGE_DIR/" \;

# Copy headers (preserving directory structure)
echo "Packaging headers..."
cd "$BUILD_DIR/spirv-cross"
find . -name "*.h" -o -name "*.hpp" | while read header; do
    mkdir -p "$PACKAGE_DIR/$(dirname "$header")"
    cp "$header" "$PACKAGE_DIR/$header"
done

# Create archive
cd "$OUTPUT_DIR"
if [[ "$PLATFORM" == windows-* ]]; then
    # Use PowerShell Compress-Archive on Windows (zip not available in Git Bash)
    powershell -Command "Compress-Archive -Path 'spirv-cross-$PLATFORM' -DestinationPath 'spirv-cross-${PLATFORM}.zip' -Force"
    echo "Created: spirv-cross-${PLATFORM}.zip"
else
    tar -czf "spirv-cross-${PLATFORM}.tar.gz" "spirv-cross-$PLATFORM"
    echo "Created: spirv-cross-${PLATFORM}.tar.gz"
fi

echo "Build complete!"
