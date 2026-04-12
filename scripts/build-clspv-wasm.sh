#!/bin/bash
set -e

# Build script for clspv (OpenCL C to Vulkan SPIR-V compiler) — WebAssembly target
# Clones upstream clspv, applies Emscripten compatibility fixes if needed, and builds
# a clspv.js + clspv.wasm pair plus a combined static library for direct linking.
#
# Requires: Emscripten SDK (emcmake/emmake on PATH)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"
PLATFORM="wasm"

echo "Building clspv for WebAssembly..."

# Verify Emscripten is available
if ! command -v emcmake &> /dev/null; then
    echo "Error: emcmake not found. Install the Emscripten SDK first."
    exit 1
fi

# clspv/LLVM is massive — limit parallelism to avoid OOM
NCPU=2

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone clspv
if [ ! -d "clspv-wasm-src" ]; then
    echo "Cloning clspv..."
    git clone https://github.com/google/clspv.git clspv-wasm-src
fi

cd clspv-wasm-src

# Find Python — command -v may not resolve MinGW executables on MSYS2,
# so fall back to probing known install locations directly.
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [ -z "$PYTHON" ]; then
    for p in /ucrt64/bin/python3.exe /ucrt64/bin/python.exe /mingw64/bin/python3.exe /mingw64/bin/python.exe; do
        if [ -x "$p" ]; then
            PYTHON="$p"
            break
        fi
    done
fi
if [ -z "$PYTHON" ]; then
    echo "Error: Python not found (needed for utils/fetch_sources.py)"
    echo "PATH=$PATH"
    ls /ucrt64/bin/python* /mingw64/bin/python* /usr/bin/python* 2>/dev/null || echo "  (no python binaries found)"
    exit 1
fi
echo "Using Python: $PYTHON"

# Fetch dependencies (LLVM, Clang, SPIRV-Tools, SPIRV-Headers)
if [ ! -d "third_party/llvm" ]; then
    echo "Fetching clspv dependencies (LLVM, SPIRV-Tools, etc.)..."
    $PYTHON utils/fetch_sources.py
fi

# Verify license exists (fail fast)
echo "Verifying license file..."
if [ ! -f "LICENSE" ]; then
    echo "Error: LICENSE not found in clspv repository"
    exit 1
fi
echo "License file verified"

# Apply Emscripten compatibility patches if they exist
PATCH_FILE="$SCRIPT_DIR/../patches/clspv-emscripten.patch"
if [ -f "$PATCH_FILE" ]; then
    echo "Applying Emscripten compatibility patches..."
    git apply "$PATCH_FILE"
    echo "Emscripten patches applied successfully"
else
    echo "No Emscripten patches found — building without patches"
fi

# ================================================================
#  Phase 1: Build libclc NATIVELY
#
#  clspv needs libclc's .bc files to generate its builtin header
#  (clspv_builtin_library.h).  libclc requires building clang and
#  an LLVM native backend — which can't be done under Emscripten.
#
#  Solution: build libclc with the host compiler first, then pass
#  the .bc files to the WASM build via CLSPV_EXTERNAL_LIBCLC_DIR.
# ================================================================
echo ""
echo "=== Phase 1: Building libclc + native tools (host compiler) ==="
mkdir -p build-native
cd build-native

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCLSPV_BUILD_TESTS=OFF \
    -DCLSPV_BUILD_SPIRV_DIS=OFF \
    -DENABLE_CLSPV_OPT=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF

echo "Building libclc + clspv natively (~60-90 minutes)..."
echo "  (Phase 2 will reuse the native tablegen/tblgen tools for WASM cross-compilation)"
cmake --build . --target clspv -j$NCPU

# Locate the libclc .bc files
LIBCLC_BC=$(find . -path "*/spir--/libclc.bc" -print -quit)
if [ -z "$LIBCLC_BC" ]; then
    echo "Error: libclc.bc not found after native build"
    find . -name "libclc.bc" 2>/dev/null || echo "  (no libclc.bc files found)"
    exit 1
fi
LIBCLC_DIR=$(dirname "$(dirname "$LIBCLC_BC")")
LIBCLC_DIR_ABS="$(cd "$LIBCLC_DIR" && pwd)"
echo "libclc built successfully: $LIBCLC_DIR_ABS"

# Save libclc .bc files
LIBCLC_SAVED="$BUILD_DIR/libclc-prebuilt"
mkdir -p "$LIBCLC_SAVED"
cp -r "$LIBCLC_DIR_ABS"/* "$LIBCLC_SAVED/"

# Save native tool binaries (tablegen, tblgen, etc.) for Phase 2.
# These let the WASM cross-compilation skip the broken NATIVE bootstrap.
NATIVE_TOOLS="$BUILD_DIR/native-tools"
mkdir -p "$NATIVE_TOOLS"
echo "Locating native tools in build tree..."
for tool in llvm-min-tblgen llvm-tblgen clang-tblgen llvm-config; do
    FOUND=$(find . -name "$tool" -type f -executable 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        cp "$FOUND" "$NATIVE_TOOLS/"
        echo "  Saved: $tool (from $FOUND)"
    else
        echo "  Not found: $tool"
    fi
done
echo "Native tools saved:"
ls -la "$NATIVE_TOOLS/"

cd "$BUILD_DIR/clspv-wasm-src"
echo "Cleaning Phase 1 build objects (keeping source tree)..."
rm -rf build-native
echo "Disk after cleanup:"
df -h . | tail -1

# ================================================================
#  Phase 2: Build clspv for WebAssembly
#
#  Use CLSPV_EXTERNAL_LIBCLC_DIR for pre-built libclc, and
#  LLVM_NATIVE_TOOL_DIR for pre-built host tools (tablegen, etc.).
#  This avoids the NATIVE tools bootstrap that fails under
#  Emscripten because it can't resolve source-tree paths for
#  tablegen .td files during cross-compilation.
# ================================================================
echo ""
echo "=== Phase 2: Building clspv for WebAssembly ==="
mkdir -p build
cd build

echo "Configuring clspv for WebAssembly..."
emcmake cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCLSPV_EXTERNAL_LIBCLC_DIR="$LIBCLC_SAVED" \
    -DLLVM_TABLEGEN="$NATIVE_TOOLS/llvm-tblgen" \
    -DCLANG_TABLEGEN="$NATIVE_TOOLS/clang-tblgen" \
    -DLLVM_ENABLE_EH=ON \
    -DLLVM_ENABLE_RTTI=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-sNO_DISABLE_EXCEPTION_CATCHING -sNO_DISABLE_EXCEPTION_THROWING" \
    -DCLSPV_BUILD_TESTS=OFF \
    -DCLSPV_BUILD_SPIRV_DIS=OFF \
    -DENABLE_CLSPV_OPT=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_ZLIB=OFF

echo "Building clspv for WebAssembly (this may take 20-40 minutes)..."
emmake cmake --build . --config Release --target clspv -j$NCPU

# Package output
PACKAGE_DIR="$OUTPUT_DIR/clspv-$PLATFORM"
mkdir -p "$PACKAGE_DIR/bin"

echo "Packaging clspv WASM..."
# Emscripten produces a .js loader and .wasm binary.
# LLVM's build system may append a version suffix (e.g. clspv.js-3.7 + clspv.js-3.wasm),
# so we find the actual files by glob and rename them to clean names.
CLSPV_JS=$(find bin -name "clspv.js*" -not -name "*.wasm" 2>/dev/null | head -1)
CLSPV_WASM=$(find bin -name "clspv.js*.wasm" -o -name "clspv.wasm" 2>/dev/null | head -1)

if [ -z "$CLSPV_JS" ] || [ -z "$CLSPV_WASM" ]; then
    echo "Warning: clspv WASM JS/WASM outputs not found in bin/"
    echo "Build output contents:"
    find bin -type f -name "clspv*" 2>/dev/null || echo "  (no clspv files found in bin/)"
    echo "Continuing with static library packaging..."
else
    cp "$CLSPV_JS" "$PACKAGE_DIR/bin/clspv.js"
    cp "$CLSPV_WASM" "$PACKAGE_DIR/bin/clspv.wasm"
    echo "Packaged: $CLSPV_JS -> clspv.js, $CLSPV_WASM -> clspv.wasm"
fi

# Package static library — merge all .a files into a single combined archive
# so consumers can link clspv without tracking ~50 individual LLVM libraries.
echo "Creating combined static library..."
mkdir -p "$PACKAGE_DIR/lib"
COMBINED_LIB="$PACKAGE_DIR/lib/libclspv-full.a"

# Collect all .a files from the entire build tree (CMake scatters them
# across nested directories, not just lib/)
ALL_ARCHIVES=$(find . -name "*.a" -type f 2>/dev/null)
if [ -z "$ALL_ARCHIVES" ]; then
    echo "Warning: No static libraries found — skipping library packaging"
else
    # Create a combined archive using Emscripten's emar
    # Extract all objects into a temp dir, then repack
    MERGE_DIR=$(mktemp -d)
    BUILD_ABS="$(pwd)"
    for archive in $ALL_ARCHIVES; do
        # Extract each archive into a uniquely-named subdirectory to avoid name collisions
        SUBDIR="$MERGE_DIR/$(echo "$archive" | tr '/' '_')"
        mkdir -p "$SUBDIR"
        cd "$SUBDIR"
        emar x "$BUILD_ABS/$archive" 2>/dev/null || true
        cd "$BUILD_ABS"
    done
    # Repack all objects into one archive
    emar rcs "$COMBINED_LIB" $(find "$MERGE_DIR" -name "*.o" -type f)
    rm -rf "$MERGE_DIR"
    echo "Created: libclspv-full.a ($(du -h "$COMBINED_LIB" | cut -f1))"
fi

# Package headers — clspv's public API for direct main() invocation
echo "Packaging headers..."
mkdir -p "$PACKAGE_DIR/include"
cd "$BUILD_DIR/clspv-wasm-src"
# The main entry point header — consumers call clspv's main() directly
if [ -f "include/clspv/Compiler.h" ]; then
    mkdir -p "$PACKAGE_DIR/include/clspv"
    cp include/clspv/Compiler.h "$PACKAGE_DIR/include/clspv/"
fi
# Copy any other public headers
find include/clspv -name "*.h" -exec cp {} "$PACKAGE_DIR/include/clspv/" \; 2>/dev/null || true

# Copy licenses
echo "Packaging licenses..."
cd "$BUILD_DIR/clspv-wasm-src"
mkdir -p "$PACKAGE_DIR/licenses/clspv/LICENSES"

# Main license (Apache 2.0 with LLVM Exceptions)
cp LICENSE "$PACKAGE_DIR/licenses/clspv/LICENSE"

# Bundled dependency licenses
if [ -f "third_party/llvm/llvm/LICENSE.TXT" ]; then
    cp "third_party/llvm/llvm/LICENSE.TXT" "$PACKAGE_DIR/licenses/clspv/LICENSES/LLVM-LICENSE.TXT"
fi
if [ -f "third_party/SPIRV-Tools/LICENSE" ]; then
    cp "third_party/SPIRV-Tools/LICENSE" "$PACKAGE_DIR/licenses/clspv/LICENSES/SPIRV-Tools-LICENSE"
fi
if [ -f "third_party/SPIRV-Headers/LICENSE" ]; then
    cp "third_party/SPIRV-Headers/LICENSE" "$PACKAGE_DIR/licenses/clspv/LICENSES/SPIRV-Headers-LICENSE"
fi

# Create archive
cd "$OUTPUT_DIR"
tar -czf "clspv-${PLATFORM}.tar.gz" "clspv-$PLATFORM"
echo "Created: clspv-${PLATFORM}.tar.gz"

echo "Build complete!"
