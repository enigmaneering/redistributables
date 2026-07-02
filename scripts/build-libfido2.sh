#!/bin/bash
set -e

# Build script for libfido2 + dependencies (libcbor + hidapi on Linux;
# libcbor + OpenSSL on Windows).  Outputs a relocatable package with
# static libraries and headers.
#
# Yubico's official FIDO2/CTAP2 library — powers YubiKey, Titan,
# SoloKey, and every FIDO2-compatible security key.  libmental links
# this to implement the FIDO2Authenticator surface.
#
# Every platform emits the same tarball layout:
#     <tool>-<platform>/lib/{libfido2.a, libcbor.a, libcrypto.a[, libhidapi-hidraw.a]}
#     <tool>-<platform>/include/{fido.h, fido/, openssl/[, hidapi/]}
#     <tool>-<platform>/LICENSES/{libfido2, libcbor, openssl[, hidapi]}
#
# macOS:   source-build libfido2 + libcbor via CMake.  libcrypto + openssl
#          headers come from Homebrew openssl@3.  HID uses IOKit natively.
# Linux:   source-build libfido2 + libcbor + hidapi (hidraw backend) via
#          CMake.  libcrypto + openssl headers come from libssl-dev.
# Windows: source-build ALL FOUR (openssl + libcbor + libfido2) with the
#          MSYS2 MinGW toolchain (mingw64 target for windows-amd64,
#          mingwarm64 target for windows-arm64 via llvm-mingw cross-compile).
#          Uses libfido2's native Windows hid.dll transport — no hidapi.
#          Yubico's Windows prebuilt zip is deliberately NOT used: it
#          ships MSVC-format .lib import stubs that MinGW's ld can't
#          consume, which would leave libmental unable to link.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# Version pinning — bump these for updates.  These are the current
# stable tags as of writing; the check-versions workflow will flag
# newer releases.
: "${LIBFIDO2_VERSION:=1.15.0}"
: "${LIBCBOR_VERSION:=0.11.0}"
: "${HIDAPI_VERSION:=hidapi-0.14.0}"
: "${OPENSSL_VERSION:=3.6.3}"  # Windows-only; mac/linux use their system openssl

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

# --- Windows: source-build the whole stack with MinGW --------------------
#
# We deliberately DON'T use Yubico's Windows prebuilt zip.  It ships MSVC
# v143 static .lib files that MinGW's ld can't consume (COFF/OMF format
# mismatch + missing thunks), which would prevent libmental from linking
# on Windows.  Building from source with the same MinGW toolchain that
# libmental itself uses produces GNU-format libfido2.a + libcbor.a +
# libcrypto.a archives that link cleanly into the final static libmental.a.
#
# Two toolchain paths:
#   windows-amd64: MSYS2 MINGW64 native (gcc, ar, ranlib on PATH)
#   windows-arm64: llvm-mingw cross-compile (aarch64-w64-mingw32-clang etc.
#                  on PATH — set up by the CI job, mirrors build-glslang.sh)
#
# OpenSSL 3.6.3 has native mingw64 + mingwarm64 Configure targets, so
# both architectures get real static builds — no wrapper hacks.
if [[ "$PLATFORM" == windows-* ]]; then
    case "$PLATFORM" in
        windows-amd64)
            OPENSSL_TARGET="mingw64"
            CROSS_PREFIX=""
            CC_HOST="gcc"
            AR_HOST="ar"
            RANLIB_HOST="ranlib"
            CMAKE_C_COMPILER_ID_FLAGS=""
            ;;
        windows-arm64)
            OPENSSL_TARGET="mingwarm64"
            CROSS_PREFIX="aarch64-w64-mingw32-"
            CC_HOST="${CROSS_PREFIX}clang"
            AR_HOST="${CROSS_PREFIX}ar"
            RANLIB_HOST="${CROSS_PREFIX}ranlib"
            CMAKE_C_COMPILER_ID_FLAGS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=aarch64"
            ;;
        *) echo "Unknown Windows arch: $PLATFORM"; exit 1 ;;
    esac

    # ---- 1. OpenSSL --------------------------------------------------
    OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
    OPENSSL_SRC_DIR="openssl-${OPENSSL_VERSION}"
    if [ ! -d "$OPENSSL_SRC_DIR" ]; then
        echo "Fetching OpenSSL ${OPENSSL_VERSION}..."
        curl -fsSL -o "$OPENSSL_TARBALL" \
            "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
        tar -xzf "$OPENSSL_TARBALL"
    fi

    OPENSSL_PREFIX="$BUILD_DIR/openssl-install-$PLATFORM"
    mkdir -p "openssl-build-$PLATFORM"
    cd "openssl-build-$PLATFORM"

    # OpenSSL's Configure is not a shadow-build-friendly system; run it
    # from inside the source tree and use --prefix to control install.
    # `no-shared no-tests no-apps no-docs` cuts build time drastically
    # while keeping libcrypto complete for libfido2's needs.
    OPENSSL_CONFIGURE=(
        "$OPENSSL_TARGET"
        "no-shared"
        "no-tests"
        "no-apps"
        "no-docs"
        "no-legacy"
        "--prefix=$OPENSSL_PREFIX"
        "--libdir=lib"
    )
    if [ -n "$CROSS_PREFIX" ]; then
        OPENSSL_CONFIGURE+=("--cross-compile-prefix=$CROSS_PREFIX")
    fi
    echo "Configuring OpenSSL: ${OPENSSL_CONFIGURE[*]}"
    perl "$BUILD_DIR/$OPENSSL_SRC_DIR/Configure" "${OPENSSL_CONFIGURE[@]}"
    make -j "$NCPU" build_libs
    make install_dev
    cd "$BUILD_DIR"

    # ---- 2. libcbor --------------------------------------------------
    if [ ! -d "libcbor-${LIBCBOR_VERSION}" ]; then
        echo "Fetching libcbor v${LIBCBOR_VERSION}..."
        curl -fsSL "https://github.com/PJK/libcbor/archive/refs/tags/v${LIBCBOR_VERSION}.tar.gz" \
            | tar -xz
    fi
    mkdir -p "libcbor-build-$PLATFORM"
    cd "libcbor-build-$PLATFORM"
    cmake ../"libcbor-${LIBCBOR_VERSION}" \
        -G "MSYS Makefiles" \
        -DCMAKE_C_COMPILER="$CC_HOST" \
        -DCMAKE_AR="$(command -v $AR_HOST)" \
        -DCMAKE_RANLIB="$(command -v $RANLIB_HOST)" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/libcbor-install-$PLATFORM" \
        $CMAKE_C_COMPILER_ID_FLAGS
    cmake --build . -j "$NCPU"
    cmake --install .
    cd "$BUILD_DIR"

    # ---- 3. libfido2 -------------------------------------------------
    if [ ! -d "libfido2-${LIBFIDO2_VERSION}" ]; then
        echo "Fetching libfido2 v${LIBFIDO2_VERSION}..."
        curl -fsSL "https://github.com/Yubico/libfido2/archive/refs/tags/${LIBFIDO2_VERSION}.tar.gz" \
            | tar -xz
    fi
    mkdir -p "libfido2-build-$PLATFORM"
    cd "libfido2-build-$PLATFORM"

    # libfido2's CMake uses pkg-config to find libcrypto / libcbor.
    # Point it at our per-tree install prefixes.  On Windows libfido2
    # talks to hid.dll natively (see libfido2/src/hid_win.c), so hidapi
    # is neither built nor linked.
    export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$BUILD_DIR/libcbor-install-$PLATFORM/lib/pkgconfig"
    cmake ../"libfido2-${LIBFIDO2_VERSION}" \
        -G "MSYS Makefiles" \
        -DCMAKE_C_COMPILER="$CC_HOST" \
        -DCMAKE_AR="$(command -v $AR_HOST)" \
        -DCMAKE_RANLIB="$(command -v $RANLIB_HOST)" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TOOLS=OFF \
        -DBUILD_MANPAGES=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        "-DCBOR_INCLUDE_DIRS=$BUILD_DIR/libcbor-install-$PLATFORM/include" \
        "-DCBOR_LIBRARY_DIRS=$BUILD_DIR/libcbor-install-$PLATFORM/lib" \
        "-DCRYPTO_INCLUDE_DIRS=$OPENSSL_PREFIX/include" \
        "-DCRYPTO_LIBRARY_DIRS=$OPENSSL_PREFIX/lib" \
        $CMAKE_C_COMPILER_ID_FLAGS
    cmake --build . -j "$NCPU"

    # ---- Package -----------------------------------------------------
    cp src/libfido2.a "$OUT/lib/"
    cp "$BUILD_DIR/libcbor-install-$PLATFORM/lib/libcbor.a" "$OUT/lib/"
    cp "$OPENSSL_PREFIX/lib/libcrypto.a" "$OUT/lib/"

    # Headers
    cp -r "$BUILD_DIR/libfido2-${LIBFIDO2_VERSION}/src/fido.h" "$OUT/include/"
    cp -r "$BUILD_DIR/libfido2-${LIBFIDO2_VERSION}/src/fido"   "$OUT/include/"
    mkdir -p "$OUT/include/openssl"
    cp -R "$OPENSSL_PREFIX/include/openssl/." "$OUT/include/openssl/"

    # Licenses
    cp "$BUILD_DIR/libfido2-${LIBFIDO2_VERSION}/LICENSE"    "$OUT/LICENSES/libfido2-LICENSE"
    cp "$BUILD_DIR/libcbor-${LIBCBOR_VERSION}/LICENSE.md"   "$OUT/LICENSES/libcbor-LICENSE"
    cp "$BUILD_DIR/openssl-${OPENSSL_VERSION}/LICENSE.txt"  "$OUT/LICENSES/openssl-LICENSE"

    cd "$OUTPUT_DIR"
    tar -czf "libfido2-${PLATFORM}.tar.gz" "libfido2-$PLATFORM"
    echo "Created: libfido2-${PLATFORM}.tar.gz"

    echo "Windows source-build package built at $OUT"
    ls -la "$OUT/lib" "$OUT/include" 2>&1 || true
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
    # GitHub archives use the pattern <repo>-<tag>, so the tag
    # `hidapi-0.14.0` produces a top-level dir named `hidapi-hidapi-0.14.0`.
    # Everything downstream (existence check, cmake source path, licence
    # copy) MUST use HIDAPI_SRC_DIR — do not compose paths from
    # ${HIDAPI_VERSION#hidapi-}; that strips the necessary prefix and
    # produces a wrong path that CMake will reject with "source directory
    # does not exist".
    HIDAPI_SRC_DIR="hidapi-${HIDAPI_VERSION}"
    if [ ! -d "$HIDAPI_SRC_DIR" ]; then
        echo "Fetching hidapi ${HIDAPI_VERSION}..."
        curl -fsSL "https://github.com/libusb/hidapi/archive/refs/tags/${HIDAPI_VERSION}.tar.gz" \
            | tar -xz
    fi
    mkdir -p "hidapi-build-$PLATFORM"
    cd "hidapi-build-$PLATFORM"
    cmake ../"$HIDAPI_SRC_DIR" \
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
    cp "$BUILD_DIR/hidapi-${HIDAPI_VERSION}/LICENSE.txt" "$OUT/LICENSES/hidapi-LICENSE" 2>/dev/null || true
fi

# Roll the flat staging dir into the tarball CI uploads as the release
# asset (matches sibling scripts: <tool>-<platform>.tar.gz at OUTPUT_DIR).
cd "$OUTPUT_DIR"
tar -czf "libfido2-${PLATFORM}.tar.gz" "libfido2-$PLATFORM"
echo "Created: libfido2-${PLATFORM}.tar.gz"

echo "libfido2 package built at $OUT"
ls -la "$OUT/lib" "$OUT/include" 2>&1 || true
