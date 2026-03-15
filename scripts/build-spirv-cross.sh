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
    ARCH=$(uname -m)
    # Override with MACOS_ARCH if provided (for cross-compilation)
    if [ -n "$MACOS_ARCH" ]; then
        ARCH="$MACOS_ARCH"
    fi
    PLATFORM="darwin-$ARCH"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux-$(uname -m)"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    # Use CROSS_COMPILE_TARGET if set, otherwise detect from uname
    if [ -n "$CROSS_COMPILE_TARGET" ]; then
        ARCH="$CROSS_COMPILE_TARGET"
    else
        ARCH=$(uname -m)
    fi
    PLATFORM="windows-$ARCH"
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
CMAKE_SYSTEM_PROCESSOR=""
CMAKE_LINKER=""
CMAKE_C_COMPILER=""
CMAKE_CXX_COMPILER=""

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
        # It's extracted in the repository root during the workflow
        # Convert to Windows path for CMake
        LLVM_MINGW_DIR="$SCRIPT_DIR/../llvm-mingw-20260311-ucrt-x86_64"
        # Resolve to absolute path and convert to Windows path for CMake
        if [ -d "$LLVM_MINGW_DIR" ]; then
            LLVM_MINGW_ABS="$(cd "$LLVM_MINGW_DIR" && pwd)"
            LLVM_MINGW_ROOT="$(cygpath -w "$LLVM_MINGW_ABS" 2>/dev/null || echo "$LLVM_MINGW_ABS")"
        else
            echo "ERROR: llvm-mingw directory not found at $LLVM_MINGW_DIR"
            exit 1
        fi
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
tar -czf "spirv-cross-${PLATFORM}.tar.gz" "spirv-cross-$PLATFORM"
echo "Created: spirv-cross-${PLATFORM}.tar.gz"

echo "Build complete!"
