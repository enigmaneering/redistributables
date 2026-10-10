#!/bin/bash
set -e

# Download script for wgpu-native (WebGPU implementation)
# Downloads prebuilt binaries from the gfx-rs/wgpu-native GitHub releases
# Outputs a relocatable package with headers, libraries, and licenses

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# Query GitHub for latest wgpu-native release if not specified
if [ -z "$WGPU_VERSION" ]; then
    echo "Querying GitHub for latest wgpu-native release..."
    WGPU_VERSION=$(curl -s ${GH_TOKEN:+-H "Authorization: token $GH_TOKEN"} https://api.github.com/repos/gfx-rs/wgpu-native/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
    if [ -z "$WGPU_VERSION" ]; then
        echo "Warning: Could not determine latest wgpu-native version, using v27.0.4.0"
        WGPU_VERSION="v27.0.4.0"
    else
        echo "Latest wgpu-native release: $WGPU_VERSION"
    fi
fi

# Detect platform
if [[ "$OSTYPE" == "darwin"* ]]; then
    ARCH=$(uname -m)
    if [ -n "$MACOS_ARCH" ]; then
        ARCH="$MACOS_ARCH"
    fi
    PLATFORM="darwin-$ARCH"
    # wgpu-native uses different naming: macos-aarch64 / macos-x86_64
    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
        WGPU_ARCH="aarch64"
    else
        WGPU_ARCH="x86_64"
    fi
    WGPU_PLATFORM="macos-${WGPU_ARCH}"
    ARCHIVE_EXT="zip"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    ARCH=$(uname -m)
    PLATFORM="linux-$ARCH"
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        WGPU_ARCH="aarch64"
    else
        WGPU_ARCH="x86_64"
    fi
    WGPU_PLATFORM="linux-${WGPU_ARCH}"
    ARCHIVE_EXT="zip"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    if [ -n "$CROSS_COMPILE_TARGET" ]; then
        ARCH="$CROSS_COMPILE_TARGET"
    else
        ARCH=$(uname -m)
    fi
    PLATFORM="windows-$ARCH"
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        WGPU_ARCH="aarch64"
    else
        WGPU_ARCH="x86_64"
    fi
    WGPU_PLATFORM="windows-${WGPU_ARCH}-msvc"
    ARCHIVE_EXT="zip"
fi

# Normalize platform names for our output
PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')

echo "Downloading wgpu-native for $PLATFORM (upstream: $WGPU_PLATFORM)..."

# Download licenses first (fail fast)
echo "Downloading licenses..."
mkdir -p /tmp/wgpu-licenses

# wgpu-native is dual-licensed (MIT + Apache 2.0) — same as wgpu
curl -sL -o /tmp/wgpu-licenses/LICENSE.MIT \
    "https://raw.githubusercontent.com/gfx-rs/wgpu-native/trunk/LICENSE.MIT" || \
curl -sL -o /tmp/wgpu-licenses/LICENSE.MIT \
    "https://raw.githubusercontent.com/gfx-rs/wgpu/trunk/LICENSE.MIT"

curl -sL -o /tmp/wgpu-licenses/LICENSE.APACHE \
    "https://raw.githubusercontent.com/gfx-rs/wgpu-native/trunk/LICENSE.APACHE" || \
curl -sL -o /tmp/wgpu-licenses/LICENSE.APACHE \
    "https://raw.githubusercontent.com/gfx-rs/wgpu/trunk/LICENSE.APACHE"

# Verify licenses exist
if [ ! -s /tmp/wgpu-licenses/LICENSE.MIT ] || [ ! -s /tmp/wgpu-licenses/LICENSE.APACHE ]; then
    echo "Error: Failed to download wgpu-native license files"
    exit 1
fi
echo "Licenses verified"

# Download the prebuilt archive
DOWNLOAD_URL="https://github.com/gfx-rs/wgpu-native/releases/download/${WGPU_VERSION}/wgpu-${WGPU_PLATFORM}-release.${ARCHIVE_EXT}"
echo "Downloading: $DOWNLOAD_URL"

mkdir -p /tmp/wgpu-download
curl -sL -o "/tmp/wgpu-download/wgpu.${ARCHIVE_EXT}" "$DOWNLOAD_URL"

if [ ! -s "/tmp/wgpu-download/wgpu.${ARCHIVE_EXT}" ]; then
    echo "Error: Failed to download wgpu-native archive"
    exit 1
fi

# Extract
echo "Extracting..."
cd /tmp/wgpu-download
if [ "$ARCHIVE_EXT" = "zip" ]; then
    unzip -q "wgpu.${ARCHIVE_EXT}"
else
    tar -xzf "wgpu.${ARCHIVE_EXT}"
fi

# Package output
PACKAGE_DIR="$OUTPUT_DIR/wgpu-$PLATFORM"
mkdir -p "$PACKAGE_DIR/include/webgpu"
mkdir -p "$PACKAGE_DIR/lib"

# Copy headers
echo "Packaging headers..."
cp include/webgpu/webgpu.h "$PACKAGE_DIR/include/webgpu/"
cp include/webgpu/wgpu.h "$PACKAGE_DIR/include/webgpu/"

# Copy libraries
echo "Packaging libraries..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    cp lib/libwgpu_native.a "$PACKAGE_DIR/lib/" 2>/dev/null || true
    cp lib/libwgpu_native.dylib "$PACKAGE_DIR/lib/" 2>/dev/null || true
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    cp lib/libwgpu_native.a "$PACKAGE_DIR/lib/" 2>/dev/null || true
    cp lib/libwgpu_native.so "$PACKAGE_DIR/lib/" 2>/dev/null || true
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    cp lib/wgpu_native.lib "$PACKAGE_DIR/lib/" 2>/dev/null || true
    cp lib/wgpu_native.dll "$PACKAGE_DIR/lib/" 2>/dev/null || true
    cp lib/wgpu_native.dll.lib "$PACKAGE_DIR/lib/" 2>/dev/null || true
fi

# Copy licenses
echo "Packaging licenses..."
cp /tmp/wgpu-licenses/LICENSE.MIT "$PACKAGE_DIR/LICENSE.MIT"
cp /tmp/wgpu-licenses/LICENSE.APACHE "$PACKAGE_DIR/LICENSE.APACHE"

# Create archive
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"
tar -czf "wgpu-${PLATFORM}.tar.gz" "wgpu-$PLATFORM"
echo "Created: wgpu-${PLATFORM}.tar.gz"

# Cleanup
rm -rf /tmp/wgpu-download /tmp/wgpu-licenses

echo "Download complete!"
