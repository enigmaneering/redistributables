#!/bin/bash
set -e

# Build clspv against llvm.
# Produces a shared library (native) or static library (WASM).
# Requires: llvm artifact (set LLVM_BUILD_DIR)

. "$(dirname "$0")/common.sh"

echo "Building clspv for $PLATFORM ($NCPU jobs)..."

if [ -z "$CMAKE" ]; then echo "Error: cmake not found"; exit 1; fi

# Find llvm
LLVM_BUILD="${LLVM_BUILD_DIR:-$BUILD_DIR/llvm-project/build}"
if [ ! -d "$LLVM_BUILD/lib/cmake/llvm" ]; then
    echo "Error: llvm not found at $LLVM_BUILD"
    echo "Build llvm first, or set LLVM_BUILD_DIR"
    exit 1
fi
echo "Using llvm from: $LLVM_BUILD"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone clspv
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
    echo "Fetching clspv dependencies..."
    $PYTHON utils/fetch_sources.py
fi

if [ ! -f "LICENSE" ]; then echo "Error: LICENSE not found"; exit 1; fi

mkdir -p build
cd build

if [ "$IS_WASM" -eq 1 ]; then
    CMAKE_CMD="emcmake $CMAKE"
    MAKE_CMD="emmake $CMAKE"
    CLSPV_EXTRA="-DCLSPV_EXTERNAL_LIBCLC_DIR=${LIBCLC_DIR:-/tmp/dummy}"
else
    CMAKE_CMD="$CMAKE"
    MAKE_CMD="$CMAKE"
    CLSPV_EXTRA=""
fi

$CMAKE_CMD .. \
    $CMAKE_GENERATOR \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCLSPV_LLVM_SOURCE_DIR="$BUILD_DIR/llvm-project/llvm" \
    -DCLSPV_CLANG_SOURCE_DIR="$BUILD_DIR/llvm-project/clang" \
    -DCLSPV_LLVM_BINARY_DIR="$LLVM_BUILD" \
    -DCLSPV_SHARED_LIB=ON \
    -DCLSPV_BUILD_TESTS=OFF \
    -DCLSPV_BUILD_SPIRV_DIS=OFF \
    -DENABLE_CLSPV_OPT=OFF \
    $CLSPV_EXTRA

$MAKE_CMD --build . --config Release --target clspv_core -j$NCPU

# Package
PACKAGE_DIR="$OUTPUT_DIR/clspv-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib" "$PACKAGE_DIR/include/clspv"

echo "Packaging clspv..."
if [ "$IS_WASM" -eq 1 ]; then
    find . -name "libclspv_core.a" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
elif [[ "$OSTYPE" == "darwin"* ]]; then
    find . -name "libclspv_core*.dylib" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
    for d in "$PACKAGE_DIR/lib/"*.dylib; do
        install_name_tool -id "@rpath/$(basename "$d")" "$d" 2>/dev/null || true
    done
else
    find . -name "libclspv_core*.so*" | while read f; do cp -P "$f" "$PACKAGE_DIR/lib/"; done
fi

# Headers
cp ../include/clspv/Compiler.h "$PACKAGE_DIR/include/clspv/"
find ../include/clspv -name "*.h" -exec cp {} "$PACKAGE_DIR/include/clspv/" \; 2>/dev/null || true

# License
cp ../LICENSE "$PACKAGE_DIR/LICENSE"

cd "$OUTPUT_DIR"
tar -czf "clspv-${PLATFORM}.tar.gz" "clspv-$PLATFORM"
echo "Created: clspv-${PLATFORM}.tar.gz"
echo "Build complete!"
