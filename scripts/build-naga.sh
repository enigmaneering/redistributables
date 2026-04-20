#!/bin/bash
set -e

# Build script for Naga
# Outputs a relocatable package with the Naga CLI binary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# Query GitHub for latest wgpu release if not specified
# Naga is now part of the wgpu project
if [ -z "$NAGA_VERSION" ]; then
    echo "Querying GitHub for latest wgpu release..."
    NAGA_VERSION=$(curl -s https://api.github.com/repos/gfx-rs/wgpu/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
    if [ -z "$NAGA_VERSION" ]; then
        echo "Warning: Could not determine latest wgpu version, using v28.0.0"
        NAGA_VERSION="v28.0.0"
    else
        echo "Latest wgpu release: $NAGA_VERSION"
    fi
fi

# Detect platform
if [[ "$OSTYPE" == "darwin"* ]]; then
    ARCH=$(uname -m)
    # Override with MACOS_ARCH if provided (for cross-compilation)
    if [ -n "$MACOS_ARCH" ]; then
        ARCH="$MACOS_ARCH"
    fi
    PLATFORM="darwin-$ARCH"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux-$(uname -m)"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    # Use CROSS_COMPILE_TARGET if set, otherwise detect from uname
    if [ -n "$CROSS_COMPILE_TARGET" ]; then
        ARCH="$CROSS_COMPILE_TARGET"
    else
        ARCH=$(uname -m)
    fi
    PLATFORM="windows-$ARCH"
fi

# Normalize architecture names
PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')

echo "Building Naga for $PLATFORM..."

# Check if Rust is installed
if ! command -v cargo &> /dev/null; then
    echo "Error: Rust/Cargo not found. Please install Rust from https://rustup.rs/"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone wgpu (contains Naga)
if [ ! -d "wgpu" ]; then
    echo "Cloning wgpu (contains Naga)..."
    git clone --depth 1 --branch "$NAGA_VERSION" https://github.com/gfx-rs/wgpu.git
fi

cd wgpu

# Verify licenses exist before building (fail fast)
echo "Verifying license files..."
if [ ! -f "LICENSE.APACHE" ] || [ ! -f "LICENSE.MIT" ]; then
    echo "Error: LICENSE files not found in wgpu repository"
    exit 1
fi
echo "License files verified"

# Build Naga CLI
echo "Building Naga CLI..."

# Set up cross-compilation target if needed
CARGO_TARGET=""
CARGO_TARGET_FLAG=""

if [[ "$OSTYPE" == "darwin"* ]] && [ -n "$MACOS_ARCH" ]; then
    # macOS cross-compilation
    if [ "$MACOS_ARCH" = "x86_64" ]; then
        CARGO_TARGET="x86_64-apple-darwin"
    elif [ "$MACOS_ARCH" = "arm64" ]; then
        CARGO_TARGET="aarch64-apple-darwin"
    fi

    if [ -n "$CARGO_TARGET" ]; then
        echo "Cross-compiling for $CARGO_TARGET"
        rustup target add "$CARGO_TARGET"
        CARGO_TARGET_FLAG="--target $CARGO_TARGET"
    fi
elif [[ "$OSTYPE" == "linux-gnu"* ]] && [ -n "$CMAKE_ARCH" ] && [ "$CMAKE_ARCH" = "aarch64" ]; then
    # Linux ARM64 cross-compilation
    CARGO_TARGET="aarch64-unknown-linux-gnu"
    echo "Cross-compiling for $CARGO_TARGET"
    rustup target add "$CARGO_TARGET"
    CARGO_TARGET_FLAG="--target $CARGO_TARGET"

    # Set up cross-compilation environment
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    # Windows
    if [ -n "$CROSS_COMPILE_TARGET" ] && [ "$CROSS_COMPILE_TARGET" = "aarch64" ]; then
        CARGO_TARGET="aarch64-pc-windows-msvc"
        echo "Cross-compiling for $CARGO_TARGET"
        rustup target add "$CARGO_TARGET"
        CARGO_TARGET_FLAG="--target $CARGO_TARGET"
    fi
fi

# Build the CLI tool (naga-cli package produces naga binary)
cargo build --release --package naga-cli $CARGO_TARGET_FLAG

# Build the FFI shared library (naga-ffi crate as cdylib → libnaga_ffi.so/.dylib)
# Cargo.toml has crate-type=["staticlib"] for WASM compatibility;
# we use cargo rustc --crate-type=cdylib to produce the shared library for native.
echo "Building Naga FFI shared library..."
FFI_DIR="$SCRIPT_DIR/../naga-ffi"
cargo rustc --release --manifest-path "$FFI_DIR/Cargo.toml" --crate-type=cdylib $CARGO_TARGET_FLAG

# Determine binary locations.  The naga-cli build runs out of wgpu/ so its
# target dir is wgpu/target/.  The FFI crate is OUTSIDE wgpu's workspace,
# so Cargo places its target at $FFI_DIR/target/ — keep them separate.
if [ -n "$CARGO_TARGET" ]; then
    CLI_BIN_DIR="target/$CARGO_TARGET/release"
    FFI_BIN_DIR="$FFI_DIR/target/$CARGO_TARGET/release"
else
    CLI_BIN_DIR="target/release"
    FFI_BIN_DIR="$FFI_DIR/target/release"
fi

# Package output
PACKAGE_DIR="$OUTPUT_DIR/naga-$PLATFORM"
mkdir -p "$PACKAGE_DIR/bin"
mkdir -p "$PACKAGE_DIR/lib"
mkdir -p "$PACKAGE_DIR/include"

# Copy CLI binary
echo "Packaging binary..."
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    cp "$CLI_BIN_DIR/naga.exe" "$PACKAGE_DIR/bin/"
else
    cp "$CLI_BIN_DIR/naga" "$PACKAGE_DIR/bin/"
fi

# Copy FFI shared library.  A prior version silently masked failures here
# with `cp ... 2>/dev/null || true`, shipping FFI-less naga packages that
# broke downstream dlopen.  Fail loud instead — the canary below checks
# that libnaga_ffi actually landed in lib/.
echo "Packaging FFI shared library (from $FFI_BIN_DIR)..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    cp "$FFI_BIN_DIR/libnaga_ffi.dylib" "$PACKAGE_DIR/lib/"
    for dylib in "$PACKAGE_DIR/lib/"*.dylib; do
        install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
    done
    FFI_ARTIFACT="libnaga_ffi.dylib"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    cp "$FFI_BIN_DIR/naga_ffi.dll" "$PACKAGE_DIR/lib/"
    FFI_ARTIFACT="naga_ffi.dll"
else
    cp "$FFI_BIN_DIR/libnaga_ffi.so" "$PACKAGE_DIR/lib/"
    FFI_ARTIFACT="libnaga_ffi.so"
fi

# Canary: verify libnaga_ffi actually landed.  Downstream libmental dlopen's
# this by name; an empty lib/ would silently disable WGSL everywhere.
if [ ! -f "$PACKAGE_DIR/lib/$FFI_ARTIFACT" ]; then
    echo "Error: $FFI_ARTIFACT missing from $PACKAGE_DIR/lib/" >&2
    echo "       Expected source: $FFI_BIN_DIR/$FFI_ARTIFACT" >&2
    echo "       $FFI_BIN_DIR contents:" >&2
    ls -la "$FFI_BIN_DIR" >&2 || true
    exit 1
fi

# Copy FFI header
cp "$FFI_DIR/naga_ffi.h" "$PACKAGE_DIR/include/"

# Copy licenses (wgpu/naga is dual-licensed)
echo "Packaging licenses..."
cp "LICENSE.APACHE" "$PACKAGE_DIR/LICENSE.APACHE"
cp "LICENSE.MIT" "$PACKAGE_DIR/LICENSE.MIT"

# Copy LICENSES directory if it exists
if [ -d "LICENSES" ]; then
    cp -r "LICENSES" "$PACKAGE_DIR/"
fi

# Create archive
cd "$OUTPUT_DIR"
tar -czf "naga-${PLATFORM}.tar.gz" "naga-$PLATFORM"
echo "Created: naga-${PLATFORM}.tar.gz"

echo "Build complete!"
