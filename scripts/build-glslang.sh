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
    ARCH=$(uname -m)
    # Override with MACOS_ARCH if provided (for cross-compilation)
    if [ -n "$MACOS_ARCH" ]; then
        ARCH="$MACOS_ARCH"
    fi
    PLATFORM="darwin-$ARCH"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux-$(uname -m)"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    ARCH=$(uname -m)
    PLATFORM="windows-$ARCH"
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

# Set up architecture for cross-compilation
CMAKE_ARCH_FLAG=""
CMAKE_OSX_ARCH_FLAG=""
CMAKE_SYSTEM_PROCESSOR=""
CMAKE_C_COMPILER=""
CMAKE_CXX_COMPILER=""
CMAKE_LINKER=""
CMAKE_C_FLAGS=""
CMAKE_CXX_FLAGS=""
CMAKE_EXE_LINKER_FLAGS=""

# macOS cross-compilation (arm64 runner can build x86_64)
if [ -n "$MACOS_ARCH" ]; then
    CMAKE_OSX_ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCH"
fi

# Windows uses Ninja generator with MinGW
CMAKE_GENERATOR=""
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    CMAKE_GENERATOR="-G Ninja"
    echo "Using MinGW with Ninja generator"

    # Cross-compilation for ARM64 using Clang
    if [ -n "$CROSS_COMPILE_TARGET" ] && [ "$CROSS_COMPILE_TARGET" = "aarch64" ]; then
        echo "Cross-compiling to ARM64 using Clang"
        # Use the llvm-mingw Clang which has ARM64 support
        LLVM_MINGW_ROOT="D:/a/_temp/build/llvm-mingw-20260311-ucrt-x86_64"
        CMAKE_C_COMPILER="-DCMAKE_C_COMPILER=${LLVM_MINGW_ROOT}/bin/clang.exe"
        CMAKE_CXX_COMPILER="-DCMAKE_CXX_COMPILER=${LLVM_MINGW_ROOT}/bin/clang++.exe"
        CMAKE_SYSTEM_PROCESSOR="-DCMAKE_SYSTEM_PROCESSOR=aarch64"
        # Set flags as environment variables to avoid shell quoting issues
        export CFLAGS="--target=aarch64-w64-mingw32"
        export CXXFLAGS="--target=aarch64-w64-mingw32"
        export LDFLAGS=""
    fi
fi

# Linux cross-compilation for ARM64
if [[ "$OSTYPE" == "linux-gnu"* ]] && [ -n "$CMAKE_ARCH" ] && [ "$CMAKE_ARCH" = "aarch64" ]; then
    CMAKE_SYSTEM_PROCESSOR="-DCMAKE_SYSTEM_PROCESSOR=aarch64"
    CMAKE_C_COMPILER="-DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc"
    CMAKE_CXX_COMPILER="-DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++"
fi

cmake .. \
    $CMAKE_GENERATOR \
    $CMAKE_ARCH_FLAG \
    $CMAKE_OSX_ARCH_FLAG \
    $CMAKE_SYSTEM_PROCESSOR \
    $CMAKE_C_COMPILER \
    $CMAKE_CXX_COMPILER \
    $CMAKE_LINKER \
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

# Create archive
cd "$OUTPUT_DIR"
tar -czf "glslang-${PLATFORM}.tar.gz" "glslang-$PLATFORM"
echo "Created: glslang-${PLATFORM}.tar.gz"

echo "Build complete!"
