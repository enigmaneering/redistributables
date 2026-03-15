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

echo "Building DXC for $PLATFORM..."

# Detect number of CPU cores
# DXC is a huge LLVM project - limit parallelism to avoid OOM on CI runners
if [[ "$OSTYPE" == "darwin"* ]]; then
    NCPU=$(sysctl -n hw.ncpu)
    # Limit to half cores on macOS to avoid memory issues
    NCPU=$((NCPU / 2))
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    NCPU=$(nproc)
    # Limit to 2 cores on Linux (GitHub runners have limited memory)
    NCPU=2
else
    NCPU=2
fi

# Ensure at least 1 core
if [ "$NCPU" -lt 1 ]; then
    NCPU=1
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
    GIT_TERMINAL_PROMPT=0 git submodule update --init --recursive --depth 1
fi

# Patch CMakeLists.txt files for newer CMake compatibility
echo "Patching CMakeLists.txt files for newer CMake compatibility..."
sed -i.bak '/cmake_policy(SET CMP0051 OLD)/d' CMakeLists.txt

# Patch tools/clang/CMakeLists.txt to update minimum CMake version
if [ -f tools/clang/CMakeLists.txt ]; then
    sed -i.bak 's/cmake_minimum_required(VERSION [0-9.]*)/cmake_minimum_required(VERSION 3.5)/' tools/clang/CMakeLists.txt
fi

# Build DXC
mkdir -p build
cd build

# Set up architecture for cross-compilation
CMAKE_ARCH_FLAG=""
CMAKE_OSX_ARCH_FLAG=""
CMAKE_SYSTEM_PROCESSOR=""
CMAKE_LINKER=""
CMAKE_C_COMPILER=""
CMAKE_CXX_COMPILER=""
CMAKE_SHARED_LINKER_FLAGS=""

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
        LLVM_MINGW_DIR="$(pwd)/llvm-mingw-20260311-ucrt-x86_64"
        LLVM_MINGW_ROOT="$(cygpath -w "$LLVM_MINGW_DIR" 2>/dev/null || echo "$LLVM_MINGW_DIR")"
        CMAKE_C_COMPILER="-DCMAKE_C_COMPILER=${LLVM_MINGW_ROOT}/bin/clang.exe"
        CMAKE_CXX_COMPILER="-DCMAKE_CXX_COMPILER=${LLVM_MINGW_ROOT}/bin/clang++.exe"
        CMAKE_SYSTEM_PROCESSOR="-DCMAKE_SYSTEM_PROCESSOR=aarch64"
        CMAKE_SHARED_LINKER_FLAGS="-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld"
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

echo "Configuring DXC..."
# Use cache file first, then override with our flags
# Note: DXC builds libdxcompiler as a shared library by default
# We keep BUILD_SHARED_LIBS=OFF but also build the dylib target
cmake .. \
    -C ../cmake/caches/PredefinedParams.cmake \
    $CMAKE_GENERATOR \
    $CMAKE_ARCH_FLAG \
    $CMAKE_OSX_ARCH_FLAG \
    $CMAKE_SYSTEM_PROCESSOR \
    $CMAKE_C_COMPILER \
    $CMAKE_CXX_COMPILER \
    $CMAKE_LINKER \
    $CMAKE_SHARED_LINKER_FLAGS \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SPIRV_CODEGEN=ON \
    -DSPIRV_BUILD_TESTS=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DHLSL_ENABLE_ANALYZE=OFF \
    -DHLSL_BUILD_DXILCONV=OFF \
    -DHLSL_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF

echo "Building DXC (this may take 10-20 minutes)..."
# Building dxc automatically builds dxcompiler as a dependency
cmake --build . --config Release --target dxc -j$NCPU

# Package output
PACKAGE_DIR="$OUTPUT_DIR/dxc-$PLATFORM"
mkdir -p "$PACKAGE_DIR/bin"
mkdir -p "$PACKAGE_DIR/lib"

# Copy DXC binary and libraries
echo "Packaging DXC..."
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    # MinGW builds - binaries in bin/ not bin/Release/
    cp bin/dxc.exe "$PACKAGE_DIR/bin/" 2>/dev/null || cp bin/dxc "$PACKAGE_DIR/bin/"
    # Copy shared libraries
    find bin -name "dxcompiler.dll" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null || true
    find bin -name "libdxcompiler.dll" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null || true
    find lib -name "*.dll" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null || true
else
    cp bin/dxc "$PACKAGE_DIR/bin/"
    # Copy shared libraries to lib directory
    find lib -name "libdxcompiler.so*" -exec cp {} "$PACKAGE_DIR/lib/" \; 2>/dev/null || true
    find lib -name "libdxcompiler.dylib" -exec cp {} "$PACKAGE_DIR/lib/" \; 2>/dev/null || true

    # On macOS, update rpath in dxc binary to find dylib in ../lib
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "Fixing rpath for macOS..."
        # Change @rpath to @executable_path/../lib
        install_name_tool -change @rpath/libdxcompiler.dylib @executable_path/../lib/libdxcompiler.dylib "$PACKAGE_DIR/bin/dxc" 2>/dev/null || true

        echo "DXC dependencies after rpath fix:"
        otool -L "$PACKAGE_DIR/bin/dxc"
    fi

    # On Linux, verify library was copied
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "DXC dependencies:"
        ldd "$PACKAGE_DIR/bin/dxc" || true
    fi
fi

# Create archive
cd "$OUTPUT_DIR"
tar -czf "dxc-${PLATFORM}.tar.gz" "dxc-$PLATFORM"
echo "Created: dxc-${PLATFORM}.tar.gz"

echo "Build complete!"
