# Enigmaneering Vendor Tools

Pre-built shader compilation toolchain binaries for cross-platform development.

## What's Included

- **glslang** - GLSL to SPIRV compiler with optimizer support
  - Includes SPIRV-Tools (optimizer and validator)
  - Includes SPIRV-Headers (required headers)
- **SPIRV-Cross** - SPIRV to GLSL/HLSL/MSL transpiler
- **DXC** - DirectX Shader Compiler (HLSL to SPIRV/DXIL)
  - Built from source for all platforms (including macOS)

## Supported Platforms

- macOS ARM64 (Apple Silicon)
- macOS x86_64 (Intel)
- Linux x86_64
- Windows x86_64
- Windows ARM64

## Building

Builds are automated via GitHub Actions. To create a new release:

1. Update version numbers in build scripts if needed
2. Push a new tag: `git tag v1.0.0 && git push origin v1.0.0`
3. GitHub Actions will build all tools for all platforms
4. Artifacts are automatically published to GitHub Releases

## Manual Build

You can also manually trigger builds from the Actions tab.

## Usage in Projects

Download prebuilt binaries from the latest release:

```bash
VENDOR_VERSION="v1.0.0"
PLATFORM="darwin-arm64"  # or darwin-amd64, linux-amd64, windows-amd64

curl -L -o glslang.tar.gz \
  "https://github.com/enigmaneering/vendor/releases/download/${VENDOR_VERSION}/glslang-${PLATFORM}.tar.gz"

tar -xzf glslang.tar.gz -C external/
```

## License

These are prebuilt binaries of open-source projects. See [LICENSES.md](LICENSES.md) for full license text.

Summary:
- glslang (+ SPIRV-Tools/SPIRV-Headers): BSD-3-Clause / Apache-2.0
- SPIRV-Cross: Apache-2.0
- DXC: University of Illinois/NCSA Open Source License

All licenses permit redistribution of precompiled binaries.
