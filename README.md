# Redistributables

Pre-built shader compilation and GPU compute toolchain for [libmental](https://git.enigmaneering.org/enigmaneering/mental). All tools are built from source across 6 native platforms + WebAssembly.

## Tools

| Tool | Purpose | Source |
|------|---------|--------|
| **[glslang](https://github.com/KhronosGroup/glslang)** | GLSL/ESSL to SPIR-V (includes SPIRV-Tools) | Khronos |
| **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)** | SPIR-V to GLSL/HLSL/MSL | Khronos |
| **[Naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga)** | WGSL to/from SPIR-V | gfx-rs |
| **[libmental-mlvm](mental-mlvm/)** | MLVM translation layer — HLSL/CUDA/OpenCL C compilation, SPIR-V↔LLVM IR bridge, PTX/AMDGPU codegen | Enigmaneering (wraps LLVM/Clang/clspv) |
| **[wgpu-native](https://github.com/gfx-rs/wgpu-native)** | WebGPU runtime (Metal/Vulkan/D3D12/OpenGL) | gfx-rs |

## Platforms

All tools are provided for:
- macOS ARM64 / x86_64
- Linux x86_64 / ARM64
- Windows x86_64 / ARM64
- WebAssembly (glslang, SPIRV-Cross, Naga, libmental-mlvm)

## Installation

```bash
# Via the e CLI
e fetch

# Via Go module
import "git.enigmaneering.org/enigmatic/gpu"
gpu.EnsureLibraries()
```

## License

Each tool carries its own license (Apache 2.0, MIT, or similar). Licenses are verified on every build and packaged alongside each binary. No binaries are stored in this repository — only build scripts and CI configuration.
