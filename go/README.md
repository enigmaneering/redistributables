# Vendor - Go Module

Go package for automatically downloading and managing shader compilation toolchain binaries.

## Usage

```go
import "github.com/enigmaneering/vendor"

func main() {
    // Automatically download and extract vendor libraries
    if err := vendor.EnsureLibraries(); err != nil {
        log.Fatal(err)
    }

    // Libraries are now available in ./external/
    // - external/glslang/
    // - external/spirv-cross/
    // - external/dxc/
}
```

## Configuration

Set the `VENDOR_EXTERNAL_DIR` environment variable to change the installation directory:

```bash
export VENDOR_EXTERNAL_DIR=/path/to/custom/external
```

## Version Selection

Use a specific release version:

```go
if err := vendor.EnsureLibrariesVersion("v0.0.42"); err != nil {
    log.Fatal(err)
}
```

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
