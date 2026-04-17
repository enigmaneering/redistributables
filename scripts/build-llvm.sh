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

# WASM: build native tools first. Tablegen must run on the host during
# cross-compile (Phase 2). We also build native clang + llvm-link here so
# the WASM artifact ships a natively-executable toolchain for downstream
# consumers that need to emit LLVM bitcode on the host (e.g. clspv's libclc
# build, which compiles .cl → spir-- .bc using a real process-exec'd clang).
# These native binaries end up in $PACKAGE_DIR/bin-native/ (see packaging
# step below); they are x86_64 Linux since the WASM LLVM job runs there.
if [ "$IS_WASM" -eq 1 ]; then
    echo "=== WASM Phase 1: Building native tools (tablegen + clang + llvm-link) ==="
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

    # Native tools: tablegen/llvm-config for Phase 2 cross-compile,
    # clang/llvm-as/llvm-link/opt/llvm-config to bundle into the artifact
    # for downstream consumers. libclc's CMake (libclc/CMakeLists.txt:137)
    # requires this exact set of four tools — clang opt llvm-as llvm-link —
    # and refuses to configure if any is missing.
    $CMAKE --build . --config Release \
        --target llvm-min-tblgen llvm-tblgen clang-tblgen llvm-config \
                 clang llvm-as llvm-link opt \
        -j$NCPU

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

    # Ship the Phase 1 native binaries alongside the wasm-compiled install.
    # Downstream consumers (clspv's wasm libclc build) need a real,
    # process-exec'd clang + llvm-link on the host — the wasm-compiled
    # ones in $PACKAGE_DIR/bin/ can't be invoked as subprocesses.
    #
    # Laid out under $PACKAGE_DIR/native/{bin,lib} (not the top-level bin/lib
    # which are owned by the wasm install) so clang's own prefix resolution
    # — realpath(argv[0])/../.. — finds its resource dir at
    # $PACKAGE_DIR/native/lib/clang/<ver>/ without us passing -resource-dir.
    NATIVE_PREFIX="$PACKAGE_DIR/native"
    echo "Bundling native clang + llvm-link into $NATIVE_PREFIX/bin/..."
    mkdir -p "$NATIVE_PREFIX/bin"
    # The real clang binary is clang-<major>; clang and clang++ are symlinks
    # to it. Copy the real binary + preserve any clang* symlinks so invoking
    # "clang" or "clang++" from native/bin/ resolves correctly. Include the
    # rest of libclc's required tool chain (llvm-as, llvm-link, opt) plus
    # llvm-config for version queries.
    for f in "$NATIVE_TOOLS_DIR"/clang "$NATIVE_TOOLS_DIR"/clang-[0-9]* \
             "$NATIVE_TOOLS_DIR"/clang++ \
             "$NATIVE_TOOLS_DIR"/llvm-as \
             "$NATIVE_TOOLS_DIR"/llvm-link \
             "$NATIVE_TOOLS_DIR"/opt \
             "$NATIVE_TOOLS_DIR"/llvm-config; do
        [ -e "$f" ] && cp -P "$f" "$NATIVE_PREFIX/bin/"
    done
    # Clang looks up its builtin headers (stddef.h, stdint.h, opencl-c.h, ...)
    # via <prefix>/lib/clang/<ver>/include/, prefix = dirname(dirname(clang)).
    # Ship the resource headers next to the native binaries.
    NATIVE_BUILD_ROOT="$(dirname "$NATIVE_TOOLS_DIR")"
    if [ -d "$NATIVE_BUILD_ROOT/lib/clang" ]; then
        mkdir -p "$NATIVE_PREFIX/lib/clang"
        cp -r "$NATIVE_BUILD_ROOT/lib/clang/"* "$NATIVE_PREFIX/lib/clang/"
    fi
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

# Bundle the FULL llvm-project source tree into the artifact so downstream
# consumers (clspv, spirv-llvm-translator) can reference any file they need.
# LLVM is a monorepo with heavy cross-subtree dependencies — clspv alone
# touches llvm/, clang/, cmake/, third-party/ (SipHash), runtimes/ and the
# add_subdirectory() graph reaches into test/, examples/, unittests/, etc.
# Earlier attempts to prune heavy bits (test/, examples/, docs/...) triggered
# cascading "missing directory" failures. Bundle everything minus .git and
# build outputs; let CMake flags decide what actually gets built.
#
# common.sh normalizes $OUTPUT_DIR (and therefore $PACKAGE_DIR) to POSIX form
# on MSYS2 via cygpath, so no drive-letter colons reach tar's path parser here.
echo "Bundling full llvm-project source tree into $PACKAGE_DIR/src..."
mkdir -p "$PACKAGE_DIR/src"
tar -cf - \
    --exclude=.git \
    --exclude=build \
    --exclude=build-native \
    -C .. . | tar -xf - -C "$PACKAGE_DIR/src"

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
