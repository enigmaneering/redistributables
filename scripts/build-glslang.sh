#!/bin/bash
set -e

# Build script for glslang + SPIRV-Tools
# Outputs a relocatable package with libraries and headers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"
GLSLANG_VERSION="${GLSLANG_VERSION:-main}"

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

echo "Building glslang for $PLATFORM..."

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

# Clone glslang
if [ ! -d "glslang" ]; then
    echo "Cloning glslang..."
    git clone --depth 1 --branch "$GLSLANG_VERSION" https://github.com/KhronosGroup/glslang.git
fi

# Clone SPIRV-Tools
if [ ! -d "spirv-tools" ]; then
    echo "Cloning SPIRV-Tools..."
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
fi

# Clone SPIRV-Headers (needed by SPIRV-Tools)
if [ ! -d "spirv-tools/external/spirv-headers" ]; then
    echo "Cloning SPIRV-Headers..."
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-tools/external/spirv-headers
fi

# Create symlink for glslang to find SPIRV-Tools
mkdir -p glslang/External
rm -rf glslang/External/spirv-tools
ln -sf ../../spirv-tools glslang/External/spirv-tools

# Build glslang
cd glslang
mkdir -p build
cd build

# Set up architecture for cross-compilation on Windows
CMAKE_ARCH_FLAG=""
if [ -n "$CMAKE_ARCH" ]; then
    CMAKE_ARCH_FLAG="-A $CMAKE_ARCH"
fi

cmake .. \
    $CMAKE_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_SPVREMAPPER=OFF \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DENABLE_CTEST=OFF \
    -DENABLE_OPT=ON \
    -DGLSLANG_TESTS=OFF

cmake --build . --config Release -j$NCPU

# Package output
PACKAGE_DIR="$OUTPUT_DIR/glslang-$PLATFORM"
mkdir -p "$PACKAGE_DIR"

# Copy libraries
echo "Packaging libraries..."
find . -name "*.a" -exec cp {} "$PACKAGE_DIR/" \;
find . -name "*.lib" -exec cp {} "$PACKAGE_DIR/" \;
find . -name "*.so" -exec cp {} "$PACKAGE_DIR/" \;
find . -name "*.dylib" -exec cp {} "$PACKAGE_DIR/" \;

# Copy headers (preserving directory structure)
echo "Packaging headers..."
cd "$BUILD_DIR/glslang"
find . -name "*.h" -o -name "*.hpp" | while read header; do
    mkdir -p "$PACKAGE_DIR/$(dirname "$header")"
    cp "$header" "$PACKAGE_DIR/$header"
done

# Create tarball
cd "$OUTPUT_DIR"
if [[ "$PLATFORM" == windows-* ]]; then
    zip -r "glslang-${PLATFORM}.zip" "glslang-$PLATFORM"
    echo "Created: glslang-${PLATFORM}.zip"
else
    tar -czf "glslang-${PLATFORM}.tar.gz" "glslang-$PLATFORM"
    echo "Created: glslang-${PLATFORM}.tar.gz"
fi

echo "Build complete!"
