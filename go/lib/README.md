# External - Go Module

Go package for automatically downloading and managing shader compilation toolchain binaries.

## Features

- Automatic download of prebuilt binaries from GitHub Releases
- Automatic version updates when new releases are available
- Platform detection (darwin, linux, windows × amd64, arm64)
- Version management and tracking
- Opt-out mechanism for freezing versions
- Simple API for ensuring libraries are present

## Usage

```go
import external "github.com/enigmaneering/external/go/lib"

func main() {
    // Automatically download and extract external libraries
    // Downloads latest release or upgrades if newer version available
    if err := external.EnsureLibraries(); err != nil {
        log.Fatal(err)
    }

    // Libraries are now available in ./external/
    // - external/glslang/
    // - external/spirv-cross/
    // - external/dxc/
}
```

## Automatic Updates

By default, `EnsureLibraries()` will:
1. Check the latest release from `enigmaneering/external`
2. Compare with the currently installed version (stored in `external/.version`)
3. Automatically download and upgrade if a newer version is available

Example output when upgrading:
```
Upgrading external libraries: v0.0.42 → v0.0.43
Downloading glslang from https://github.com/...
Successfully installed glslang
...
```

Example output when up-to-date:
```
External libraries already up-to-date (v0.0.43)
```

## Freezing Versions

To prevent automatic updates and lock to a specific version:

```bash
# In your project's external directory
touch external/freeze
```

When the `freeze` file exists:
- No automatic updates will occur
- The currently installed version will be used
- A message will be displayed: `External libraries frozen at version v0.0.42`

To re-enable automatic updates:

```bash
rm external/freeze
```

**Note**: The `freeze` file should not be committed to version control (it's in `.gitignore`). This is a per-developer preference for local development environments.

## Configuration

Set the `EXTERNAL_DIR` environment variable to change the installation directory:

```bash
export EXTERNAL_DIR=/path/to/custom/external
```

## Version Selection

Use a specific release version:

```go
if err := external.EnsureLibrariesVersion("v0.0.42"); err != nil {
    log.Fatal(err)
}
```

## Version Tracking

The module tracks installed versions in `external/.version`. This file is automatically managed and should not be manually edited.

## Supported Platforms

- macOS ARM64 (darwin-arm64)
- macOS Intel (darwin-amd64)
- Linux x86_64 (linux-amd64)
- Linux ARM64 (linux-arm64)
- Windows x86_64 (windows-amd64)
- Windows ARM64 (windows-arm64)

## Included Libraries

- **glslang**: GLSL to SPIRV compiler with optimizer
- **SPIRV-Cross**: SPIRV transpiler (GLSL/HLSL/MSL)
- **DXC**: DirectX Shader Compiler (HLSL to SPIRV/DXIL)
