# Shader Compilation Toolchain __VERSION__

Complete cross-platform shader compilation toolchain with support for GLSL, HLSL, WGSL, and SPIRV. Pre-built binaries for all supported platforms.

## 🚀 Quick Start

### Automated Installation (Recommended)

Use the [`fetch` CLI tool](https://git.enigmaneering.org/enigmaneering/external/releases/tag/__GPU_VERSION__) or [Go module](https://git.enigmaneering.org/enigmaneering/external/tree/main/go/fetch) for automatic installation:

```bash
# Download fetch CLI from the go/fetch release
# See: https://git.enigmaneering.org/enigmaneering/external/releases/tag/__GPU_VERSION__

./fetch  # Automatically downloads and installs this version
```

Or use the Go module:

```go
import "git.enigmaneering.org/redistributables/go/fetch/gpu"

func main() {
    // Automatically downloads latest toolchain to ./external/
    if err := gpu.EnsureLibraries(); err != nil {
        log.Fatal(err)
    }
}
```

## 🛠️ Included Tools

| Tool | Description | Capabilities |
|------|-------------|--------------|
| **glslang** | Reference GLSL/ESSL validator and compiler | GLSL/ESSL → SPIRV, with SPIRV optimizer |
| **SPIRV-Cross** | SPIRV reflection and transpiler | SPIRV → GLSL/HLSL/MSL/WGSL |
| **Naga** | Rust-based WebGPU shader compiler | WGSL/GLSL/SPIRV ↔ SPIRV/WGSL/MSL/HLSL/GLSL |
| **clspv** | OpenCL C to Vulkan SPIR-V compiler | OpenCL C → SPIR-V for cross-backend compute |
| **llvm** | LLVM + Clang (NVPTX, AMDGPU backends) | Foundation for clspv and SPIRV-LLVM-Translator |
| **clspv** | OpenCL C → Vulkan SPIR-V (built against llvm) | Memory model transformation |
| **spirv-llvm-translator** | SPIR-V ↔ LLVM IR bridge (built against llvm) | Cross-hub translation |
| **wgpu-native** | Cross-platform WebGPU implementation | GPU compute via Metal/Vulkan/D3D12/OpenGL |

## 💻 Supported Platforms

All binaries are provided for the following platforms:

- ✅ macOS ARM64 (Apple Silicon M1/M2/M3/M4)
- ✅ macOS x86_64 (Intel)
- ✅ Linux x86_64 (glibc 2.31+)
- ✅ Linux ARM64 (glibc 2.31+)
- ✅ Windows x86_64
- ✅ Windows ARM64

## 📦 Manual Installation

Download the appropriate `.tar.gz` (Unix) or `.zip` (Windows) archives for your platform and extract them to your project's `external/` directory.

Each tool is packaged separately:
- `glslang-{platform}.tar.gz` / `.zip`
- `spirv-cross-{platform}.tar.gz` / `.zip`
- `naga-{platform}.tar.gz` / `.zip`
- `wgpu-{platform}.tar.gz`

## 🔄 Version Management

When using the fetch tool or Go module:
- **`.version`** file tracks the installed version
- **`FREEZE`** file prevents automatic updates (create manually to pin version)
- Automatic upgrade detection

## 📝 License

All tools maintain their original licenses. See individual tool directories for license information.
