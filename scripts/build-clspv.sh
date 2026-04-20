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
    # $LLVM_TAG is now a commit SHA (build-llvm.sh pins to clspv's pinned
    # commit), not a branch/tag name. Use codeload tarball instead of git
    # clone so we don't need to resolve the SHA as a ref.
    curl -sSLf "https://codeload.github.com/llvm/llvm-project/tar.gz/$LLVM_TAG" | \
        tar -xz -C "$BUILD_DIR" && \
        mv "$BUILD_DIR/llvm-project-$LLVM_TAG" "$FETCH_DIR"
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
    # libclc (libclc/CMakeLists.txt:137) requires clang/opt/llvm-as/llvm-link.
    # clspv's cross-compile needs tablegens (llvm-min-tblgen, llvm-tblgen,
    # clang-tblgen) passed explicitly — otherwise LLVM's CrossCompile.cmake
    # spawns a "NATIVE" sub-build which inherits emmake's em++ and produces
    # Emscripten modules unable to see the host filesystem.
    for tool in clang llvm-as llvm-link opt llvm-min-tblgen llvm-tblgen clang-tblgen; do
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
    # clspv's cmake (clspv/cmake/CMakeLists.txt) hardcodes the lookup at
    #   $CLSPV_EXTERNAL_LIBCLC_DIR/spir--/libclc.bc        (32-bit)
    #   $CLSPV_EXTERNAL_LIBCLC_DIR/spir64--/libclc.bc      (64-bit)
    # We build libclc with LLVM_RUNTIMES_TARGET=clspv--/clspv64-- (the
    # modern build-time triples libclc accepts). libclc internally maps
    # those to spir--/spir64-- in the install layout:
    #   $LIBCLC_INSTALL/share/clc/spir--/libclc.bc
    #   $LIBCLC_INSTALL/share/clc/spir64--/libclc.bc
    # — exactly what clspv wants, so we set CLSPV_EXTERNAL_LIBCLC_DIR to
    # $LIBCLC_INSTALL/share/clc and no renaming is needed.
    LIBCLC_SHARE="$LIBCLC_INSTALL/share/clc"
    if [ ! -f "$LIBCLC_SHARE/spir--/libclc.bc" ] || [ ! -f "$LIBCLC_SHARE/spir64--/libclc.bc" ]; then
        echo "=== WASM libclc prep: building clspv-- and clspv64-- bitcode ==="
        rm -rf "$LIBCLC_BUILD"
        # libclc's CMake (commit 121f5a96ff38) changed from accepting a
        # list via LIBCLC_TARGETS_TO_BUILD to a single target per configure
        # via LLVM_RUNTIMES_TARGET. To get both 32-bit and 64-bit bitcode
        # we do TWO configure + build + install cycles, one per triple.
        #
        # Tool discovery in this libclc version splits two ways:
        # - enable_language(CLC) via CMakeCLCInformation.cmake: calls
        #   find_llvm_tool(llvm-ar ...) and (llvm-ranlib ...) relative to
        #   CMAKE_CLC_COMPILER's parent dir. Pointing CMAKE_C_COMPILER at
        #   our native clang implicitly directs CLC there too, and those
        #   tools are in the same bin/, so that side "just works."
        # - libclc/CMakeLists.txt standalone branch: calls find_program for
        #   opt and llvm-link with PATHS=$LLVM_TOOLS_BINARY_DIR NO_DEFAULT_PATH.
        #   LLVM_TOOLS_BINARY_DIR is set by find_package(LLVM) to the wasm
        #   install's bin/ (non-executable .js/.wasm stubs — no plain 'opt'
        #   file). The prior LIBCLC_CUSTOM_LLVM_TOOLS_BINARY_DIR escape hatch
        #   was removed in this version. We preempt find_program instead:
        #   pre-seeding LLVM_TOOL_opt / LLVM_TOOL_llvm-link as cache vars
        #   makes find_program return the cached value without searching.
        #
        # Also: enable_language(CLC) requires CMAKE_C_COMPILER to be clang;
        # Ubuntu's default /usr/bin/cc is gcc. We point at our native clang.
        for triple in clspv-- clspv64--; do
            LIBCLC_BUILD_PER="$LIBCLC_BUILD/$triple"
            mkdir -p "$LIBCLC_BUILD_PER"
            (cd "$LIBCLC_BUILD_PER" && \
                "$CMAKE" "$LLVM_BUILD/src/libclc" \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_INSTALL_PREFIX="$LIBCLC_INSTALL" \
                    -DCMAKE_C_COMPILER="$NATIVE_BIN/clang" \
                    -DCMAKE_CXX_COMPILER="$NATIVE_BIN/clang++" \
                    -DLLVM_RUNTIMES_TARGET="$triple" \
                    -DLLVM_DIR="$LLVM_BUILD/lib/cmake/llvm" \
                    -DLLVM_TOOL_opt="$NATIVE_BIN/opt" \
                    -DLLVM_TOOL_llvm-link="$NATIVE_BIN/llvm-link" && \
                "$CMAKE" --build . --config Release -j$NCPU && \
                "$CMAKE" --install .)
        done

        # Verify libclc installed where we expect. If the layout changes
        # in a future libclc bump, this surfaces the drift loudly.
        for triple in spir-- spir64--; do
            if [ ! -f "$LIBCLC_SHARE/$triple/libclc.bc" ]; then
                echo "Error: libclc did not install $triple/libclc.bc under $LIBCLC_SHARE"
                echo "Actual install tree:"
                find "$LIBCLC_INSTALL" -type f
                exit 1
            fi
            echo "Found $LIBCLC_SHARE/$triple/libclc.bc"
        done
    else
        echo "Reusing cached libclc at: $LIBCLC_SHARE/{spir--,spir64--}/libclc.bc"
    fi

    LIBCLC_DIR="$LIBCLC_SHARE"
fi

# Arrays (not strings) so $CMAKE with spaces (e.g. Git Bash resolving to
# "/c/Program Files/CMake/bin/cmake.exe" when MSYS2 isn't installed on the
# Windows runner) survives word-splitting at expansion time.
if [ "$IS_WASM" -eq 1 ]; then
    CMAKE_CMD=(emcmake "$CMAKE")
    MAKE_CMD=(emmake "$CMAKE")
    # Feed clspv the pre-built native tablegens and native tool dir so LLVM's
    # CrossCompile.cmake skips its NATIVE sub-build. Without these, that
    # sub-build inherits emmake's em++ and produces Emscripten tools that
    # can't see host files (see build-llvm.sh's native bundle comment).
    CLSPV_EXTRA="-DCLSPV_EXTERNAL_LIBCLC_DIR=$LIBCLC_DIR \
        -DLLVM_TABLEGEN=$NATIVE_BIN/llvm-tblgen \
        -DCLANG_TABLEGEN=$NATIVE_BIN/clang-tblgen \
        -DLLVM_CONFIG_PATH=$NATIVE_BIN/llvm-config \
        -DLLVM_NATIVE_TOOL_DIR=$NATIVE_BIN"
else
    CMAKE_CMD=("$CMAKE")
    MAKE_CMD=("$CMAKE")
    CLSPV_EXTRA=""
fi

# On shared-lib platforms (darwin/linux) restrict libclspv_core's export
# table to clspv's public C/C++ API.  Without this, the statically-linked
# LLVM inside the dylib leaks ~14k mangled llvm::* symbols into dyld's
# global table and cross-binds with other LLVM-embedding images in the
# process (libmental, libLLVMSPIRVLib) → class-layout-mismatch segfault.
# See scripts/clspv-exports.txt for rationale and pattern list.
CLSPV_EXPORT_LINKER_FLAGS=""
if [ "$IS_WASM" -ne 1 ] && [[ "$OSTYPE" != "msys" && "$OSTYPE" != "cygwin" && "$OSTYPE" != "win32" ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        CLSPV_EXPORT_LINKER_FLAGS="-Wl,-exported_symbols_list,$SCRIPT_DIR/clspv-exports.txt"
    else
        CLSPV_EXPORT_LINKER_FLAGS="-Wl,--version-script=$SCRIPT_DIR/clspv-exports.ld"
    fi
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
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_DOCS=OFF \
    -DCLANG_BUILD_EXAMPLES=OFF \
    -DCLANG_INCLUDE_EXAMPLES=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="$CLSPV_EXPORT_LINKER_FLAGS" \
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
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    # MinGW shared-lib output is libclspv_core.dll + libclspv_core.dll.a
    # (import lib). Copy both so downstream consumers can link + load.
    # The prior linux-only find -name "*.so*" pattern missed these and
    # produced empty Windows artifacts silently.
    find . -name "libclspv_core*.dll" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
    find . -name "libclspv_core*.dll.a" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
else
    find . -name "libclspv_core*.so*" | while read f; do cp -P "$f" "$PACKAGE_DIR/lib/"; done
fi

# Sanity check: the artifact must actually contain libclspv_core.* — the
# prior silent-empty-artifact state (Windows .dll missed by *.so* glob)
# passed CI with a 0-byte clspv-*.tar.gz that only surfaced at release
# upload. Fail here instead.
if [ -z "$(ls -A "$PACKAGE_DIR/lib/" 2>/dev/null)" ]; then
    echo "Error: no clspv core library was packaged for $PLATFORM."
    echo "Build tree contents relevant to clspv_core:"
    find . -name 'libclspv_core*' -o -name 'clspv_core*'
    exit 1
fi

# Headers
cp ../include/clspv/Compiler.h "$PACKAGE_DIR/include/clspv/"
find ../include/clspv -name "*.h" -exec cp {} "$PACKAGE_DIR/include/clspv/" \; 2>/dev/null || true

# License
cp ../LICENSE "$PACKAGE_DIR/LICENSE"

# Canary: verify the shared-lib export restriction actually took hold.
# Only runs on native shared-lib builds (WASM static archives don't have
# a visibility concept; Windows uses __declspec(dllexport) defaults).
#
# Grep pattern matches ONLY symbols whose OWNING namespace is llvm::
# (mangled prefix _ZN4llvm<length>Name).  A naive "contains PassManager"
# would false-positive on clspv::*::run(llvm::Module&, llvm::AnalysisManager&)
# which takes those LLVM types as parameters but lives in the clspv::
# namespace.  See matching fix in build-spirv-llvm-translator.sh.
if [ "$IS_WASM" -ne 1 ] && [[ "$OSTYPE" != "msys" && "$OSTYPE" != "cygwin" && "$OSTYPE" != "win32" ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        LIB_TO_CHECK=$(ls "$PACKAGE_DIR/lib/"libclspv_core*.dylib 2>/dev/null | head -1)
        if [ -n "$LIB_TO_CHECK" ]; then
            leaked=$(nm -gU "$LIB_TO_CHECK" 2>/dev/null | \
                grep -E "__ZN4llvm11PassManager|__ZN4llvm15AnalysisManager|__ZN4llvm6Module" | head -3 || true)
            if [ -n "$leaked" ]; then
                echo "Error: LLVM internals leaked from $LIB_TO_CHECK:" >&2
                echo "$leaked" >&2
                echo "       exports list at $SCRIPT_DIR/clspv-exports.txt" \
                     "didn't restrict the symbol table — check CMAKE_SHARED_LINKER_FLAGS" \
                     "propagation and the exported_symbols_list patterns." >&2
                exit 1
            fi
        fi
    else
        LIB_TO_CHECK=$(ls "$PACKAGE_DIR/lib/"libclspv_core*.so* 2>/dev/null | head -1)
        if [ -n "$LIB_TO_CHECK" ]; then
            leaked=$(nm -D --defined-only "$LIB_TO_CHECK" 2>/dev/null | \
                grep -E "_ZN4llvm11PassManager|_ZN4llvm15AnalysisManager|_ZN4llvm6Module" | head -3 || true)
            if [ -n "$leaked" ]; then
                echo "Error: LLVM internals leaked from $LIB_TO_CHECK:" >&2
                echo "$leaked" >&2
                exit 1
            fi
        fi
    fi
fi

cd "$OUTPUT_DIR"
tar -czf "clspv-${PLATFORM}.tar.gz" "clspv-$PLATFORM"
echo "Created: clspv-${PLATFORM}.tar.gz"
echo "Build complete!"
