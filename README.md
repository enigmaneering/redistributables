<picture>
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_light.png">
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_dark.png">
    <img alt="redistributables logo" src="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_light.png" >
</picture>

This repository releases pre-built tools for [libmental](https://git.enigmaneering.org/enigmaneering/mental). All tools are as faithful of upstream builds as possible
across 7 targets (6 native + WebAssembly).

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

All components have open source licenses, which are verified on every build and packaged alongside each artifact.

If any of the licenses change underneath us, a nightly check will alert us to address it at that time.

## Windows Note

Our Windows artifacts are PE/COFF DLLs built via MSYS2 UCRT64 (GCC / MinGW-w64 family), not MSVC — they
link against ucrtbase.dll (the Universal CRT) and ship with GCC-style .dll.a import libraries rather than
MSVC .lib files. Consumers need a UCRT-family toolchain (MSYS2, MinGW-w64 UCRT, or clang in UCRT mode);
plain MSVC can't link them directly due to the CRT coupling and import-lib format differences.

There are so many reasons for this, mostly from interoperability perspectives.