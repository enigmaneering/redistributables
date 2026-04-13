#!/bin/bash
set -e

# Build script for libmental-mlvm
#
# Produces a single self-contained library wrapping LLVM, Clang, clspv,
# and SPIRV-LLVM-Translator behind a flat C API (mental_mlvm.h).
#
# The entire LLVM build is namespaced (-Dllvm=mlvm -Dclang=mlang) so
# there is zero symbol crossover with other LLVM-based packages like DXC.
# This is the same strategy on ALL platforms — native and WASM.
#
# Native: produces libmental-mlvm.so/.dylib (shared, dlopen'd at runtime)
# WASM:   produces libmental-mlvm-full.a (static, linked into mental)
#
# mental gets:
#   - CUDA → PTX (Clang + NVPTX backend)
#   - OpenCL C → Vulkan SPIR-V (clspv, memory model transformation)
#   - OpenCL C → OpenCL SPIR-V (Clang + SPIRV-LLVM-Translator)
#   - SPIR-V ↔ LLVM IR bridge
#   - LLVM IR → PTX / AMDGPU

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# ================================================================
#  Platform detection
# ================================================================

IS_WASM=0
if command -v emcmake &> /dev/null && [ "${WASM_BUILD:-0}" = "1" ]; then
    IS_WASM=1
    PLATFORM="wasm"
    echo "Building libmental-mlvm for WebAssembly..."
elif [[ "$OSTYPE" == "darwin"* ]]; then
    ARCH=$(uname -m)
    if [ -n "$MACOS_ARCH" ]; then ARCH="$MACOS_ARCH"; fi
    PLATFORM="darwin-$ARCH"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux-$(uname -m)"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    PLATFORM="windows-$(uname -m)"
    export PATH="/mingw64/bin:/ucrt64/bin:$PATH"
fi
PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')

if [ "$IS_WASM" -eq 0 ]; then
    echo "Building libmental-mlvm for $PLATFORM..."
fi

# Parallelism
if [[ "$OSTYPE" == "darwin"* ]]; then
    NCPU=$(($(sysctl -n hw.ncpu) / 2))
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    NCPU=$(nproc); NCPU=2
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

# Architecture flags
CMAKE_OSX_ARCH_FLAG=""
CMAKE_GENERATOR=""
if [ -n "$MACOS_ARCH" ]; then
    CMAKE_OSX_ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCH"
fi
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    CMAKE_GENERATOR="-G Ninja"
fi

# Namespace the entire build
NS_FLAGS="-Dllvm=mlvm -Dclang=mlang"

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
#  WASM: Phase 1 — build natively first (tablegen + libclc)
# ================================================================

if [ "$IS_WASM" -eq 1 ]; then
    echo ""
    echo "=== WASM Phase 1: Building native tools (tablegen, libclc) ==="
    cd llvm-project
    mkdir -p build-native
    cd build-native

    $CMAKE ../llvm \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$NS_FLAGS" \
        -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
        -DLLVM_ENABLE_PROJECTS="clang" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_ZLIB=OFF

    # Build clspv (which builds clang + libclc + native tools)
    # We need the native tablegen binaries for cross-compilation
    echo "Building native tools + libclc (~30-60 minutes)..."
    cd "$BUILD_DIR/clspv"
    mkdir -p build-native
    cd build-native

    $CMAKE .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$NS_FLAGS" \
        -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
        -DCLSPV_BUILD_TESTS=OFF \
        -DCLSPV_BUILD_SPIRV_DIS=OFF \
        -DENABLE_CLSPV_OPT=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF

    $CMAKE --build . --target clspv -j$NCPU

    # Save native tools + libclc
    NATIVE_TOOLS="$BUILD_DIR/native-tools"
    mkdir -p "$NATIVE_TOOLS"
    for tool in llvm-min-tblgen llvm-tblgen clang-tblgen llvm-config; do
        FOUND=$(find . -name "$tool" -type f -executable 2>/dev/null | head -1)
        if [ -n "$FOUND" ]; then cp "$FOUND" "$NATIVE_TOOLS/"; echo "  Saved: $tool"; fi
    done

    LIBCLC_BC=$(find . -path "*/spir--/libclc.bc" -print -quit)
    LIBCLC_SAVED="$BUILD_DIR/libclc-prebuilt"
    if [ -n "$LIBCLC_BC" ]; then
        LIBCLC_DIR=$(dirname "$(dirname "$LIBCLC_BC")")
        LIBCLC_DIR_ABS="$(cd "$LIBCLC_DIR" && pwd)"
        mkdir -p "$LIBCLC_SAVED"
        cp -r "$LIBCLC_DIR_ABS"/* "$LIBCLC_SAVED/"
        echo "Saved libclc to $LIBCLC_SAVED"
    fi

    echo "Cleaning native build..."
    cd "$BUILD_DIR"
    rm -rf clspv/build-native llvm-project/build-native
    echo "Disk after cleanup:"
    df -h . | tail -1
fi

# ================================================================
#  Step 2: Build LLVM + Clang
# ================================================================

echo ""
if [ "$IS_WASM" -eq 1 ]; then
    echo "=== WASM Phase 2: Building LLVM + Clang for WebAssembly ==="
else
    echo "=== Building LLVM + Clang (namespaced: llvm→mlvm, clang→mlang) ==="
fi

cd llvm-project
mkdir -p build
cd build

LLVM_EXTRA_FLAGS=""
if [ "$IS_WASM" -eq 1 ]; then
    LLVM_EXTRA_FLAGS="-DLLVM_TABLEGEN=$NATIVE_TOOLS/llvm-tblgen -DCLANG_TABLEGEN=$NATIVE_TOOLS/clang-tblgen"
    CMAKE_CMD="emcmake $CMAKE"
    MAKE_CMD="emmake $CMAKE"
    LINKER_FLAGS="-DCMAKE_EXE_LINKER_FLAGS=-sNO_DISABLE_EXCEPTION_CATCHING -sNO_DISABLE_EXCEPTION_THROWING"
    LLVM_TARGETS=""  # No native targets on WASM
    EH_FLAGS="-DLLVM_ENABLE_EH=ON -DLLVM_ENABLE_RTTI=ON"
else
    CMAKE_CMD="$CMAKE"
    MAKE_CMD="$CMAKE"
    LINKER_FLAGS=""
    LLVM_TARGETS="Native;NVPTX;AMDGPU"
    EH_FLAGS=""
fi

$CMAKE_CMD ../llvm \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$NS_FLAGS" \
    -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
    $LINKER_FLAGS \
    $EH_FLAGS \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
    $LLVM_EXTRA_FLAGS \
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
$MAKE_CMD --build . --config Release -j$NCPU

LLVM_BUILD_DIR="$(pwd)"
cd "$BUILD_DIR"

# ================================================================
#  Step 3: Build SPIRV-LLVM-Translator
# ================================================================

echo ""
echo "=== Building SPIRV-LLVM-Translator ==="
cd SPIRV-LLVM-Translator
mkdir -p build
cd build

$CMAKE_CMD .. \
    $CMAKE_GENERATOR \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$NS_FLAGS" \
    -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
    -DLLVM_DIR="$LLVM_BUILD_DIR/lib/cmake/llvm" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF

$MAKE_CMD --build . --config Release -j$NCPU

SPIRV_TRANSLATOR_BUILD="$(pwd)"
cd "$BUILD_DIR"

# ================================================================
#  Step 4: Build clspv passes
# ================================================================

echo ""
echo "=== Building clspv (against unified LLVM) ==="
cd clspv
mkdir -p build-unified
cd build-unified

CLSPV_EXTRA=""
if [ "$IS_WASM" -eq 1 ] && [ -d "$LIBCLC_SAVED" ]; then
    CLSPV_EXTRA="-DCLSPV_EXTERNAL_LIBCLC_DIR=$LIBCLC_SAVED"
fi

$CMAKE_CMD .. \
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
    -DENABLE_CLSPV_OPT=OFF \
    $CLSPV_EXTRA

$MAKE_CMD --build . --config Release --target clspv_core -j$NCPU

CLSPV_BUILD_DIR="$(pwd)"
cd "$BUILD_DIR"

# ================================================================
#  Step 5: Build libmental-mlvm
# ================================================================

echo ""
WRAPPER_SRC="$SCRIPT_DIR/../mental-mlvm"

if [ "$IS_WASM" -eq 1 ]; then
    echo "=== Building libmental-mlvm (WASM static library) ==="
    mkdir -p mental-mlvm-build
    cd mental-mlvm-build

    # On WASM, build as static and combine all .a into one archive
    $CMAKE_CMD "$WRAPPER_SRC" \
        $CMAKE_GENERATOR \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$NS_FLAGS" \
        -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
        -DLLVM_DIR="$LLVM_BUILD_DIR/lib/cmake/llvm" \
        -DClang_DIR="$LLVM_BUILD_DIR/lib/cmake/clang" \
        -DSPIRV_TRANSLATOR_DIR="$SPIRV_TRANSLATOR_BUILD" \
        -DCLSPV_BUILD_DIR="$CLSPV_BUILD_DIR" \
        -DBUILD_SHARED=OFF

    $MAKE_CMD --build . --config Release

    # Create combined static archive
    echo "Creating combined static library..."
    COMBINED_LIB="libmental-mlvm-full.a"
    ALL_ARCHIVES=$(find "$LLVM_BUILD_DIR" "$SPIRV_TRANSLATOR_BUILD" "$CLSPV_BUILD_DIR" . \
        -name "*.a" -type f 2>/dev/null)
    MERGE_DIR=$(mktemp -d)
    BUILD_ABS="$(pwd)"
    for archive in $ALL_ARCHIVES; do
        SUBDIR="$MERGE_DIR/$(echo "$archive" | tr '/' '_')"
        mkdir -p "$SUBDIR"
        cd "$SUBDIR"
        emar x "$archive" 2>/dev/null || true
        cd "$BUILD_ABS"
    done
    emar rcs "$COMBINED_LIB" $(find "$MERGE_DIR" -name "*.o" -type f)
    rm -rf "$MERGE_DIR"
    echo "Created: $COMBINED_LIB ($(du -h "$COMBINED_LIB" | cut -f1))"
else
    echo "=== Building libmental-mlvm (shared library) ==="
    mkdir -p mental-mlvm-build
    cd mental-mlvm-build

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
fi

# ================================================================
#  Package
# ================================================================

PACKAGE_DIR="$OUTPUT_DIR/mental-mlvm-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib"
mkdir -p "$PACKAGE_DIR/include"

echo "Packaging libmental-mlvm..."
if [ "$IS_WASM" -eq 1 ]; then
    cp libmental-mlvm-full.a "$PACKAGE_DIR/lib/" 2>/dev/null || true
    find . -name "libmental-mlvm*.a" -not -name "*-full*" | while read f; do
        cp "$f" "$PACKAGE_DIR/lib/"
    done
elif [[ "$OSTYPE" == "darwin"* ]]; then
    find . -name "libmental-mlvm*.dylib" | while read f; do
        cp "$f" "$PACKAGE_DIR/lib/"
    done
    for dylib in "$PACKAGE_DIR/lib/"*.dylib; do
        install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib" 2>/dev/null || true
    done
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    find . -name "*mental-mlvm*.dll" -o -name "*mental-mlvm*.lib" | while read f; do
        cp "$f" "$PACKAGE_DIR/lib/"
    done
else
    find . -name "libmental-mlvm*.so*" | while read f; do
        cp -P "$f" "$PACKAGE_DIR/lib/"
    done
fi

# Header
cp "$WRAPPER_SRC/mental_mlvm.h" "$PACKAGE_DIR/include/"

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
tar -czf "mental-mlvm-${PLATFORM}.tar.gz" "mental-mlvm-$PLATFORM"
echo "Created: mental-mlvm-${PLATFORM}.tar.gz"

echo "Build complete!"
