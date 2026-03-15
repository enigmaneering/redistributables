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
    # Override with CMAKE_ARCH if provided (for Windows builds)
    if [ -n "$CMAKE_ARCH" ]; then
        if [ "$CMAKE_ARCH" == "x64" ]; then
            ARCH="x86_64"
        elif [ "$CMAKE_ARCH" == "arm64" ]; then
            ARCH="aarch64"
        fi
    fi
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
    git submodule update --init --recursive
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
CMAKE_C_COMPILER=""
CMAKE_CXX_COMPILER=""

# macOS cross-compilation (arm64 runner can build x86_64)
if [ -n "$MACOS_ARCH" ]; then
    CMAKE_OSX_ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCH"
fi

# Windows uses -A for architecture
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    if [ -n "$CMAKE_ARCH" ]; then
        CMAKE_ARCH_FLAG="-A $CMAKE_ARCH"
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
    $CMAKE_ARCH_FLAG \
    $CMAKE_OSX_ARCH_FLAG \
    $CMAKE_SYSTEM_PROCESSOR \
    $CMAKE_C_COMPILER \
    $CMAKE_CXX_COMPILER \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SPIRV_CODEGEN=ON \
    -DSPIRV_BUILD_TESTS=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DHLSL_ENABLE_ANALYZE=OFF \
    -DHLSL_BUILD_DXILCONV=OFF

echo "Building DXC and libdxcompiler (this may take 10-20 minutes)..."
# Build both dxc binary and libdxcompiler shared library
cmake --build . --config Release --target dxc -j$NCPU
cmake --build . --config Release --target libdxcompiler -j$NCPU

# Package output
PACKAGE_DIR="$OUTPUT_DIR/dxc-$PLATFORM"
mkdir -p "$PACKAGE_DIR/bin"
mkdir -p "$PACKAGE_DIR/lib"

# Copy DXC binary and libraries
echo "Packaging DXC..."
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    cp bin/Release/dxc.exe "$PACKAGE_DIR/bin/"
    # Copy DLLs to bin (Windows convention)
    find bin/Release -name "dxcompiler.dll" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null || true
    find bin/Release -name "*.dll" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null || true
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
if [[ "$PLATFORM" == windows-* ]]; then
    # Use PowerShell Compress-Archive on Windows (zip not available in Git Bash)
    powershell -Command "Compress-Archive -Path 'dxc-$PLATFORM' -DestinationPath 'dxc-${PLATFORM}.zip' -Force"
    echo "Created: dxc-${PLATFORM}.zip"
else
    tar -czf "dxc-${PLATFORM}.tar.gz" "dxc-$PLATFORM"
    echo "Created: dxc-${PLATFORM}.tar.gz"
fi

echo "Build complete!"
