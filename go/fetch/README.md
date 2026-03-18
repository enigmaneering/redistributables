# fetch - Shader Compilation Toolchain Downloader

CLI tool and Go package for automatically downloading and managing shader compilation toolchain binaries.

## Features

- Automatic download of prebuilt binaries from GitHub Releases
- Automatic version updates when new releases are available
- Platform detection (darwin, linux, windows × amd64, arm64)
- Version management and tracking
- Opt-out mechanism for freezing versions
- CLI tool for non-Go projects
- Go API for programmatic use

## CLI Usage

Download and install the `fetch` binary for your platform from the [latest release](https://git.enigmaneering.org/enigmaneering/external/releases/latest).

### Basic Usage

```bash
# Install latest version to ./external
fetch

# Install specific version
fetch -version v1.0.42

# Install to custom directory
fetch -dir /opt/shaders

# Show help
fetch -help
```

### Examples

```bash
# Download latest toolchain
$ fetch
Installing latest shader compilation toolchain...
Downloading glslang from https://git.enigmaneering.org/enigmaneering/external/releases/download/v1.0.42/glslang-darwin-arm64.tar.gz...
Successfully installed glslang
Downloading spirv-cross from https://git.enigmaneering.org/...
Successfully installed spirv-cross
Downloading dxc from https://git.enigmaneering.org/...
Successfully installed dxc
Downloading naga from https://git.enigmaneering.org/...
Successfully installed naga

✓ Shader compilation toolchain installed successfully

# Use in shell script
#!/bin/bash
fetch || exit 1
./build-shaders.sh
```

## Go Package Usage

```go
import "git.enigmaneering.org/redistributables/go/fetch/gpu"

func main() {
    // Automatically download and extract external libraries
    // Downloads latest release or upgrades if newer version available
    if err := gpu.EnsureLibraries(); err != nil {
        log.Fatal(err)
    }

    // Libraries are now available in ./external/
    // - external/glslang/
    // - external/spirv-cross/
    // - external/dxc/
    // - external/naga/
}
```

## Automatic Updates

By default, `EnsureLibraries()` will:
1. Check the latest release from `enigmaneering/external`
2. Compare with the currently installed version (stored in `external/.version`)
3. Automatically download and upgrade if a newer version is available

Example output when upgrading:
```
Upgrading external libraries: v1.0.41 → v1.0.42
Downloading glslang from https://git.enigmaneering.org/...
Successfully installed glslang
...
```

Example output when up-to-date:
```
External libraries already up-to-date (v1.0.42)
```

## Freezing Versions

To prevent automatic updates and lock to a specific version:

```bash
# In your project's external directory
touch external/FREEZE
```

When the `FREEZE` file exists:
- No automatic updates will occur
- The currently installed version will be used
- A message will be displayed: `External libraries frozen at version v1.0.42`

To re-enable automatic updates:

```bash
rm external/FREEZE
```

**Note**: The `FREEZE` file should not be committed to version control (it's in `.gitignore`). This is a per-developer preference for local development environments.

## Configuration

Set the `EXTERNAL_DIR` environment variable to change the installation directory:

```bash
export EXTERNAL_DIR=/path/to/custom/external
fetch
```

Or use the CLI flag:

```bash
fetch -dir /path/to/custom/external
```

## Version Selection

### CLI

```bash
fetch -version v1.0.42
```

### Go API

```go
if err := fetch.EnsureLibrariesVersion("v1.0.42"); err != nil {
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
- **SPIRV-Cross**: SPIRV transpiler (GLSL/HLSL/MSL/WGSL)
- **DXC**: DirectX Shader Compiler (HLSL to SPIRV/DXIL)
- **Naga**: WebGPU shader compiler (WGSL to SPIRV)

## Building from Source

```bash
cd go/fetch
go build -o fetch
```

Cross-compile for all platforms:

```bash
cd go/fetch

# macOS ARM64
GOOS=darwin GOARCH=arm64 go build -o fetch-darwin-arm64

# macOS Intel
GOOS=darwin GOARCH=amd64 go build -o fetch-darwin-amd64

# Linux x86_64
GOOS=linux GOARCH=amd64 go build -o fetch-linux-amd64

# Linux ARM64
GOOS=linux GOARCH=arm64 go build -o fetch-linux-arm64

# Windows x86_64
GOOS=windows GOARCH=amd64 go build -o fetch-windows-amd64.exe

# Windows ARM64
GOOS=windows GOARCH=arm64 go build -o fetch-windows-arm64.exe
```

## Integration with Build Systems

### Makefile

```makefile
.PHONY: fetch-toolchain
fetch-toolchain:
	@command -v fetch > /dev/null || (echo "fetch not found. Download from https://git.enigmaneering.org/enigmaneering/external/releases" && exit 1)
	@fetch

build: fetch-toolchain
	# Your build commands here
```

### CMakeLists.txt

```cmake
find_program(FETCH_EXECUTABLE fetch)
if(NOT FETCH_EXECUTABLE)
    message(FATAL_ERROR "fetch not found. Download from https://git.enigmaneering.org/enigmaneering/external/releases")
endif()

execute_process(COMMAND ${FETCH_EXECUTABLE})
```

### npm/package.json

```json
{
  "scripts": {
    "fetch": "fetch",
    "prebuild": "npm run fetch",
    "build": "..."
  }
}
```
