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
else
    CMAKE_CMD=("$CMAKE")
    MAKE_CMD=("$CMAKE")
fi

# Static-only build: libLLVMSPIRVLib.a is the only artifact, with undefined
# LLVM symbols that the downstream consumer (libmental_llvm.dylib) resolves
# by linking the same LLVM archives separately.  This replaces the previous
# per-platform split (darwin/linux shared, win/wasm static) — every
# platform now produces a static archive that libmental merges into one
# self-contained dylib on its side.  The dyld-symbol-leak hazard the old
# shared-lib visibility whitelist was guarding against (two LLVMs in one
# process) is structurally eliminated: the final dylib has exactly one
# LLVM.  Symbol visibility for the final dylib is controlled by its own
# exports list (cmake/mental-llvm-exports.txt).

"${CMAKE_CMD[@]}" .. \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DLLVM_DIR="$LLVM_BUILD/lib/cmake/llvm" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF

"${MAKE_CMD[@]}" --build . --config Release -j$NCPU

# Package
PACKAGE_DIR="$OUTPUT_DIR/spirv-llvm-translator-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib" "$PACKAGE_DIR/include"

echo "Packaging spirv-llvm-translator (static archive)..."
# Static-only packaging: one rule, every platform.
find lib -name "libLLVMSPIRVLib*.a" | while read f; do cp "$f" "$PACKAGE_DIR/lib/"; done

# Sanity check: fail loudly if the static archive didn't land where we
# expect.  Same rationale as the matching check in build-clspv.sh.
if [ -z "$(ls -A "$PACKAGE_DIR/lib/" 2>/dev/null)" ]; then
    echo "Error: libLLVMSPIRVLib.a was not produced by the translator build."
    echo "Build tree contents relevant to LLVMSPIRVLib:"
    find . -name 'libLLVMSPIRVLib*' -o -name 'LLVMSPIRVLib*'
    exit 1
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

# Shared-library symbol-visibility canary removed with the static-only
# switch — same reason as in build-clspv.sh.  Static .a archives have
# no dynamic symbol table to enforce against; visibility of the final
# libmental_llvm.dylib is controlled on the libmental side.

cd "$OUTPUT_DIR"
tar -czf "spirv-llvm-translator-${PLATFORM}.tar.gz" "spirv-llvm-translator-$PLATFORM"
echo "Created: spirv-llvm-translator-${PLATFORM}.tar.gz"
echo "Build complete!"
