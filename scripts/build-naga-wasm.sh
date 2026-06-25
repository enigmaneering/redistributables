#!/bin/bash
set -e

# Build script for Naga — WebAssembly target
# Builds naga-cli for wasm32-wasip1, producing a .wasm module that can be
# invoked via any WASI runtime (wasmtime, wasmer, Node.js with WASI support).
#
# Requires: Rust/Cargo (rustup)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"
PLATFORM="wasm"

# Query GitHub for latest wgpu release if not specified
if [ -z "$NAGA_VERSION" ]; then
    echo "Querying GitHub for latest wgpu release..."
    NAGA_VERSION=$(curl -s https://api.github.com/repos/gfx-rs/wgpu/releases/latest \
        | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
    if [ -z "$NAGA_VERSION" ]; then
        echo "Warning: Could not determine latest wgpu version, using v28.0.0"
        NAGA_VERSION="v28.0.0"
    else
        echo "Latest wgpu release: $NAGA_VERSION"
    fi
fi

echo "Building Naga $NAGA_VERSION for WebAssembly..."

# Check if Rust is installed
if ! command -v cargo &> /dev/null; then
    echo "Error: Rust/Cargo not found. Please install Rust from https://rustup.rs/"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone wgpu (contains Naga)
if [ ! -d "wgpu-wasm" ]; then
    echo "Cloning wgpu (contains Naga)..."
    git clone --depth 1 --branch "$NAGA_VERSION" https://github.com/gfx-rs/wgpu.git wgpu-wasm
fi

cd wgpu-wasm

# Verify licenses exist before building (fail fast)
echo "Verifying license files..."
if [ ! -f "LICENSE.APACHE" ] || [ ! -f "LICENSE.MIT" ]; then
    echo "Error: LICENSE files not found in wgpu repository"
    exit 1
fi
echo "License files verified"

# Add WASI target
echo "Adding wasm32-wasip1 target..."
rustup target add wasm32-wasip1

# Build Naga CLI for WASI (standalone tool)
echo "Building Naga CLI for WebAssembly..."
cargo build --release --package naga-cli --target wasm32-wasip1

# Build Naga FFI static library for Emscripten (linkable into C/C++ projects)
echo "Building Naga FFI static library for Emscripten..."
NAGA_FFI_DIR="$SCRIPT_DIR/../naga-ffi"
if [ ! -d "$NAGA_FFI_DIR" ]; then
    echo "Error: naga-ffi crate not found at $NAGA_FFI_DIR"
    exit 1
fi

# The naga-ffi crate needs to resolve the naga dependency from the wgpu checkout,
# and Cargo needs to know how to use Emscripten as the compiler/linker for this target.
mkdir -p "$NAGA_FFI_DIR/.cargo"
cat > "$NAGA_FFI_DIR/.cargo/config.toml" << CARGO_EOF
[patch.'https://github.com/gfx-rs/wgpu.git']
naga = { path = "$BUILD_DIR/wgpu-wasm/naga" }

[target.wasm32-unknown-emscripten]
linker = "emcc"
ar = "emar"
CARGO_EOF

cd "$NAGA_FFI_DIR"
# Must add the target from HERE (not the wgpu dir) so it installs for the
# toolchain that Cargo will actually use — wgpu pins to a specific Rust
# version via rust-toolchain.toml, but naga-ffi uses stable.
rustup target add wasm32-unknown-emscripten
# Emscripten's emcc must be used as the C compiler for build scripts and native deps.
# We force --crate-type=staticlib here: naga-ffi's Cargo.toml declares both
# staticlib and cdylib (so native builds produce both forms), but a cdylib
# for wasm32-unknown-emscripten requires extra linker plumbing we don't need —
# downstream libmental statically links libnaga_ffi.a on WASM.
CC_wasm32_unknown_emscripten=emcc \
CXX_wasm32_unknown_emscripten=em++ \
cargo rustc --release --target wasm32-unknown-emscripten --crate-type=staticlib
cd "$BUILD_DIR/wgpu-wasm"

# Package output
PACKAGE_DIR="$OUTPUT_DIR/naga-$PLATFORM"
mkdir -p "$PACKAGE_DIR/bin"
mkdir -p "$PACKAGE_DIR/lib"
mkdir -p "$PACKAGE_DIR/include"

# Copy the WASI CLI binary
echo "Packaging WASM binary..."
cp "target/wasm32-wasip1/release/naga.wasm" "$PACKAGE_DIR/bin/"

# Copy the Emscripten static library
echo "Packaging FFI static library..."
FFI_LIB=$(find "$NAGA_FFI_DIR/target/wasm32-unknown-emscripten/release" -name "libnaga_ffi.a" | head -1)
if [ -n "$FFI_LIB" ]; then
    cp "$FFI_LIB" "$PACKAGE_DIR/lib/libnaga_ffi.a"
    echo "Library size: $(du -h "$PACKAGE_DIR/lib/libnaga_ffi.a" | cut -f1)"
else
    echo "Warning: libnaga_ffi.a not found — FFI library not packaged"
fi

# Copy C header
cp "$NAGA_FFI_DIR/naga_ffi.h" "$PACKAGE_DIR/include/"

# Verify we got the CLI output
if [ ! -f "$PACKAGE_DIR/bin/naga.wasm" ]; then
    echo "Error: naga.wasm not found in build output"
    ls -la target/wasm32-wasip1/release/ 2>/dev/null || true
    exit 1
fi

echo "CLI binary size: $(du -h "$PACKAGE_DIR/bin/naga.wasm" | cut -f1)"

# Clean up cargo config override
rm -f "$NAGA_FFI_DIR/.cargo/config.toml"
rmdir "$NAGA_FFI_DIR/.cargo" 2>/dev/null || true

# Copy licenses (wgpu/naga is dual-licensed)
echo "Packaging licenses..."
mkdir -p "$PACKAGE_DIR/licenses/naga"
cp "LICENSE.APACHE" "$PACKAGE_DIR/licenses/naga/LICENSE.APACHE"
cp "LICENSE.MIT" "$PACKAGE_DIR/licenses/naga/LICENSE.MIT"

# Copy LICENSES directory if it exists
if [ -d "LICENSES" ]; then
    cp -r "LICENSES" "$PACKAGE_DIR/licenses/naga/"
fi

# Create archive
cd "$OUTPUT_DIR"
tar -czf "naga-${PLATFORM}.tar.gz" "naga-$PLATFORM"
echo "Created: naga-${PLATFORM}.tar.gz"

echo "Build complete!"
