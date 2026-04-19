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

"${CMAKE_CMD[@]}" .. \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DLLVM_DIR="$LLVM_BUILD/lib/cmake/llvm" \
    -DBUILD_SHARED_LIBS=$SHARED \
    -DLLVM_INCLUDE_TESTS=OFF

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

cd "$OUTPUT_DIR"
tar -czf "spirv-llvm-translator-${PLATFORM}.tar.gz" "spirv-llvm-translator-$PLATFORM"
echo "Created: spirv-llvm-translator-${PLATFORM}.tar.gz"
echo "Build complete!"
