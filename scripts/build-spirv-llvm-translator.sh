#!/bin/bash
set -e

# Build SPIRV-LLVM-Translator against llvm.
# Bridges SPIR-V ↔ LLVM IR.
# Requires: llvm artifact (set LLVM_BUILD_DIR)

. "$(dirname "$0")/common.sh"

echo "Building spirv-llvm-translator for $PLATFORM ($NCPU jobs)..."

if [ -z "$CMAKE" ]; then echo "Error: cmake not found"; exit 1; fi

LLVM_BUILD="${LLVM_BUILD_DIR:-$BUILD_DIR/llvm-project/build}"
if [ ! -d "$LLVM_BUILD/lib/cmake/llvm" ]; then
    echo "Error: llvm not found at $LLVM_BUILD"
    exit 1
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -d "SPIRV-LLVM-Translator" ]; then
    SLT_TAG=$(curl -s https://api.github.com/repos/KhronosGroup/SPIRV-LLVM-Translator/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
    if [ -z "$SLT_TAG" ]; then SLT_TAG="v22.1.1"; fi
    echo "Cloning SPIRV-LLVM-Translator $SLT_TAG..."
    git clone --depth 1 --branch "$SLT_TAG" https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git
fi

cd SPIRV-LLVM-Translator
if [ ! -f "LICENSE.TXT" ]; then echo "Error: LICENSE.TXT not found"; exit 1; fi

mkdir -p build
cd build

if [ "$IS_WASM" -eq 1 ]; then
    CMAKE_CMD="emcmake $CMAKE"
    MAKE_CMD="emmake $CMAKE"
    SHARED=OFF
else
    CMAKE_CMD="$CMAKE"
    MAKE_CMD="$CMAKE"
    SHARED=ON
fi

$CMAKE_CMD .. \
    $CMAKE_GENERATOR \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DLLVM_DIR="$LLVM_BUILD/lib/cmake/llvm" \
    -DBUILD_SHARED_LIBS=$SHARED \
    -DLLVM_INCLUDE_TESTS=OFF

$MAKE_CMD --build . --config Release -j$NCPU

# Package
PACKAGE_DIR="$OUTPUT_DIR/spirv-llvm-translator-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib" "$PACKAGE_DIR/include"

echo "Packaging spirv-llvm-translator..."
if [ "$IS_WASM" -eq 1 ]; then
    find lib -name "*.a" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
elif [[ "$OSTYPE" == "darwin"* ]]; then
    find lib -name "libLLVMSPIRVLib*.dylib" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
else
    find lib -name "libLLVMSPIRVLib*.so*" | while read f; do cp -P "$f" "$PACKAGE_DIR/lib/"; done
fi

cp -r ../include/LLVMSPIRVLib.h "$PACKAGE_DIR/include/" 2>/dev/null || true
cp -r ../include/LLVMSPIRVLib "$PACKAGE_DIR/include/" 2>/dev/null || true

cp ../LICENSE.TXT "$PACKAGE_DIR/LICENSE.TXT"

cd "$OUTPUT_DIR"
tar -czf "spirv-llvm-translator-${PLATFORM}.tar.gz" "spirv-llvm-translator-$PLATFORM"
echo "Created: spirv-llvm-translator-${PLATFORM}.tar.gz"
echo "Build complete!"
