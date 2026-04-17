#!/bin/bash
set -e

# Build clspv against llvm.
# Produces a shared library (native) or static library (WASM).
# Requires: llvm artifact (set LLVM_BUILD_DIR)

. "$(dirname "$0")/common.sh"

echo "Building clspv for $PLATFORM ($NCPU jobs)..."

if [ -z "$CMAKE" ]; then echo "Error: cmake not found"; exit 1; fi

# Find llvm artifact (install tree + bundled source tree)
LLVM_BUILD="${LLVM_BUILD_DIR:-$BUILD_DIR/llvm-project/build}"
if [ ! -d "$LLVM_BUILD/lib/cmake/llvm" ]; then
    echo "Error: llvm install tree not found at $LLVM_BUILD/lib/cmake/llvm"
    echo "Build llvm first, or set LLVM_BUILD_DIR"
    exit 1
fi
if [ ! -d "$LLVM_BUILD/src/llvm" ] || [ ! -d "$LLVM_BUILD/src/clang" ]; then
    echo "Error: llvm/clang source tree not found in artifact at $LLVM_BUILD/src/"
    echo "build-llvm.sh must bundle the source tree alongside the install tree"
    exit 1
fi
echo "Using llvm from: $LLVM_BUILD"

# clspv pulls LLVM's source CMakeLists.txt, which needs sibling directories
# of llvm/ (cmake/, third-party/) that the LLVM artifact doesn't bundle to
# keep it small. Fetch them here at the tag recorded in VERSION. This does
# NOT touch build-llvm.sh, so the cached LLVM artifacts remain valid.
#   - cmake/        — LLVM's shared cmake modules (included via ../cmake/...)
#   - third-party/  — vendored sources (e.g. siphash/SipHash.h for
#                     LLVMSupport, unittest/ for gtest when tests enabled)
if [ ! -d "$LLVM_BUILD/src/cmake" ] || [ ! -d "$LLVM_BUILD/src/third-party" ]; then
    if [ ! -f "$LLVM_BUILD/VERSION" ]; then
        echo "Error: $LLVM_BUILD/VERSION missing; can't determine LLVM tag for sibling fetch"
        exit 1
    fi
    LLVM_TAG="$(head -n1 "$LLVM_BUILD/VERSION" | tr -d '\r\n ')"
    if [ -z "$LLVM_TAG" ]; then
        echo "Error: $LLVM_BUILD/VERSION is empty"
        exit 1
    fi
    echo "Fetching LLVM sibling dirs (cmake/, third-party/) at $LLVM_TAG..."
    FETCH_DIR="$BUILD_DIR/llvm-sibling-fetch"
    rm -rf "$FETCH_DIR"
    git -c advice.detachedHead=false clone --depth 1 --filter=blob:none \
        --no-checkout --branch "$LLVM_TAG" \
        https://github.com/llvm/llvm-project.git "$FETCH_DIR"
    (cd "$FETCH_DIR" && git sparse-checkout set cmake third-party && git checkout)
    [ ! -d "$LLVM_BUILD/src/cmake" ] && cp -r "$FETCH_DIR/cmake" "$LLVM_BUILD/src/cmake"
    [ ! -d "$LLVM_BUILD/src/third-party" ] && cp -r "$FETCH_DIR/third-party" "$LLVM_BUILD/src/third-party"
    rm -rf "$FETCH_DIR"
fi

# Stub out subdirectories that build-llvm.sh excluded from the LLVM/Clang
# source bundle. LLVM/Clang/clspv do unconditional add_subdirectory() calls
# on these paths (the LLVM_INCLUDE_* / CLANG_INCLUDE_* flags guard the *build*
# logic, not the subdir inclusion itself). An empty CMakeLists.txt makes
# add_subdirectory a no-op, and satisfies ExternalProject_Add's
# "existing non-empty directory" check.
STUB_CMAKELISTS='cmake_minimum_required(VERSION 3.13.4)
project(stub LANGUAGES NONE)
# Placeholder for a subtree excluded from the LLVM source bundle.
'
for stub in \
    runtimes \
    clang/examples \
    clang/unittests \
    clang/test \
    clang/docs \
    clang/bindings \
    clang/bindings/python/tests; do
    STUB_PATH="$LLVM_BUILD/src/$stub"
    mkdir -p "$STUB_PATH"
    if [ ! -f "$STUB_PATH/CMakeLists.txt" ]; then
        printf '%s' "$STUB_CMAKELISTS" > "$STUB_PATH/CMakeLists.txt"
    fi
done

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

# WASM libclc prep. Native clspv builds its own libclc in-tree (its CMake
# calls clang directly from the local build). That works on native because
# the clang being built is natively-executable. On WASM, the clang compiled
# by emcmake is a .wasm module — can't be process-exec'd to drive libclc's
# per-file .cl → .bc compiles. So we build libclc here first, using the
# native clang + llvm-link + opt that build-llvm.sh ships at
# $LLVM_BUILD/native/bin/, and feed the resulting spir-- bitcode to clspv
# via CLSPV_EXTERNAL_LIBCLC_DIR.
if [ "$IS_WASM" -eq 1 ]; then
    NATIVE_BIN="$LLVM_BUILD/native/bin"
    for tool in clang llvm-link opt; do
        if [ ! -x "$NATIVE_BIN/$tool" ]; then
            echo "Error: native $tool not found at $NATIVE_BIN/"
            echo "build-llvm.sh must bundle native tools (Phase 1 output) for WASM"
            exit 1
        fi
    done
    if [ ! -d "$LLVM_BUILD/src/libclc" ]; then
        echo "Error: libclc source not found at $LLVM_BUILD/src/libclc"
        echo "build-llvm.sh must bundle the full llvm-project source tree"
        exit 1
    fi

    LIBCLC_BUILD="$BUILD_DIR/libclc-build"
    LIBCLC_INSTALL="$BUILD_DIR/libclc-install"
    if [ ! -f "$LIBCLC_INSTALL/spir--/libclc.bc" ]; then
        echo "=== WASM libclc prep: building spir-- bitcode ==="
        rm -rf "$LIBCLC_BUILD"
        mkdir -p "$LIBCLC_BUILD"
        # Prepend native tools to PATH so libclc's find_program(clang ...),
        # llvm-link, opt all resolve to our shipped binaries — most robust
        # way to steer libclc without guessing its exact CMake variable names.
        (cd "$LIBCLC_BUILD" && \
            PATH="$NATIVE_BIN:$PATH" \
            "$CMAKE" "$LLVM_BUILD/src/libclc" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="$LIBCLC_INSTALL" \
                -DLIBCLC_TARGETS_TO_BUILD="spir--" \
                -DLLVM_DIR="$LLVM_BUILD/lib/cmake/llvm" && \
            PATH="$NATIVE_BIN:$PATH" \
            "$CMAKE" --build . --config Release -j$NCPU && \
            PATH="$NATIVE_BIN:$PATH" \
            "$CMAKE" --install .)

        # clspv looks for $CLSPV_EXTERNAL_LIBCLC_DIR/spir--/libclc.bc. libclc
        # installs under <prefix>/share/clc/... with naming variants across
        # LLVM versions (spir--.bc, spir--/libclc.bc, etc.). Find whatever
        # got produced and arrange it at the path clspv expects.
        LIBCLC_BC=$(find "$LIBCLC_INSTALL" -type f -name '*.bc' | head -1)
        if [ -z "$LIBCLC_BC" ]; then
            echo "Error: libclc build produced no .bc file; install tree:"
            find "$LIBCLC_INSTALL" -type f
            exit 1
        fi
        mkdir -p "$LIBCLC_INSTALL/spir--"
        [ -f "$LIBCLC_INSTALL/spir--/libclc.bc" ] || cp "$LIBCLC_BC" "$LIBCLC_INSTALL/spir--/libclc.bc"
        echo "libclc ready at: $LIBCLC_INSTALL/spir--/libclc.bc"
    else
        echo "Reusing cached libclc at: $LIBCLC_INSTALL/spir--/libclc.bc"
    fi

    LIBCLC_DIR="$LIBCLC_INSTALL"
fi

# Arrays (not strings) so $CMAKE with spaces (e.g. Git Bash resolving to
# "/c/Program Files/CMake/bin/cmake.exe" when MSYS2 isn't installed on the
# Windows runner) survives word-splitting at expansion time.
if [ "$IS_WASM" -eq 1 ]; then
    CMAKE_CMD=(emcmake "$CMAKE")
    MAKE_CMD=(emmake "$CMAKE")
    CLSPV_EXTRA="-DCLSPV_EXTERNAL_LIBCLC_DIR=$LIBCLC_DIR"
else
    CMAKE_CMD=("$CMAKE")
    MAKE_CMD=("$CMAKE")
    CLSPV_EXTRA=""
fi

"${CMAKE_CMD[@]}" .. \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCLSPV_LLVM_SOURCE_DIR="$LLVM_BUILD/src/llvm" \
    -DCLSPV_CLANG_SOURCE_DIR="$LLVM_BUILD/src/clang" \
    -DCLSPV_LLVM_BINARY_DIR="$LLVM_BUILD" \
    -DCLSPV_SHARED_LIB=ON \
    -DCLSPV_BUILD_TESTS=OFF \
    -DCLSPV_BUILD_SPIRV_DIS=OFF \
    -DENABLE_CLSPV_OPT=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_RUNTIMES="" \
    -DLLVM_BUILD_RUNTIME=OFF \
    -DLLVM_BUILD_RUNTIMES=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_DOCS=OFF \
    -DCLANG_BUILD_EXAMPLES=OFF \
    -DCLANG_INCLUDE_EXAMPLES=OFF \
    $CLSPV_EXTRA

"${MAKE_CMD[@]}" --build . --config Release --target clspv_core -j$NCPU

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
