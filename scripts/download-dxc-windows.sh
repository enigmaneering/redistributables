#!/bin/bash
set -e

# Download DXC from NuGet for Windows (AMD64 and ARM64)
# Uses official Microsoft.Direct3D.DXC package which is licensed for redistribution

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"
PACKAGE_NAME="Microsoft.Direct3D.DXC"

# Query NuGet for latest version if not specified
if [ -z "$DXC_VERSION" ]; then
    echo "Querying NuGet for latest version of $PACKAGE_NAME..."
    DXC_VERSION=$(curl -s "https://api.nuget.org/v3-flatcontainer/${PACKAGE_NAME}/index.json" | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | tail -1 | tr -d '"')
    if [ -z "$DXC_VERSION" ]; then
        echo "Error: Could not determine latest DXC version from NuGet"
        exit 1
    fi
    echo "Latest version: $DXC_VERSION"
fi

# Determine architecture
if [ -n "$CROSS_COMPILE_TARGET" ]; then
    if [ "$CROSS_COMPILE_TARGET" = "aarch64" ]; then
        ARCH="arm64"
    else
        ARCH="x64"
    fi
else
    # Detect from uname
    MACHINE=$(uname -m)
    if [[ "$MACHINE" == "x86_64" || "$MACHINE" == "amd64" ]]; then
        ARCH="x64"
    elif [[ "$MACHINE" == "aarch64" || "$MACHINE" == "arm64" ]]; then
        ARCH="arm64"
    else
        echo "Unsupported architecture: $MACHINE"
        exit 1
    fi
fi

PLATFORM="windows-$ARCH"
echo "Downloading DXC for $PLATFORM from NuGet..."

# Create temp directory for download
TEMP_DIR="$SCRIPT_DIR/../build/dxc-nuget-temp"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# Download NuGet package
NUGET_URL="https://www.nuget.org/api/v2/package/${PACKAGE_NAME}/${DXC_VERSION}"
PACKAGE_FILE="${PACKAGE_NAME}.${DXC_VERSION}.nupkg"

echo "Downloading from $NUGET_URL..."
curl -L -o "$PACKAGE_FILE" "$NUGET_URL"

# NuGet packages are just zip files - extract them
echo "Extracting package..."
unzip -q "$PACKAGE_FILE"

# Verify license exists before copying binaries (fail fast)
echo "Verifying license file..."
if [ ! -f "LICENSE.txt" ] && [ ! -f "LICENSE.TXT" ] && [ ! -f "LICENSE" ]; then
    echo "Error: LICENSE not found in NuGet package"
    exit 1
fi
echo "License file verified"

# Copy binaries to output directory
# NuGet package structure: bin/{x64,arm64}/{dxc.exe,dxcompiler.dll,dxil.dll}
NUGET_BIN_DIR="bin/$ARCH"

if [ ! -d "$NUGET_BIN_DIR" ]; then
    echo "Error: Architecture $ARCH not found in NuGet package"
    echo "Available architectures:"
    ls -d bin/* || true
    exit 1
fi

mkdir -p "$OUTPUT_DIR/$PLATFORM"

echo "Copying DXC binaries..."
cp "$NUGET_BIN_DIR/dxc.exe" "$OUTPUT_DIR/$PLATFORM/"
cp "$NUGET_BIN_DIR/dxcompiler.dll" "$OUTPUT_DIR/$PLATFORM/"
cp "$NUGET_BIN_DIR/dxil.dll" "$OUTPUT_DIR/$PLATFORM/"

# Copy license from NuGet package
echo "Copying license..."
# License was already verified to exist
if [ -f "LICENSE.txt" ]; then
    cp "LICENSE.txt" "$OUTPUT_DIR/$PLATFORM/LICENSE"
elif [ -f "LICENSE.TXT" ]; then
    cp "LICENSE.TXT" "$OUTPUT_DIR/$PLATFORM/LICENSE"
else
    cp "LICENSE" "$OUTPUT_DIR/$PLATFORM/LICENSE"
fi

echo "DXC binaries for $PLATFORM installed to $OUTPUT_DIR/$PLATFORM"
ls -lh "$OUTPUT_DIR/$PLATFORM"

# Cleanup
cd "$SCRIPT_DIR"
rm -rf "$TEMP_DIR"

echo "Done!"
