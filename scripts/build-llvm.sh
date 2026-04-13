#!/bin/bash
set -e

# Build script for libmental-llvm
# Produces a single self-contained shared library wrapping LLVM, Clang,
# clspv, and SPIRV-LLVM-Translator behind a flat C API.
#
# The entire LLVM build is namespaced (-Dllvm=mlvm -Dclang=mlang) so
# there is zero symbol crossover with other LLVM-based packages like DXC.
# This eliminates the need for post-hoc symbol prefixing on any platform.
#
# mental dlopen's this one library to get:
#   - CUDA → PTX (Clang + NVPTX backend)
#   - OpenCL C → Vulkan SPIR-V (clspv passes + memory model transformation)
#   - OpenCL C → OpenCL SPIR-V (Clang + SPIRV-LLVM-Translator)
#   - SPIR-V ↔ LLVM IR bridge
#   - LLVM IR → PTX / AMDGPU

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# Detect platform
if [[ "$OSTYPE" == "darwin"* ]]; then
    ARCH=$(uname -m)
    if [ -n "$MACOS_ARCH" ]; then
        ARCH="$MACOS_ARCH"
    fi
    PLATFORM="darwin-$ARCH"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux-$(uname -m)"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    PLATFORM="windows-$(uname -m)"
    export PATH="/mingw64/bin:/ucrt64/bin:$PATH"
fi
PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')

echo "Building libmental-llvm for $PLATFORM..."

# LLVM is massive — limit parallelism
if [[ "$OSTYPE" == "darwin"* ]]; then
    NCPU=$(($(sysctl -n hw.ncpu) / 2))
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    NCPU=2
else
    NCPU=2
fi
if [ "$NCPU" -lt 1 ]; then NCPU=1; fi
echo "Using $NCPU parallel jobs"

# Find cmake
CMAKE=$(command -v cmake 2>/dev/null || true)
if [ -z "$CMAKE" ]; then
    for p in /ucrt64/bin/cmake.exe /mingw64/bin/cmake.exe; do
        if [ -x "$p" ]; then CMAKE="$p"; break; fi
    done
fi
if [ -z "$CMAKE" ]; then echo "Error: cmake not found"; exit 1; fi

# Find python
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [ -z "$PYTHON" ]; then
    for p in /ucrt64/bin/python3.exe /ucrt64/bin/python.exe /mingw64/bin/python3.exe /mingw64/bin/python.exe; do
        if [ -x "$p" ]; then PYTHON="$p"; break; fi
    done
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# ================================================================
#  Step 1: Clone sources
# ================================================================

if [ ! -d "llvm-project" ]; then
    echo "Cloning LLVM (latest main)..."
    git clone --depth 1 https://github.com/llvm/llvm-project.git
fi

if [ ! -d "SPIRV-LLVM-Translator" ]; then
    echo "Cloning SPIRV-LLVM-Translator..."
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git
fi

if [ ! -d "clspv" ]; then
    echo "Cloning clspv..."
    set +e
    git clone https://github.com/google/clspv.git
    CLONE_EXIT=$?
    set -e
    if [ $CLONE_EXIT -ne 0 ] && [ ! -d "clspv/.git" ]; then
        echo "Error: git clone failed"; exit 1
    fi
fi

# clspv needs its own dependencies (SPIRV-Tools, SPIRV-Headers) but
# NOT its own LLVM — we'll point it at ours
cd clspv
if [ ! -d "third_party/SPIRV-Headers" ] && [ -n "$PYTHON" ]; then
    echo "Fetching clspv dependencies (SPIRV-Tools, SPIRV-Headers)..."
    $PYTHON utils/fetch_sources.py
fi
cd "$BUILD_DIR"

# Verify licenses
echo "Verifying licenses..."
for f in llvm-project/llvm/LICENSE.TXT SPIRV-LLVM-Translator/LICENSE.TXT clspv/LICENSE; do
    if [ ! -f "$f" ]; then echo "Error: $f not found"; exit 1; fi
done
echo "Licenses verified"

# ================================================================
#  Step 2: Build LLVM + Clang (static, namespaced)
# ================================================================

echo ""
echo "=== Building LLVM + Clang (namespaced: llvm→mlvm, clang→mlang) ==="
cd llvm-project
mkdir -p build
cd build

CMAKE_OSX_ARCH_FLAG=""
CMAKE_GENERATOR=""
if [ -n "$MACOS_ARCH" ]; then
    CMAKE_OSX_ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCH"
fi
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    CMAKE_GENERATOR="-G Ninja"
fi

# Namespace the entire build to avoid symbol crossover with DXC
NS_FLAGS="-Dllvm=mlvm -Dclang=mlang"

$CMAKE ../llvm \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$NS_FLAGS" \
    -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_TARGETS_TO_BUILD="Native;NVPTX;AMDGPU" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_DOCS=OFF

echo "Building LLVM (this may take 30-60 minutes)..."
$CMAKE --build . --config Release -j$NCPU

LLVM_BUILD_DIR="$(pwd)"
cd "$BUILD_DIR"

# ================================================================
#  Step 3: Build SPIRV-LLVM-Translator (static, namespaced)
# ================================================================

echo ""
echo "=== Building SPIRV-LLVM-Translator ==="
cd SPIRV-LLVM-Translator
mkdir -p build
cd build

$CMAKE .. \
    $CMAKE_GENERATOR \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$NS_FLAGS" \
    -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
    -DLLVM_DIR="$LLVM_BUILD_DIR/lib/cmake/llvm" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF

$CMAKE --build . --config Release -j$NCPU

SPIRV_TRANSLATOR_BUILD="$(pwd)"
cd "$BUILD_DIR"

# ================================================================
#  Step 4: Build clspv passes (static, against our LLVM)
# ================================================================

echo ""
echo "=== Building clspv (against unified LLVM) ==="
cd clspv
mkdir -p build-unified
cd build-unified

$CMAKE .. \
    $CMAKE_GENERATOR \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$NS_FLAGS" \
    -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
    -DCLSPV_LLVM_SOURCE_DIR="$BUILD_DIR/llvm-project/llvm" \
    -DCLSPV_CLANG_SOURCE_DIR="$BUILD_DIR/llvm-project/clang" \
    -DCLSPV_LLVM_BINARY_DIR="$LLVM_BUILD_DIR" \
    -DCLSPV_SHARED_LIB=OFF \
    -DCLSPV_BUILD_TESTS=OFF \
    -DCLSPV_BUILD_SPIRV_DIS=OFF \
    -DENABLE_CLSPV_OPT=OFF

$CMAKE --build . --config Release --target clspv_core -j$NCPU

CLSPV_BUILD_DIR="$(pwd)"
cd "$BUILD_DIR"

# ================================================================
#  Step 5: Build libmental-llvm (shared, links everything)
# ================================================================

echo ""
echo "=== Building libmental-llvm (shared library) ==="
WRAPPER_SRC="$SCRIPT_DIR/../mental-llvm"
mkdir -p mental-llvm-build
cd mental-llvm-build

$CMAKE "$WRAPPER_SRC" \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$NS_FLAGS" \
    -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
    -DLLVM_DIR="$LLVM_BUILD_DIR/lib/cmake/llvm" \
    -DClang_DIR="$LLVM_BUILD_DIR/lib/cmake/clang" \
    -DSPIRV_TRANSLATOR_DIR="$SPIRV_TRANSLATOR_BUILD" \
    -DCLSPV_BUILD_DIR="$CLSPV_BUILD_DIR"

$CMAKE --build . --config Release

# ================================================================
#  Package
# ================================================================

PACKAGE_DIR="$OUTPUT_DIR/mental-llvm-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib"
mkdir -p "$PACKAGE_DIR/include"

echo "Packaging libmental-llvm..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    find . -name "libmental-llvm*.dylib" | while read f; do
        cp "$f" "$PACKAGE_DIR/lib/"
    done
    for dylib in "$PACKAGE_DIR/lib/"*.dylib; do
        install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib" 2>/dev/null || true
    done
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    find . -name "*mental-llvm*.dll" -o -name "*mental-llvm*.lib" | while read f; do
        cp "$f" "$PACKAGE_DIR/lib/"
    done
else
    find . -name "libmental-llvm*.so*" | while read f; do
        cp -P "$f" "$PACKAGE_DIR/lib/"
    done
fi

# Header
cp "$WRAPPER_SRC/mental_llvm.h" "$PACKAGE_DIR/include/"

# Verify
LIB_COUNT=$(find "$PACKAGE_DIR/lib" -type f 2>/dev/null | wc -l)
if [ "$LIB_COUNT" -eq 0 ]; then
    echo "Error: no libraries found after build"
    exit 1
fi
echo "Packaged:"
ls -lh "$PACKAGE_DIR/lib/"

# Licenses
mkdir -p "$PACKAGE_DIR/LICENSES"
cp "$BUILD_DIR/llvm-project/llvm/LICENSE.TXT" "$PACKAGE_DIR/LICENSES/LLVM-LICENSE.TXT"
cp "$BUILD_DIR/llvm-project/clang/LICENSE.TXT" "$PACKAGE_DIR/LICENSES/Clang-LICENSE.TXT" 2>/dev/null || true
cp "$BUILD_DIR/SPIRV-LLVM-Translator/LICENSE.TXT" "$PACKAGE_DIR/LICENSES/SPIRV-LLVM-Translator-LICENSE.TXT"
cp "$BUILD_DIR/clspv/LICENSE" "$PACKAGE_DIR/LICENSES/clspv-LICENSE"

cd "$OUTPUT_DIR"
tar -czf "mental-llvm-${PLATFORM}.tar.gz" "mental-llvm-$PLATFORM"
echo "Created: mental-llvm-${PLATFORM}.tar.gz"

echo "Build complete!"
