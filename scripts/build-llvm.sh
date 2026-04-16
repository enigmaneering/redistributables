#!/bin/bash
set -e

# Build LLVM + Clang for libmental.
# Produces shared libraries (native) or static libraries (WASM).
# All other downstream tools build against this.

. "$(dirname "$0")/common.sh"

echo "Building llvm for $PLATFORM ($NCPU jobs)..."

if [ -z "$CMAKE" ]; then echo "Error: cmake not found"; exit 1; fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone latest stable release
if [ ! -d "llvm-project" ]; then
    LLVM_TAG=$(curl -s https://api.github.com/repos/llvm/llvm-project/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
    if [ -z "$LLVM_TAG" ]; then LLVM_TAG="llvmorg-22.1.3"; fi
    echo "Cloning LLVM $LLVM_TAG..."
    git clone --depth 1 --branch "$LLVM_TAG" https://github.com/llvm/llvm-project.git
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
    WASM_FLAGS="-DLLVM_TABLEGEN=$NATIVE_TOOLS_DIR/llvm-tblgen -DCLANG_TABLEGEN=$NATIVE_TOOLS_DIR/clang-tblgen -DLLVM_CONFIG_PATH=$NATIVE_TOOLS_DIR/llvm-config -DLLVM_NATIVE_TOOL_DIR=$NATIVE_TOOLS_DIR -DLLVM_ENABLE_EH=ON -DLLVM_ENABLE_RTTI=ON -DLLVM_BUILD_TOOLS=OFF -DCLANG_BUILD_TOOLS=OFF"
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

echo "Building LLVM (this may take a while)..."
$MAKE_CMD --build . --config Release -j$NCPU

# Package
PACKAGE_DIR="$OUTPUT_DIR/llvm-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib" "$PACKAGE_DIR/include"

if [ "$IS_WASM" -eq 1 ]; then
    # WASM: cmake --install (plain, NOT emcmake — install is just file ops)
    # generates a relocatable CMake config. Do NOT copy build-tree
    # cmake files: those have hardcoded absolute paths that break when
    # the artifact is downloaded by a different job.
    echo "Installing WASM build to $PACKAGE_DIR..."
    "$CMAKE" --install . --prefix "$PACKAGE_DIR"
else
    # Native: cmake --install generates relocatable CMake config
    echo "Installing to $PACKAGE_DIR..."
    cmake --install . --prefix "$PACKAGE_DIR"

    # Fix rpaths on macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        find "$PACKAGE_DIR/lib" -name "*.dylib" | while read d; do
            install_name_tool -id "@rpath/$(basename "$d")" "$d" 2>/dev/null || true
        done
    fi
fi

# Bundle the LLVM/Clang source tree into the artifact so downstream
# consumers (clspv, spirv-llvm-translator) can point CLSPV_LLVM_SOURCE_DIR
# / CLANG_SOURCE_DIR at it. Skip heavy bits we don't need.
echo "Bundling LLVM/Clang source tree into $PACKAGE_DIR/src..."
mkdir -p "$PACKAGE_DIR/src/llvm" "$PACKAGE_DIR/src/clang"
EXCLUDES=(
    --exclude=test --exclude=unittests --exclude=docs
    --exclude=examples --exclude=benchmarks --exclude=bindings
    --exclude=.git
)
# common.sh normalizes $OUTPUT_DIR (and therefore $PACKAGE_DIR) to POSIX form
# on MSYS2 via cygpath, so no drive-letter colons reach tar's path parser here.
tar -cf - "${EXCLUDES[@]}" -C ../llvm . | tar -xf - -C "$PACKAGE_DIR/src/llvm"
tar -cf - "${EXCLUDES[@]}" -C ../clang . | tar -xf - -C "$PACKAGE_DIR/src/clang"

# Record the LLVM tag we built so consumers can verify version match
if [ -d "../.git" ]; then
    (cd .. && git describe --tags 2>/dev/null || git rev-parse HEAD) > "$PACKAGE_DIR/VERSION"
fi

# License
mkdir -p "$PACKAGE_DIR/LICENSES"
cp ../llvm/LICENSE.TXT "$PACKAGE_DIR/LICENSES/LLVM-LICENSE.TXT"
cp ../clang/LICENSE.TXT "$PACKAGE_DIR/LICENSES/Clang-LICENSE.TXT" 2>/dev/null || true

cd "$OUTPUT_DIR"
tar -czf "llvm-${PLATFORM}.tar.gz" "llvm-$PLATFORM"
echo "Created: llvm-${PLATFORM}.tar.gz"
echo "Build complete!"
