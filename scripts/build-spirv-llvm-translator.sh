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
    # Track SLT's main branch — our LLVM tracks clspv's pin (also on main),
    # so matching here keeps the LLVM IR contract consistent. SLT's
    # llvm_release_* branches line up with LLVM stable releases; they'd
    # drift against our main-pinned LLVM.
    echo "Cloning SPIRV-LLVM-Translator (main)..."
    git clone --depth 1 --branch main https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git
fi

cd SPIRV-LLVM-Translator
if [ ! -f "LICENSE.TXT" ]; then echo "Error: LICENSE.TXT not found"; exit 1; fi

mkdir -p build
cd build

# Arrays (not strings) so $CMAKE with spaces (e.g. Git Bash resolving to
# "/c/Program Files/CMake/bin/cmake.exe" when MSYS2 isn't installed on the
# Windows runner) survives word-splitting at expansion time.
if [ "$IS_WASM" -eq 1 ]; then
    CMAKE_CMD=(emcmake "$CMAKE")
    MAKE_CMD=(emmake "$CMAKE")
    SHARED=OFF
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    # Windows: LLVM is distributed as static .a archives. Building
    # SPIRV-LLVM-Translator with BUILD_SHARED_LIBS=ON bundles those statics
    # into libLLVMSPIRVLib.dll, and its import lib then re-exports the LLVM
    # symbols. Linking llvm-spirv.exe pulls both the import lib and LLVM's
    # static .a → "multiple definition" errors. Match WASM and go static.
    CMAKE_CMD=("$CMAKE")
    MAKE_CMD=("$CMAKE")
    SHARED=OFF
else
    CMAKE_CMD=("$CMAKE")
    MAKE_CMD=("$CMAKE")
    SHARED=ON
fi

# On shared-lib platforms (darwin/linux) restrict the dylib's export table
# to the translator's public API only.  The static-linked LLVM this dylib
# embeds would otherwise leak ~14k mangled llvm::* symbols into dyld's
# global table, which — since libmental and libclspv_core each carry
# their own private LLVM — can cross-bind at load time and crash when
# class layouts don't match.  See scripts/spirv-llvm-translator-exports.txt
# for the full rationale and pattern list.
EXPORT_LINKER_FLAGS=""
if [ "$SHARED" = "ON" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        EXPORT_LINKER_FLAGS="-Wl,-exported_symbols_list,$SCRIPT_DIR/spirv-llvm-translator-exports.txt"
    else
        EXPORT_LINKER_FLAGS="-Wl,--version-script=$SCRIPT_DIR/spirv-llvm-translator-exports.ld"
    fi
fi

"${CMAKE_CMD[@]}" .. \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DLLVM_DIR="$LLVM_BUILD/lib/cmake/llvm" \
    -DBUILD_SHARED_LIBS=$SHARED \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="$EXPORT_LINKER_FLAGS"

"${MAKE_CMD[@]}" --build . --config Release -j$NCPU

# Package
PACKAGE_DIR="$OUTPUT_DIR/spirv-llvm-translator-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib" "$PACKAGE_DIR/include"

echo "Packaging spirv-llvm-translator..."
if [ "$IS_WASM" -eq 1 ] || [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    # WASM + Windows: static .a (see SHARED=OFF branch above)
    find lib -name "*.a" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
elif [[ "$OSTYPE" == "darwin"* ]]; then
    find lib -name "libLLVMSPIRVLib*.dylib" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done
else
    find lib -name "libLLVMSPIRVLib*.so*" | while read f; do cp -P "$f" "$PACKAGE_DIR/lib/"; done
fi

# Ship every public header SPIRV-LLVM-Translator exposes.  Upstream places
# them flat under include/ (not in a subdir), and LLVMSPIRVLib.h transitively
# needs both LLVMSPIRVOpts.h AND the LLVMSPIRVExtensions.inc it #includes.
# A prior version globbed a non-existent "include/LLVMSPIRVLib/" directory
# with "|| true", silently shipping only LLVMSPIRVLib.h and breaking any
# downstream that actually #include'd the header.
cp ../include/*.h ../include/*.inc "$PACKAGE_DIR/include/"

# Canary: confirm the three headers downstream compiles require all landed.
# Fail loud — silent packaging gaps are the whole reason this check exists.
for required in LLVMSPIRVLib.h LLVMSPIRVOpts.h LLVMSPIRVExtensions.inc; do
    if [ ! -f "$PACKAGE_DIR/include/$required" ]; then
        echo "Error: required header $required missing from package" >&2
        echo "       upstream include/ contained:" >&2
        ls -1 ../include/ >&2
        exit 1
    fi
done

cp ../LICENSE.TXT "$PACKAGE_DIR/LICENSE.TXT"

# Canary: verify the shared-lib export restriction actually took effect.
# If LLVM internals (PassManager, AnalysisManager, Module, etc.) leak into
# the dylib's dynamic symbol table, the cross-binding crash this whole
# exports list is meant to prevent will reappear at runtime.
# Canary grep pattern: only flag symbols whose OWNING namespace is llvm:: —
# mangled prefixes `_ZN4llvm11PassManager`, `_ZN4llvm15AnalysisManager`,
# `_ZN4llvm6Module`.  Naive "contains PassManager" would false-positive
# on SPIRV::*Pass::run(llvm::Module&, llvm::AnalysisManager&) which takes
# those LLVM types as PARAMETERS but lives in the SPIRV:: namespace.
# The darwin symbol table adds a leading underscore (`__ZN4llvm...`);
# Linux's ELF symbol table does not (`_ZN4llvm...`).
if [ "$SHARED" = "ON" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        LIB_TO_CHECK=$(ls "$PACKAGE_DIR/lib/"libLLVMSPIRVLib*.dylib 2>/dev/null | head -1)
        if [ -n "$LIB_TO_CHECK" ]; then
            leaked=$(nm -gU "$LIB_TO_CHECK" 2>/dev/null | \
                grep -E "__ZN4llvm11PassManager|__ZN4llvm15AnalysisManager|__ZN4llvm6Module" | head -3 || true)
            if [ -n "$leaked" ]; then
                echo "Error: LLVM internals leaked from $LIB_TO_CHECK:" >&2
                echo "$leaked" >&2
                echo "       exports list at $SCRIPT_DIR/spirv-llvm-translator-exports.txt" \
                     "didn't restrict the symbol table — check CMAKE_SHARED_LINKER_FLAGS" \
                     "propagation and the exported_symbols_list patterns." >&2
                exit 1
            fi
        fi
    elif [[ "$OSTYPE" != "msys" && "$OSTYPE" != "cygwin" && "$OSTYPE" != "win32" ]]; then
        LIB_TO_CHECK=$(ls "$PACKAGE_DIR/lib/"libLLVMSPIRVLib*.so* 2>/dev/null | head -1)
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
tar -czf "spirv-llvm-translator-${PLATFORM}.tar.gz" "spirv-llvm-translator-$PLATFORM"
echo "Created: spirv-llvm-translator-${PLATFORM}.tar.gz"
echo "Build complete!"
