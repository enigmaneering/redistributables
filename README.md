# Redistributables

Pre-built shader compilation and GPU compute toolchain for [libmental](https://git.enigmaneering.org/enigmaneering/mental). All tools are faithful upstream builds across 7 targets (6 native + WebAssembly).

## Tools

| Tool | Purpose | Source |
|------|---------|--------|
| **glslang** | GLSL/ESSL to SPIR-V (includes SPIRV-Tools) | [Khronos](https://github.com/KhronosGroup/glslang) |
| **SPIRV-Cross** | SPIR-V to GLSL/HLSL/MSL | [Khronos](https://github.com/KhronosGroup/SPIRV-Cross) |
| **Naga** | WGSL to/from SPIR-V (shared library via FFI) | [gfx-rs](https://github.com/gfx-rs/wgpu) |
| **wgpu-native** | WebGPU runtime (Metal/Vulkan/D3D12/OpenGL) | [gfx-rs](https://github.com/gfx-rs/wgpu-native) |
| **LLVM** | LLVM + Clang (NVPTX, AMDGPU backends) | [LLVM](https://github.com/llvm/llvm-project) |
| **clspv** | OpenCL C to Vulkan SPIR-V | [Google](https://github.com/google/clspv) |
| **SPIRV-LLVM-Translator** | SPIR-V ↔ LLVM IR bridge | [Khronos](https://github.com/KhronosGroup/SPIRV-LLVM-Translator) |

## Platforms

All tools are provided for:
- macOS ARM64 / x86_64
- Linux x86_64 / ARM64
- Windows x86_64 / ARM64
- WebAssembly

## License

All components are Apache 2.0 or dual MIT/Apache 2.0. Licenses are verified on every build and packaged alongside each artifact.
