#!/bin/bash
# Common setup shared by all build scripts.
# Source this, don't execute it: . "$(dirname "$0")/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# Windows: ensure MSYS2 MinGW tools are on PATH (must happen before
# platform detection since cmake/ninja/python resolution depends on it).
# Order is broadest-first: clangarm64 entries are only present on the
# windows-11-arm runner (CLANGARM64 subsystem); mingw64 + ucrt64 cover
# x86_64 hosts.  Non-existent dirs in PATH are harmless.
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    export PATH="/clangarm64/bin:/mingw64/bin:/ucrt64/bin:$PATH"

    # Normalize Windows-native paths (e.g. D:\a\_temp/output) to POSIX form
    # (/d/a/_temp/output) so tools like tar don't parse the drive-letter colon
    # as old-style rsh "host:path" syntax. GitHub Actions' ${{ runner.temp }}
    # is Windows-native, so BUILD_DIR/OUTPUT_DIR come in that form.
    if command -v cygpath >/dev/null 2>&1; then
        BUILD_DIR="$(cygpath -u "$BUILD_DIR")"
        OUTPUT_DIR="$(cygpath -u "$OUTPUT_DIR")"
    fi
fi

# Platform detection — prefer MENTAL_PLATFORM env var if set by CI,
# since MSYS2 on Windows ARM64 misreports architecture as x86_64.
IS_WASM=0
if [ -n "$MENTAL_PLATFORM" ]; then
    PLATFORM="$MENTAL_PLATFORM"
    if [ "$PLATFORM" = "wasm" ]; then IS_WASM=1; fi
elif command -v emcmake &> /dev/null && [ "${WASM_BUILD:-0}" = "1" ]; then
    IS_WASM=1
    PLATFORM="wasm"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    ARCH=$(uname -m)
    if [ -n "$MACOS_ARCH" ]; then ARCH="$MACOS_ARCH"; fi
    PLATFORM="darwin-$ARCH"
    PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux-$(uname -m)"
    PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    PLATFORM="windows-$(uname -m)"
    PLATFORM=$(echo "$PLATFORM" | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')
fi

# Parallelism. NCPU in the environment wins (a workflow can pin it); otherwise
# every core on Linux and Windows — the hard-coded 2 dated from when GitHub's
# hosted runners had two cores; they have had four since January 2024, and the
# LLVM jobs (79–184 min at -j2) are the ones that notice. macOS stays at
# half the cores: the macos-14 runner has 3 cores and 7 GB, and an LLVM link
# wants a few GB each. (build-llvm.sh caps Windows link parallelism with
# LLVM_PARALLEL_LINK_JOBS for the same reason.)
if [ -n "$NCPU" ]; then
    :
elif [[ "$OSTYPE" == "darwin"* ]]; then
    NCPU=$(($(sysctl -n hw.ncpu) / 2))
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    NCPU=$(nproc 2>/dev/null || echo 2)
else
    NCPU=$(nproc 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-2}")
fi
if [ "$NCPU" -lt 1 ]; then NCPU=1; fi

# Find cmake
CMAKE=$(command -v cmake 2>/dev/null || true)
if [ -z "$CMAKE" ]; then
    for p in /ucrt64/bin/cmake.exe /mingw64/bin/cmake.exe; do
        if [ -x "$p" ]; then CMAKE="$p"; break; fi
    done
fi

# Find python
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [ -z "$PYTHON" ]; then
    for p in /ucrt64/bin/python3.exe /ucrt64/bin/python.exe /mingw64/bin/python3.exe /mingw64/bin/python.exe; do
        if [ -x "$p" ]; then PYTHON="$p"; break; fi
    done
fi

# Architecture flags for cmake
CMAKE_OSX_ARCH_FLAG=""
CMAKE_GENERATOR=""
if [ -n "$MACOS_ARCH" ]; then
    CMAKE_OSX_ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCH"
fi
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    CMAKE_GENERATOR="-G Ninja"
fi

