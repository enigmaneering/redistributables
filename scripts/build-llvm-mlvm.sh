#!/bin/bash
set -e

# Build LLVM + Clang with mlvm namespace (-Dllvm=mlvm -Dclang=mlang).
# Produces shared libraries (native) or static libraries (WASM).
# All other mlvm-suffixed tools build against this.

. "$(dirname "$0")/common.sh"

echo "Building llvm-mlvm for $PLATFORM ($NCPU jobs)..."

if [ -z "$CMAKE" ]; then echo "Error: cmake not found"; exit 1; fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone
if [ ! -d "llvm-project" ]; then
    echo "Cloning LLVM (latest main)..."
    git clone --depth 1 https://github.com/llvm/llvm-project.git
fi

# Verify license
if [ ! -f "llvm-project/llvm/LICENSE.TXT" ]; then
    echo "Error: LLVM LICENSE not found"; exit 1
fi

# WASM: build native tools first (tablegen needs to run on host)
if [ "$IS_WASM" -eq 1 ]; then
    echo "=== WASM Phase 1: Building native tablegen tools ==="
    cd llvm-project
    mkdir -p build-native
    cd build-native

    $CMAKE ../llvm \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$NS_FLAGS" \
        -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
        -DLLVM_ENABLE_PROJECTS="clang" \
        -DLLVM_TARGETS_TO_BUILD="X86" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_ZLIB=OFF

    # Build all native tools that the WASM cross-compilation needs
    $CMAKE --build . --config Release --target llvm-min-tblgen llvm-tblgen clang-tblgen llvm-config -j$NCPU

    NATIVE_TOOLS_DIR="$(pwd)/bin"
    echo "Native tools at: $NATIVE_TOOLS_DIR"
    ls -la "$NATIVE_TOOLS_DIR/"

    cd "$BUILD_DIR"
    echo "=== WASM Phase 2: Building LLVM for WebAssembly ==="
fi

cd llvm-project
mkdir -p build
cd build

# Configure
WASM_FLAGS=""
if [ "$IS_WASM" -eq 1 ]; then
    WASM_FLAGS="-DLLVM_TABLEGEN=$NATIVE_TOOLS_DIR/llvm-tblgen -DCLANG_TABLEGEN=$NATIVE_TOOLS_DIR/clang-tblgen -DLLVM_CONFIG_PATH=$NATIVE_TOOLS_DIR/llvm-config -DLLVM_NATIVE_TOOL_DIR=$NATIVE_TOOLS_DIR -DLLVM_ENABLE_EH=ON -DLLVM_ENABLE_RTTI=ON"
    export LDFLAGS="-sNO_DISABLE_EXCEPTION_CATCHING -sNO_DISABLE_EXCEPTION_THROWING"
    CMAKE_CMD="emcmake $CMAKE"
    MAKE_CMD="emmake $CMAKE"
    LLVM_TARGETS="X86"
else
    CMAKE_CMD="$CMAKE"
    MAKE_CMD="$CMAKE"
    LLVM_TARGETS="Native;NVPTX;AMDGPU"
fi

$CMAKE_CMD ../llvm \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$NS_FLAGS" \
    -DCMAKE_CXX_FLAGS="$NS_FLAGS" \
    $WASM_FLAGS \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
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

# Package
PACKAGE_DIR="$OUTPUT_DIR/llvm-mlvm-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib" "$PACKAGE_DIR/include"

echo "Packaging llvm-mlvm..."
if [ "$IS_WASM" -eq 1 ]; then
    # Static libraries for WASM
    find lib -name "*.a" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
elif [[ "$OSTYPE" == "darwin"* ]]; then
    find lib -name "libLLVM*.dylib" -o -name "libclang*.dylib" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
    for d in "$PACKAGE_DIR/lib/"*.dylib; do
        install_name_tool -id "@rpath/$(basename "$d")" "$d" 2>/dev/null || true
    done
else
    find lib -name "libLLVM*.so*" -o -name "libclang*.so*" | while read f; do cp -P "$f" "$PACKAGE_DIR/lib/"; done
fi

# Headers (needed by downstream builds)
cp -r ../llvm/include/llvm "$PACKAGE_DIR/include/"
cp -r include/llvm/* "$PACKAGE_DIR/include/llvm/" 2>/dev/null || true
cp -r ../clang/include/clang "$PACKAGE_DIR/include/"
cp -r tools/clang/include/clang/* "$PACKAGE_DIR/include/clang/" 2>/dev/null || true

# CMake config (needed by downstream builds)
mkdir -p "$PACKAGE_DIR/lib/cmake"
cp -r lib/cmake/llvm "$PACKAGE_DIR/lib/cmake/" 2>/dev/null || true
cp -r lib/cmake/clang "$PACKAGE_DIR/lib/cmake/" 2>/dev/null || true

# License
mkdir -p "$PACKAGE_DIR/LICENSES"
cp ../llvm/LICENSE.TXT "$PACKAGE_DIR/LICENSES/LLVM-LICENSE.TXT"
cp ../clang/LICENSE.TXT "$PACKAGE_DIR/LICENSES/Clang-LICENSE.TXT" 2>/dev/null || true

cd "$OUTPUT_DIR"
tar -czf "llvm-mlvm-${PLATFORM}.tar.gz" "llvm-mlvm-$PLATFORM"
echo "Created: llvm-mlvm-${PLATFORM}.tar.gz"
echo "Build complete!"
