<picture>
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_light.png">
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_dark.png">
    <img alt="redistributables logo" src="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_light.png" >
</picture>

# `__VERSION__`

Complete cross-platform shader compilation toolchain with support for GLSL, HLSL, WGSL, SPIR-V, OpenCL, and CUDA. Pre-built binaries for all supported platforms.

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

Each tool is packaged separately:
- `glslang-{platform}.tar.gz` / `.zip`
- `spirv-cross-{platform}.tar.gz` / `.zip`
- `naga-{platform}.tar.gz` / `.zip`
- `wgpu-{platform}.tar.gz`

## 📝 License

All tools maintain their original licenses. See individual tool directories for license information.
