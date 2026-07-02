#!/bin/bash
set -e

# Build script for libfido2 + dependencies (libcbor, hidapi on Linux).
# Outputs a relocatable package with static libraries and headers.
#
# Yubico's official FIDO2/CTAP2 library — powers YubiKey, Titan,
# SoloKey, and every FIDO2-compatible security key.  libmental links
# this to implement the FIDO2Authenticator surface.
#
# Windows: uses Yubico's official prebuilt zip (they ship one per
#          release for x86, x64, arm64).
# macOS:   builds libfido2 + libcbor from source with CMake.  Uses
#          the LibreSSL that ships with macOS + IOKit-native HID
#          transport (no hidapi needed).
# Linux:   builds libfido2 + libcbor + hidapi from source with CMake.
#          Links against system OpenSSL (available on every distro
#          via libssl-dev / openssl-devel).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# Version pinning — bump these for updates.  These are the current
# stable tags as of writing; the check-versions workflow will flag
# newer releases.
: "${LIBFIDO2_VERSION:=1.15.0}"
: "${LIBCBOR_VERSION:=0.11.0}"
: "${HIDAPI_VERSION:=hidapi-0.14.0}"

# Detect platform
if [[ "$OSTYPE" == "darwin"* ]]; then
    ARCH=$(uname -m)
    if [ -n "$MACOS_ARCH" ]; then ARCH="$MACOS_ARCH"; fi
    PLATFORM="darwin-$ARCH"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux-$(uname -m)"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    if [ -n "$CROSS_COMPILE_TARGET" ]; then
        ARCH="$CROSS_COMPILE_TARGET"
    else
        ARCH=$(uname -m)
    fi
    PLATFORM="windows-$ARCH"
fi
PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')

echo "Building libfido2 for $PLATFORM..."

# Number of CPU cores
if [[ "$OSTYPE" == "darwin"* ]]; then NCPU=$(sysctl -n hw.ncpu)
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then NCPU=$(nproc)
else NCPU=4; fi

mkdir -p "$BUILD_DIR"
mkdir -p "$OUTPUT_DIR"
cd "$BUILD_DIR"

# Package layout matches sibling build scripts: OUTPUT_DIR/<tool>-<platform>/
# is the flat staging dir the CI job tars as <tool>-<platform>.tar.gz.
OUT="$OUTPUT_DIR/libfido2-$PLATFORM"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include" "$OUT/LICENSES"

# --- Windows: use Yubico's prebuilt --------------------------------------
if [[ "$PLATFORM" == windows-* ]]; then
    case "$PLATFORM" in
        windows-amd64) YBOX_ARCH="win64" ;;
        windows-arm64) YBOX_ARCH="win-arm64" ;;
        *) echo "Unknown Windows arch: $PLATFORM"; exit 1 ;;
    esac

    ZIP_URL="https://developers.yubico.com/libfido2/Releases/libfido2-${LIBFIDO2_VERSION}-${YBOX_ARCH}.zip"
    ZIP_FILE="libfido2-${LIBFIDO2_VERSION}-${YBOX_ARCH}.zip"

    if [ ! -f "$ZIP_FILE" ]; then
        echo "Downloading $ZIP_URL"
        curl -fsSL -o "$ZIP_FILE" "$ZIP_URL"
    fi

    UNZIP_DIR="libfido2-${LIBFIDO2_VERSION}-${YBOX_ARCH}"
    rm -rf "$UNZIP_DIR"
    unzip -q "$ZIP_FILE" -d "$UNZIP_DIR"

    # Yubico's zip lays out {bin,include,lib} directly.
    cp "$UNZIP_DIR"/*.lib "$OUT/lib/" 2>/dev/null || true
    cp "$UNZIP_DIR"/*/*.lib "$OUT/lib/" 2>/dev/null || true
    cp -r "$UNZIP_DIR"/include/* "$OUT/include/" 2>/dev/null || true
    cp -r "$UNZIP_DIR"/*/include/* "$OUT/include/" 2>/dev/null || true

    # Attribution: fetch the upstream LICENSE at the pinned tag so the
    # Yubico prebuilt is packaged with the same license text as the
    # source builds on macOS/Linux.
    curl -fsSL -o "$OUT/LICENSES/libfido2-LICENSE" \
        "https://raw.githubusercontent.com/Yubico/libfido2/${LIBFIDO2_VERSION}/LICENSE" || true
    curl -fsSL -o "$OUT/LICENSES/libcbor-LICENSE" \
        "https://raw.githubusercontent.com/PJK/libcbor/v${LIBCBOR_VERSION}/LICENSE.md" || true

    cd "$OUTPUT_DIR"
    tar -czf "libfido2-${PLATFORM}.tar.gz" "libfido2-$PLATFORM"
    echo "Created: libfido2-${PLATFORM}.tar.gz"

    echo "Windows package extracted to $OUT"
    exit 0
fi

# --- macOS / Linux: build from source ------------------------------------

# 1. libcbor — dependency of libfido2
if [ ! -d "libcbor-${LIBCBOR_VERSION}" ]; then
    echo "Fetching libcbor v${LIBCBOR_VERSION}..."
    curl -fsSL "https://github.com/PJK/libcbor/archive/refs/tags/v${LIBCBOR_VERSION}.tar.gz" \
        | tar -xz
fi
mkdir -p "libcbor-build-$PLATFORM"
cd "libcbor-build-$PLATFORM"
cmake ../"libcbor-${LIBCBOR_VERSION}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/libcbor-install-$PLATFORM"
cmake --build . -j "$NCPU"
cmake --install .
cd "$BUILD_DIR"

# 2. hidapi (Linux only; macOS uses IOKit natively, Windows uses hid.dll)
#
# hidapi has two Linux backends: hidraw (kernel /dev/hidraw* via ioctl,
# links libudev for enumeration) and libusb (libusb-1.0.so runtime dep).
# We deliberately build ONLY the hidraw backend — it has a much smaller
# runtime footprint (libudev.so.1 is universal on any systemd distro,
# including Raspberry Pi OS on Pi 5, which is the minimum viable compute
# target for Glitter unikernel deployments).  libusb-1.0 is often absent
# from embedded/minimal images.
if [[ "$PLATFORM" == linux-* ]]; then
    if [ ! -d "hidapi-${HIDAPI_VERSION#hidapi-}" ]; then
        echo "Fetching hidapi ${HIDAPI_VERSION}..."
        curl -fsSL "https://github.com/libusb/hidapi/archive/refs/tags/${HIDAPI_VERSION}.tar.gz" \
            | tar -xz
    fi
    mkdir -p "hidapi-build-$PLATFORM"
    cd "hidapi-build-$PLATFORM"
    cmake ../"hidapi-${HIDAPI_VERSION#hidapi-}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DHIDAPI_WITH_HIDRAW=ON \
        -DHIDAPI_WITH_LIBUSB=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/hidapi-install-$PLATFORM"
    cmake --build . -j "$NCPU"
    cmake --install .
    cd "$BUILD_DIR"
fi

# 3. libfido2 — the main event
if [ ! -d "libfido2-${LIBFIDO2_VERSION}" ]; then
    echo "Fetching libfido2 v${LIBFIDO2_VERSION}..."
    curl -fsSL "https://github.com/Yubico/libfido2/archive/refs/tags/${LIBFIDO2_VERSION}.tar.gz" \
        | tar -xz
fi
mkdir -p "libfido2-build-$PLATFORM"
cd "libfido2-build-$PLATFORM"

CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_TOOLS=OFF
    -DBUILD_MANPAGES=OFF
    -DBUILD_EXAMPLES=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    "-DCBOR_INCLUDE_DIRS=$BUILD_DIR/libcbor-install-$PLATFORM/include"
    "-DCBOR_LIBRARY_DIRS=$BUILD_DIR/libcbor-install-$PLATFORM/lib"
)

if [[ "$PLATFORM" == linux-* ]]; then
    CMAKE_ARGS+=(
        "-DHIDAPI_INCLUDE_DIRS=$BUILD_DIR/hidapi-install-$PLATFORM/include/hidapi"
        "-DHIDAPI_LIBRARY_DIRS=$BUILD_DIR/hidapi-install-$PLATFORM/lib"
    )
fi

export PKG_CONFIG_PATH="$BUILD_DIR/libcbor-install-$PLATFORM/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
cmake ../"libfido2-${LIBFIDO2_VERSION}" "${CMAKE_ARGS[@]}"
cmake --build . -j "$NCPU"

# libfido2's CMake doesn't offer a great install target for our layout;
# copy artifacts manually.
cp src/libfido2.a "$OUT/lib/"
cp "$BUILD_DIR/libcbor-install-$PLATFORM/lib/libcbor.a" "$OUT/lib/"
if [[ "$PLATFORM" == linux-* ]]; then
    # hidraw-only build — see the hidapi build step above for rationale.
    cp "$BUILD_DIR/hidapi-install-$PLATFORM/lib/libhidapi-hidraw.a" "$OUT/lib/"
    # Ship hidapi's public header too — libmental's hid_linux.c compiles
    # against it.  hidapi installs to include/hidapi/hidapi.h under the
    # install prefix.
    mkdir -p "$OUT/include/hidapi"
    cp "$BUILD_DIR/hidapi-install-$PLATFORM/include/hidapi/hidapi.h" \
       "$OUT/include/hidapi/"
fi

# Headers
cp -r "$BUILD_DIR/libfido2-${LIBFIDO2_VERSION}/src/fido.h" "$OUT/include/"
cp -r "$BUILD_DIR/libfido2-${LIBFIDO2_VERSION}/src/fido" "$OUT/include/"

# --- Bundle OpenSSL (libcrypto + headers) so the tarball is self-contained.
#
# fido.h publicly includes <openssl/ec.h>, so any TU that touches it
# needs openssl headers on its include path.  Shipping libcrypto.a + the
# matching openssl/*.h alongside libfido2 lets libmental compile and link
# without a system OpenSSL dev package or Homebrew shortcut on the
# consumer side — this is what "buttoned up" means for this dependency.
#
# macOS: Homebrew openssl@3 provides libcrypto.a + headers under a
#        predictable prefix.  CI runners come with brew pre-installed
#        and the redistributables workflow apt/brew-installs openssl@3
#        before invoking this script.
# Linux: libssl-dev ships libcrypto.a + headers under system paths.
#        Debian/Ubuntu multiarch puts it under /usr/lib/<triplet>/.
mkdir -p "$OUT/include/openssl"
if [[ "$PLATFORM" == darwin-* ]]; then
    OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || echo /opt/homebrew/opt/openssl@3)"
    if [ -f "$OPENSSL_PREFIX/lib/libcrypto.a" ]; then
        cp "$OPENSSL_PREFIX/lib/libcrypto.a" "$OUT/lib/"
    else
        echo "ERROR: could not find libcrypto.a under $OPENSSL_PREFIX/lib"
        echo "       brew install openssl@3"
        exit 1
    fi
    cp -R "$OPENSSL_PREFIX/include/openssl/." "$OUT/include/openssl/"
    if [ -f "$OPENSSL_PREFIX/LICENSE.txt" ]; then
        cp "$OPENSSL_PREFIX/LICENSE.txt" "$OUT/LICENSES/openssl-LICENSE"
    elif [ -f "$OPENSSL_PREFIX/LICENSE" ]; then
        cp "$OPENSSL_PREFIX/LICENSE" "$OUT/LICENSES/openssl-LICENSE"
    fi
elif [[ "$PLATFORM" == linux-* ]]; then
    # Prefer pkg-config to find the multiarch libdir; fall back to a search.
    CRYPTO_A="$(pkg-config --variable=libdir libcrypto 2>/dev/null)/libcrypto.a"
    if [ ! -f "$CRYPTO_A" ]; then
        CRYPTO_A="$(find /usr/lib /usr/local/lib -name libcrypto.a 2>/dev/null | head -1)"
    fi
    if [ -z "$CRYPTO_A" ] || [ ! -f "$CRYPTO_A" ]; then
        echo "ERROR: could not find libcrypto.a; install libssl-dev"
        exit 1
    fi
    cp "$CRYPTO_A" "$OUT/lib/"
    # Headers ship under /usr/include/openssl in the -dev package.
    if [ -d /usr/include/openssl ]; then
        cp -R /usr/include/openssl/. "$OUT/include/openssl/"
    fi
    # Debian/Ubuntu ships the OpenSSL LICENSE at /usr/share/doc/libssl-dev/copyright.
    if [ -f /usr/share/doc/libssl-dev/copyright ]; then
        cp /usr/share/doc/libssl-dev/copyright "$OUT/LICENSES/openssl-LICENSE"
    fi
fi

# License files
cp "$BUILD_DIR/libfido2-${LIBFIDO2_VERSION}/LICENSE" "$OUT/LICENSES/libfido2-LICENSE" 2>/dev/null || true
cp "$BUILD_DIR/libcbor-${LIBCBOR_VERSION}/LICENSE.md" "$OUT/LICENSES/libcbor-LICENSE" 2>/dev/null || true
if [[ "$PLATFORM" == linux-* ]]; then
    cp "$BUILD_DIR/hidapi-${HIDAPI_VERSION#hidapi-}/LICENSE.txt" "$OUT/LICENSES/hidapi-LICENSE" 2>/dev/null || true
fi

# Roll the flat staging dir into the tarball CI uploads as the release
# asset (matches sibling scripts: <tool>-<platform>.tar.gz at OUTPUT_DIR).
cd "$OUTPUT_DIR"
tar -czf "libfido2-${PLATFORM}.tar.gz" "libfido2-$PLATFORM"
echo "Created: libfido2-${PLATFORM}.tar.gz"

echo "libfido2 package built at $OUT"
ls -la "$OUT/lib" "$OUT/include" 2>&1 || true
