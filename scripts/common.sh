#!/bin/bash
# Common setup shared by all build scripts.
# Source this, don't execute it: . "$(dirname "$0")/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"

# Windows: ensure MSYS2 MinGW tools are on PATH (must happen before
# platform detection since cmake/ninja/python resolution depends on it)
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    export PATH="/mingw64/bin:/ucrt64/bin:$PATH"
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

# Parallelism
if [[ "$OSTYPE" == "darwin"* ]]; then
    NCPU=$(($(sysctl -n hw.ncpu) / 2))
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    NCPU=2
else
    NCPU=2
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

