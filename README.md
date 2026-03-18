# Enigmaneering External Shader Compilation Tools

Pre-built shader compilation toolchain binaries for cross-platform development with automatic version management.

## What's Included

- **glslang** - GLSL to SPIRV compiler with optimizer support
  - Includes SPIRV-Tools (optimizer and validator)
  - Includes SPIRV-Headers (required headers)
- **SPIRV-Cross** - SPIRV to GLSL/HLSL/MSL/WGSL transpiler
- **DXC** - DirectX Shader Compiler (HLSL to SPIRV/DXIL)
- **Naga** - WebGPU shader compiler (WGSL to SPIRV)

## Supported Platforms

- macOS ARM64 (Apple Silicon)
- macOS x86_64 (Intel)
- Linux x86_64
- Linux ARM64
- Windows x86_64
- Windows ARM64

## Automatic Updates

This repository features a fully automated release pipeline:

### Daily Version Checks
- **Automated workflow** runs daily at 2 AM UTC
- **Queries upstream sources** for latest stable releases:
  - DXC from Microsoft NuGet (Windows) and GitHub Releases (Linux)
  - glslang from KhronosGroup GitHub Releases
  - SPIRV-Cross from Vulkan SDK tags
- **Auto-creates releases** when new versions are detected
- **Version numbering** automatically increments (e.g., v0.0.42 → v0.0.43)

### Build Process
- All platforms built from **latest stable sources**
- Windows uses official Microsoft DXC binaries from NuGet
- Linux/macOS build from source for maximum compatibility
- Releases include all binaries for all platforms

## Usage in Projects

### Automated (Recommended)

Use the Go library for automatic download and version management:

```go
import external "git.enigmaneering.org/redistributables/go/fetch/gpu"

func main() {
    // Automatically downloads latest release
    if err := external.EnsureLibraries(); err != nil {
        log.Fatal(err)
    }

    // Libraries ready in ./external/ directory
}
```

**Features:**
- Automatically downloads latest release
- Auto-upgrades when new versions available
- Platform detection (darwin/linux/windows × amd64/arm64)
- Version tracking and management
- Opt-out freeze mechanism (create `external/freeze` file)

See [go/lib/README.md](go/lib/README.md) for details.

### Manual Download

Download prebuilt binaries from the latest release:

```bash
VERSION="v0.0.42"  # or use 'latest'
PLATFORM="darwin-arm64"  # darwin-amd64, linux-amd64, linux-arm64, windows-amd64, windows-arm64

# Download all four tools
for tool in glslang spirv-cross dxc naga; do
  curl -L -o "${tool}.tar.gz" \
    "https://git.enigmaneering.org/enigmaneering/external/releases/download/${VERSION}/${tool}-${PLATFORM}.tar.gz"
  tar -xzf "${tool}.tar.gz" -C external/
  rm "${tool}.tar.gz"
done
```

## Build Details

### DXC (DirectX Shader Compiler)

**Windows:**
- Downloaded from official Microsoft NuGet package: `Microsoft.Direct3D.DXC`
- Latest version automatically queried from NuGet API
- AMD64 and ARM64 both available
- Licensed for redistribution
- Includes `dxc.exe`, `dxcompiler.dll`, and `dxil.dll`

**Linux:**
- Downloaded from Microsoft DirectXShaderCompiler GitHub Releases
- Latest release automatically detected

**macOS:**
- Built from source (Microsoft DirectXShaderCompiler main branch)
- Cross-compiled for both Intel and Apple Silicon

### glslang

- Built from latest GitHub release tag
- Includes SPIRV-Tools and SPIRV-Headers
- All platforms built from source

### SPIRV-Cross

- Built from latest Vulkan SDK tag
- All platforms built from source

### Naga

- Built from latest wgpu release
- Rust-based WGSL to SPIRV compiler
- All platforms built from source

## Creating Releases

### Automatic (Default)
Releases are created automatically when upstream dependencies update. No manual intervention needed.

### Manual Trigger
You can manually trigger a build from GitHub Actions:

1. Go to Actions tab
2. Select "Build and Release Vendor Tools" workflow
3. Click "Run workflow"
4. Version number will auto-increment from latest tag

### Manual Tag Push
Alternatively, push a tag manually:

```bash
git tag v0.0.43
git push origin v0.0.43
```

GitHub Actions will automatically build and release all platforms.

## Version Tracking

Each release includes a `CURRENT_VERSIONS.txt` file documenting the exact upstream versions:

```
DXC=1.9.2602.17
GLSLANG=16.2.0
SPIRV_CROSS=vulkan-sdk-1.4.341.0
NAGA=24.0.0
UPDATED=2026-03-15 02:00:00 UTC
```

## License

These are prebuilt binaries of open-source projects. See [README-licenses.md](README-licenses.md) for complete license information.

Summary:
- glslang (+ SPIRV-Tools/SPIRV-Headers): BSD-3-Clause / Apache-2.0
- SPIRV-Cross: Apache-2.0
- DXC: University of Illinois/NCSA Open Source License
- Naga: Apache-2.0 / MIT

All licenses permit redistribution of precompiled binaries.
