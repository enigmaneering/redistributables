#!/bin/bash
set -e

# Build script for clspv (OpenCL C to Vulkan SPIR-V compiler)
# - Builds from source on all platforms (no prebuilt releases available)
# - LLVM-based (like DXC) — uses python3 utils/fetch_sources.py for dependencies
# - Output: single static binary (no shared library needed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

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
    PLATFORM="windows-$(uname -m)"
fi

# Normalize architecture names
PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')

# Handle Windows ARM64 cross-compilation
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    if [ -n "$CROSS_COMPILE_TARGET" ] && [ "$CROSS_COMPILE_TARGET" = "aarch64" ]; then
        PLATFORM="windows-arm64"
    fi
fi

echo "Building clspv for $PLATFORM..."

# Detect number of CPU cores
# clspv is a huge LLVM project — limit parallelism to avoid OOM on CI runners
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

echo "Using $NCPU parallel jobs"

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone clspv (no tagged releases — build from main)
if [ ! -d "clspv" ]; then
    echo "Cloning clspv..."
    set +e
    git clone https://github.com/google/clspv.git clspv
    CLONE_EXIT=$?
    set -e

    if [ $CLONE_EXIT -ne 0 ]; then
        if [ -d "clspv/.git" ]; then
            echo "Warning: git clone exited with code $CLONE_EXIT but repository was created successfully"
            echo "  (MSYS2 git on Windows commonly returns non-zero for benign checkout warnings)"
        else
            echo "Error: git clone failed (exit code $CLONE_EXIT)"
            exit 1
        fi
    fi
fi

cd clspv

# Find Python — MSYS2 may only provide "python", not "python3".
# The trailing "|| true" prevents set -e from killing the script before
# our explicit check can print a useful error message.
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [ -z "$PYTHON" ]; then
    echo "Error: Python not found (needed for utils/fetch_sources.py)"
    echo "PATH=$PATH"
    exit 1
fi
echo "Using Python: $PYTHON"

# Fetch dependencies (LLVM, Clang, SPIRV-Tools, SPIRV-Headers, libclc)
# clspv uses its own fetch script instead of git submodules
if [ ! -d "third_party/llvm" ]; then
    echo "Fetching clspv dependencies (LLVM, SPIRV-Tools, etc.)..."
    $PYTHON utils/fetch_sources.py
fi

# Verify license exists before building (fail fast)
echo "Verifying license file..."
if [ ! -f "LICENSE" ]; then
    echo "Error: LICENSE not found in clspv repository"
    exit 1
fi
echo "License file verified (Apache 2.0 with LLVM Exceptions)"

# Build clspv
mkdir -p build
cd build

# Set up architecture for cross-compilation
CMAKE_OSX_ARCH_FLAG=""
CMAKE_SYSTEM_PROCESSOR=""
CMAKE_C_COMPILER=""
CMAKE_CXX_COMPILER=""
CMAKE_GENERATOR=""

# macOS cross-compilation (arm64 runner can build x86_64)
if [ -n "$MACOS_ARCH" ]; then
    CMAKE_OSX_ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCH"
fi

# Windows uses Ninja generator with MinGW
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    CMAKE_GENERATOR="-G Ninja"
    echo "Using MinGW with Ninja generator"

    # Cross-compilation for ARM64 using llvm-mingw
    if [ -n "$CROSS_COMPILE_TARGET" ] && [ "$CROSS_COMPILE_TARGET" = "aarch64" ]; then
        echo "Cross-compiling to ARM64 using llvm-mingw"
        LLVM_MINGW_DIR="$SCRIPT_DIR/../llvm-mingw-20260311-ucrt-x86_64"
        if [ -d "$LLVM_MINGW_DIR" ]; then
            LLVM_MINGW_ABS="$(cd "$LLVM_MINGW_DIR" && pwd)"
            LLVM_MINGW_ROOT_WIN="$(cygpath -w "$LLVM_MINGW_ABS" 2>/dev/null || echo "$LLVM_MINGW_ABS")"
        else
            echo "ERROR: llvm-mingw directory not found at $LLVM_MINGW_DIR"
            exit 1
        fi
        CMAKE_C_COMPILER="-DCMAKE_C_COMPILER=${LLVM_MINGW_ROOT_WIN}/bin/clang.exe"
        CMAKE_CXX_COMPILER="-DCMAKE_CXX_COMPILER=${LLVM_MINGW_ROOT_WIN}/bin/clang++.exe"
        CMAKE_SYSTEM_PROCESSOR="-DCMAKE_SYSTEM_PROCESSOR=aarch64"
        SYSROOT_WIN="$(cygpath -m "$LLVM_MINGW_ABS")"
        export CFLAGS="--target=aarch64-w64-mingw32 --sysroot=${SYSROOT_WIN} -fcf-protection=none"
        export CXXFLAGS="--target=aarch64-w64-mingw32 --sysroot=${SYSROOT_WIN} -fcf-protection=none"
        export LDFLAGS="--sysroot=${SYSROOT_WIN}"
    fi
fi

# Linux cross-compilation for ARM64
if [[ "$OSTYPE" == "linux-gnu"* ]] && [ -n "$CMAKE_ARCH" ] && [ "$CMAKE_ARCH" = "aarch64" ]; then
    CMAKE_SYSTEM_PROCESSOR="-DCMAKE_SYSTEM_PROCESSOR=aarch64"
    CMAKE_C_COMPILER="-DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc"
    CMAKE_CXX_COMPILER="-DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++"
fi

echo "Configuring clspv..."
# Note: clspv's CMakeLists.txt handles LLVM configuration internally:
#   - Sets LLVM_TARGETS_TO_BUILD="Native" (needed for libclc's CLC compiler)
#   - Sets LLVM_ENABLE_RUNTIMES="libclc" (OpenCL C standard library)
#   - Sets LIBCLC_TARGETS_TO_BUILD="clspv--;clspv64--"
# Do NOT override LLVM_TARGETS_TO_BUILD — libclc build requires a native backend.
cmake .. \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    $CMAKE_SYSTEM_PROCESSOR \
    $CMAKE_C_COMPILER \
    $CMAKE_CXX_COMPILER \
    -DCMAKE_BUILD_TYPE=Release \
    -DCLSPV_BUILD_TESTS=OFF \
    -DCLSPV_BUILD_SPIRV_DIS=OFF \
    -DENABLE_CLSPV_OPT=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF

echo "Building clspv (this may take 20-40 minutes)..."
cmake --build . --config Release --target clspv -j$NCPU

# Package output
PACKAGE_DIR="$OUTPUT_DIR/clspv-$PLATFORM"
mkdir -p "$PACKAGE_DIR/bin"

echo "Packaging clspv..."
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    cp bin/clspv.exe "$PACKAGE_DIR/bin/" 2>/dev/null || \
        find . -name "clspv.exe" -type f -not -path "*/CMakeFiles/*" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null
else
    cp bin/clspv "$PACKAGE_DIR/bin/" 2>/dev/null || \
        find . -name "clspv" -type f -not -path "*/CMakeFiles/*" -exec cp {} "$PACKAGE_DIR/bin/" \; 2>/dev/null
fi

# Verify binary was packaged
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    if [ ! -f "$PACKAGE_DIR/bin/clspv.exe" ]; then
        echo "Error: clspv.exe not found after build"
        echo "Build output contents:"
        find . -name "clspv*" -type f 2>/dev/null || echo "  (no clspv files found)"
        exit 1
    fi
else
    if [ ! -f "$PACKAGE_DIR/bin/clspv" ]; then
        echo "Error: clspv binary not found after build"
        echo "Build output contents:"
        find . -name "clspv*" -type f 2>/dev/null || echo "  (no clspv files found)"
        exit 1
    fi
fi

# Copy licenses
echo "Packaging licenses..."
cd "$BUILD_DIR/clspv"

# Main license (Apache 2.0 with LLVM Exceptions)
cp LICENSE "$PACKAGE_DIR/LICENSE"

# Copy bundled dependency licenses
mkdir -p "$PACKAGE_DIR/LICENSES"
if [ -f "third_party/llvm/llvm/LICENSE.TXT" ]; then
    cp "third_party/llvm/llvm/LICENSE.TXT" "$PACKAGE_DIR/LICENSES/LLVM-LICENSE.TXT"
fi
if [ -f "third_party/SPIRV-Tools/LICENSE" ]; then
    cp "third_party/SPIRV-Tools/LICENSE" "$PACKAGE_DIR/LICENSES/SPIRV-Tools-LICENSE"
fi
if [ -f "third_party/SPIRV-Headers/LICENSE" ]; then
    cp "third_party/SPIRV-Headers/LICENSE" "$PACKAGE_DIR/LICENSES/SPIRV-Headers-LICENSE"
fi

# Create archive
cd "$OUTPUT_DIR"
tar -czf "clspv-${PLATFORM}.tar.gz" "clspv-$PLATFORM"
echo "Created: clspv-${PLATFORM}.tar.gz"

echo "Build complete!"
