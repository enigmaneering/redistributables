#!/bin/bash
set -e

# Build wgpu-native from source — for the platforms gfx-rs publishes no
# prebuilt binary for. The release job downloads the upstream zip for the
# six platforms it covers (download-wgpu-native.sh, and the inline step in
# build-release.yml); linux-riscv64 is built here instead, from the same
# tag, with Rust's riscv64gc-unknown-linux-gnu target and Ubuntu's cross
# toolchain as the linker. The package has the layout of the downloaded one:
#     wgpu-<platform>/include/webgpu/{webgpu.h,wgpu.h}
#     wgpu-<platform>/lib/{libwgpu_native.a,libwgpu_native.so}
#     wgpu-<platform>/{LICENSE.MIT,LICENSE.APACHE}
#
# Inputs: WGPU_VERSION (the wgpu-native tag; the latest release if unset),
# CMAKE_ARCH (riscv64 for the cross build; the host otherwise), BUILD_DIR,
# OUTPUT_DIR. Needs cargo, git, and libclang for wgpu-native's bindgen.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

if [ -z "$WGPU_VERSION" ]; then
    echo "Querying GitHub for latest wgpu-native release..."
    WGPU_VERSION=$(curl -s https://api.github.com/repos/gfx-rs/wgpu-native/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
    [ -n "$WGPU_VERSION" ] || { echo "Error: could not determine the latest wgpu-native release"; exit 1; }
    echo "Latest wgpu-native release: $WGPU_VERSION"
fi

if [[ "$OSTYPE" != "linux-gnu"* ]]; then
    echo "Error: build-wgpu-native.sh builds on Linux only (the other platforms download upstream's binaries)"; exit 1
fi
PLATFORM="linux-${CMAKE_ARCH:-$(uname -m)}"
PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')
echo "Building wgpu-native $WGPU_VERSION for $PLATFORM..."

command -v cargo >/dev/null 2>&1 || { echo "Error: Rust/Cargo not found. Please install Rust from https://rustup.rs/"; exit 1; }

CARGO_TARGET=""
CARGO_TARGET_FLAG=""
if [ "${CMAKE_ARCH:-}" = "riscv64" ]; then
    CARGO_TARGET="riscv64gc-unknown-linux-gnu"
    rustup target add "$CARGO_TARGET"
    CARGO_TARGET_FLAG="--target $CARGO_TARGET"
    export CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER=riscv64-linux-gnu-gcc
    export CC_riscv64gc_unknown_linux_gnu=riscv64-linux-gnu-gcc
    export CXX_riscv64gc_unknown_linux_gnu=riscv64-linux-gnu-g++
    export AR_riscv64gc_unknown_linux_gnu=riscv64-linux-gnu-ar
    # wgpu-native's build script runs bindgen over ffi/webgpu-headers for the
    # TARGET; libclang must see the cross libc's headers for that triple.
    export BINDGEN_EXTRA_CLANG_ARGS="${BINDGEN_EXTRA_CLANG_ARGS:-} --sysroot=/usr/riscv64-linux-gnu -I/usr/riscv64-linux-gnu/include"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
if [ ! -d "wgpu-native" ]; then
    echo "Cloning wgpu-native $WGPU_VERSION (with ffi/webgpu-headers)..."
    git clone --depth 1 --recursive --branch "$WGPU_VERSION" https://github.com/gfx-rs/wgpu-native.git
fi
cd wgpu-native
for f in LICENSE.MIT LICENSE.APACHE ffi/webgpu-headers/webgpu.h ffi/wgpu.h; do
    [ -f "$f" ] || { echo "Error: $f not found in wgpu-native $WGPU_VERSION"; exit 1; }
done

cargo build --release $CARGO_TARGET_FLAG

if [ -n "$CARGO_TARGET" ]; then BIN_DIR="target/$CARGO_TARGET/release"; else BIN_DIR="target/release"; fi

PACKAGE_DIR="$OUTPUT_DIR/wgpu-$PLATFORM"
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/include/webgpu" "$PACKAGE_DIR/lib"
cp ffi/webgpu-headers/webgpu.h ffi/wgpu.h "$PACKAGE_DIR/include/webgpu/"
for lib in libwgpu_native.a libwgpu_native.so; do
    [ -f "$BIN_DIR/$lib" ] || { echo "Error: $BIN_DIR/$lib was not built"; ls -la "$BIN_DIR" >&2; exit 1; }
    cp "$BIN_DIR/$lib" "$PACKAGE_DIR/lib/"
done
cp LICENSE.MIT LICENSE.APACHE "$PACKAGE_DIR/"

cd "$OUTPUT_DIR"
tar -czf "wgpu-${PLATFORM}.tar.gz" "wgpu-$PLATFORM"
echo "Created: wgpu-${PLATFORM}.tar.gz"
echo "Build complete!"
