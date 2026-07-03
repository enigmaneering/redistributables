#!/bin/bash
set -e

# Build script for glslang + SPIRV-Tools
# Outputs a relocatable package with libraries and headers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# Query GitHub for latest release if not specified
if [ -z "$GLSLANG_VERSION" ]; then
    echo "Querying GitHub for latest glslang release..."
    GLSLANG_VERSION=$(curl -s https://api.github.com/repos/KhronosGroup/glslang/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
    if [ -z "$GLSLANG_VERSION" ]; then
        echo "Error: Could not determine latest glslang version, falling back to main"
        GLSLANG_VERSION="main"
    else
        echo "Latest release: $GLSLANG_VERSION"
    fi
fi

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

# Resolve SPIRV-Tools + SPIRV-Headers SHAs from glslang's own
# known_good.json instead of tracking upstream `main`.  The former
# guarantees glslang can consume whatever enum/API surface those repos
# expose; the latter breaks periodically when SPIRV-Tools adds new
# enum values that glslang's own generated switch statements don't
# handle yet (SPV_OPERAND_TYPE_GATHER_MODES was the trigger that
# prompted this fix — glslang 16.3.0 predated it and the resulting
# core_tables_body.inc had `use of undeclared identifier` errors).
KNOWN_GOOD="glslang/known_good.json"
if [ -f "$KNOWN_GOOD" ]; then
    SPIRV_TOOLS_SHA=$(python3 -c "import json; d=json.load(open('$KNOWN_GOOD')); print(next(c['commit'] for c in d['commits'] if c['name']=='spirv-tools'))")
    SPIRV_HEADERS_SHA=$(python3 -c "import json; d=json.load(open('$KNOWN_GOOD')); print(next(c['commit'] for c in d['commits'] if c['name']=='spirv-tools/external/spirv-headers'))")
    echo "known_good.json — SPIRV-Tools: $SPIRV_TOOLS_SHA"
    echo "                  SPIRV-Headers: $SPIRV_HEADERS_SHA"
else
    echo "WARNING: glslang/known_good.json missing; falling back to main"
    SPIRV_TOOLS_SHA=""
    SPIRV_HEADERS_SHA=""
fi

# Clone SPIRV-Tools at the known-good SHA (fall back to main if the
# JSON was missing — old behaviour, kept for safety).
if [ ! -d "spirv-tools" ]; then
    echo "Cloning SPIRV-Tools..."
    if [ -n "$SPIRV_TOOLS_SHA" ]; then
        git clone https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
        (cd spirv-tools && git checkout "$SPIRV_TOOLS_SHA")
    else
        git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    fi
fi

# Clone SPIRV-Headers (needed by SPIRV-Tools) at the known-good SHA.
if [ ! -d "spirv-tools/external/spirv-headers" ]; then
    echo "Cloning SPIRV-Headers..."
    if [ -n "$SPIRV_HEADERS_SHA" ]; then
        git clone https://github.com/KhronosGroup/SPIRV-Headers.git spirv-tools/external/spirv-headers
        (cd spirv-tools/external/spirv-headers && git checkout "$SPIRV_HEADERS_SHA")
    else
        git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-tools/external/spirv-headers
    fi
fi

# Create symlink for glslang to find SPIRV-Tools
mkdir -p glslang/External
rm -rf glslang/External/spirv-tools
ln -sf ../../spirv-tools glslang/External/spirv-tools

# Verify licenses exist before building (fail fast)
echo "Verifying license files..."
if [ ! -f "glslang/LICENSE.txt" ]; then
    echo "Error: LICENSE.txt not found in glslang repository"
    exit 1
fi
if [ ! -f "spirv-tools/LICENSE" ]; then
    echo "Error: LICENSE not found in SPIRV-Tools repository"
    exit 1
fi
if [ ! -f "spirv-tools/external/spirv-headers/LICENSE" ]; then
    echo "Error: LICENSE not found in SPIRV-Headers repository"
    exit 1
fi
echo "License files verified"

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
        # It's extracted in the repository root during the workflow
        LLVM_MINGW_DIR="$SCRIPT_DIR/../llvm-mingw-20260311-ucrt-x86_64"
        # Resolve to absolute path and convert to Windows path for CMake
        if [ -d "$LLVM_MINGW_DIR" ]; then
            LLVM_MINGW_ABS="$(cd "$LLVM_MINGW_DIR" && pwd)"
            # For CMake compiler path, use Windows path
            LLVM_MINGW_ROOT_WIN="$(cygpath -w "$LLVM_MINGW_ABS" 2>/dev/null || echo "$LLVM_MINGW_ABS")"
            # For sysroot, keep Unix path (Clang handles this better in MSYS2)
            LLVM_MINGW_ROOT="$LLVM_MINGW_ABS"
        else
            echo "ERROR: llvm-mingw directory not found at $LLVM_MINGW_DIR"
            exit 1
        fi
        CMAKE_C_COMPILER="-DCMAKE_C_COMPILER=${LLVM_MINGW_ROOT_WIN}/bin/clang.exe"
        CMAKE_CXX_COMPILER="-DCMAKE_CXX_COMPILER=${LLVM_MINGW_ROOT_WIN}/bin/clang++.exe"
        CMAKE_SYSTEM_PROCESSOR="-DCMAKE_SYSTEM_PROCESSOR=aarch64"
        # Set flags as environment variables to avoid shell quoting issues
        # Include sysroot for Windows headers and libraries
        # Use Windows-style path with forward slashes for sysroot - convert using cygpath -m
        SYSROOT_WIN="$(cygpath -m "$LLVM_MINGW_ABS")"
        export CFLAGS="--target=aarch64-w64-mingw32 --sysroot=${SYSROOT_WIN}"
        export CXXFLAGS="--target=aarch64-w64-mingw32 --sysroot=${SYSROOT_WIN}"
        export LDFLAGS="--sysroot=${SYSROOT_WIN}"
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
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_SPVREMAPPER=OFF \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DENABLE_CTEST=OFF \
    -DENABLE_OPT=ON \
    -DENABLE_HLSL=OFF \
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

# Copy licenses - preserve structure from source repos
echo "Packaging licenses..."
cd "$BUILD_DIR/glslang"
# Main glslang license
cp "LICENSE.txt" "$PACKAGE_DIR/LICENSE.txt"

# Create LICENSES directory for bundled dependencies
mkdir -p "$PACKAGE_DIR/LICENSES"

# SPIRV-Tools license
cp "External/spirv-tools/LICENSE" "$PACKAGE_DIR/LICENSES/SPIRV-Tools-LICENSE"

# SPIRV-Headers license
cp "External/spirv-tools/external/spirv-headers/LICENSE" "$PACKAGE_DIR/LICENSES/SPIRV-Headers-LICENSE"

# Create archive
cd "$OUTPUT_DIR"
tar -czf "glslang-${PLATFORM}.tar.gz" "glslang-$PLATFORM"
echo "Created: glslang-${PLATFORM}.tar.gz"

echo "Build complete!"
