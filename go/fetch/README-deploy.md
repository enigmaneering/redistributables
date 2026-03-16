# External Shader Compilation Tools

Pre-built shader compilation toolchain binaries automatically managed by the `enigmaneering/external` package.

## What's Installed

This directory contains four shader compilation tools:

### glslang
- **Location**: `glslang/bin/glslangValidator`
- **Purpose**: GLSL to SPIRV compiler with optimizer
- **Includes**: SPIRV-Tools (optimizer/validator) and SPIRV-Headers
- **License**: BSD-3-Clause / Apache-2.0
- **Source**: https://github.com/KhronosGroup/glslang

### SPIRV-Cross
- **Location**: `spirv-cross/bin/spirv-cross`
- **Purpose**: SPIRV to GLSL/HLSL/MSL/WGSL transpiler
- **License**: Apache-2.0
- **Source**: https://github.com/KhronosGroup/SPIRV-Cross

### DXC (DirectX Shader Compiler)
- **Location**: `dxc/bin/dxc` (or `dxc.exe` on Windows)
- **Purpose**: HLSL to SPIRV/DXIL compiler
- **License**: University of Illinois/NCSA Open Source License
- **Source**: https://github.com/microsoft/DirectXShaderCompiler
- **Note**: Windows binaries are official Microsoft redistributables from NuGet

### Naga
- **Location**: `naga/bin/naga` (or `naga.exe` on Windows)
- **Purpose**: WGSL to SPIRV compiler
- **License**: Apache-2.0 / MIT
- **Source**: https://github.com/gfx-rs/naga
- **Note**: Part of the WebGPU ecosystem (wgpu project)

## Version Information

The installed version is tracked in `.version` file in this directory.

To see what version you have:
```bash
cat external/.version
```

## Automatic Updates

By default, your libraries are automatically updated to the latest stable release when you build your project.

### Checking for Updates
Updates are checked automatically when you run your project's build command (e.g., `make`).

### Freezing Versions
To prevent automatic updates and stay on your current version:

```bash
# In your project root
touch external/FREEZE
```

When frozen, you'll see:
```
External libraries frozen at version v0.0.42
(Remove 'FREEZE' file in external directory to enable automatic updates)
```

To re-enable automatic updates:
```bash
rm external/FREEZE
```

### Manual Version Selection
You can manually install a specific version if needed. See the Go library documentation for details.

## Platform Support

These binaries are built specifically for your platform:
- macOS ARM64 (Apple Silicon)
- macOS x86_64 (Intel)
- Linux x86_64
- Linux ARM64
- Windows x86_64
- Windows ARM64

## Licenses

Each tool includes its license files preserved from the original source repositories:

### glslang
- `glslang/LICENSE.txt` - Main glslang license (BSD-3-Clause)
- `glslang/LICENSES/SPIRV-Tools-LICENSE` - SPIRV-Tools (Apache-2.0)
- `glslang/LICENSES/SPIRV-Headers-LICENSE` - SPIRV-Headers (MIT-style)

### SPIRV-Cross
- `spirv-cross/LICENSE` - Main license (Apache-2.0)
- `spirv-cross/LICENSES/` - Additional license texts referenced by the main license

### DXC (DirectX Shader Compiler)
- `dxc/LICENSE.TXT` - Main DXC license (University of Illinois/NCSA)
- `dxc/LICENSES/DxilCompression-LICENSE.TXT` - DxilCompression component (RAD Game Tools/Valve)
- `dxc/LICENSES/LICENSE-LLVM.txt` - LLVM license (Windows binaries only)

All licenses permit redistribution of precompiled binaries.

## Upstream Sources

These tools track the latest stable releases from:
- **glslang**: Latest GitHub release tag
- **SPIRV-Cross**: Latest Vulkan SDK tag
- **DXC**: Latest from Microsoft NuGet (Windows) or GitHub releases (Linux/macOS)

## Troubleshooting

### Libraries not found
If you're getting "library not found" errors:
1. Ensure this directory exists: `external/`
2. Run your project's build command (e.g., `make`) to download libraries
3. Check that binaries exist in `glslang/bin/`, `spirv-cross/bin/`, `dxc/bin/`

### Wrong version
To force a re-download:
```bash
# Remove FREEZE if present
rm external/FREEZE

# Clean external libraries
rm -rf external/glslang external/spirv-cross external/dxc external/.version

# Re-run build to download latest
make
```

### Disable automatic updates
Create a `FREEZE` file as described above in the "Freezing Versions" section.

## More Information

- **Repository**: https://github.com/enigmaneering/external
- **Releases**: https://github.com/enigmaneering/external/releases
- **Go Library**: https://github.com/enigmaneering/external/tree/main/go/lib

---

🤖 This directory is automatically managed. Manual modifications may be overwritten during updates.
