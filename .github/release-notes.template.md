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
| **spirv-to-dxil** | Mesa's SPIR-V → DXIL compiler (carve-out, no LLVM dep) | SPIR-V → DXIL for D3D12 (Windows amd64/arm64 + Linux build-cover) |
| **Naga** | Rust-based WebGPU shader compiler | WGSL/GLSL/SPIRV ↔ SPIRV/WGSL/MSL/HLSL/GLSL |
| **clspv** | OpenCL C to Vulkan SPIR-V compiler | OpenCL C → SPIR-V for cross-backend compute |
| **llvm** | LLVM + Clang + LLD dev kit (X86, ARM, AArch64, RISC-V, LoongArch, PowerPC, SystemZ, WebAssembly, NVPTX, AMDGPU, SPIRV) | Foundation for clspv, SPIRV-LLVM-Translator and libmental |
| **clang** | The slim pinned toolchain for [enigmatic](https://git.enigmaneering.org/enigmatic): `bin/clang`, `bin/lld`, `bin/llvm-objdump`, builtin headers, from the same build as **llvm** | `e fetch clang` — one compiler on every host, byte-identical codegen |
| **spirv-llvm-translator** | SPIR-V ↔ LLVM IR bridge (built against llvm) | Cross-hub translation |
| **wgpu-native** | Cross-platform WebGPU implementation | GPU compute via Metal/Vulkan/D3D12/OpenGL |
| **libfido2** | Yubico's FIDO2/CTAP2 stack (+ libcbor, hidapi on Linux, libcrypto) | Enumerate + drive external security keys for WebAuthn attestation |

## 💻 Supported Platforms

All binaries are provided for the following platforms:

- ✅ macOS ARM64 (Apple Silicon M1/M2/M3/M4)
- ✅ macOS x86_64 (Intel)
- ✅ Linux x86_64 (glibc 2.31+)
- ✅ Linux ARM64 (glibc 2.31+)
- ✅ Windows x86_64
- ✅ Windows ARM64

Each tool is packaged separately (every asset is a `.tar.gz`, on Windows too):
- `glslang-{platform}.tar.gz`
- `spirv-cross-{platform}.tar.gz`
- `spirv-to-dxil-{platform}.tar.gz` (Linux x86_64/ARM64 + Windows x86_64/ARM64; macOS and WASM omitted — no D3D12 consumer there)
- `naga-{platform}.tar.gz`
- `clspv-{platform}.tar.gz`
- `llvm-{platform}.tar.gz` (the dev kit: static archives, headers, tools, full source tree; `VERSION` holds the pinned LLVM commit)
- `clang-{platform}.tar.gz` (the slim pinned toolchain for `e fetch clang`: `bin/clang`, `bin/lld` (+ `ld.lld`/`wasm-ld` symlinks on unix, none on Windows), `bin/llvm-objdump`, `lib/clang/<ver>/include`, `VERSION`, `LICENSES/`; six native platforms, no WASM; statically linked and stripped)
- `spirv-llvm-translator-{platform}.tar.gz`
- `wgpu-{platform}.tar.gz`
- `libfido2-{platform}.tar.gz` (bundles static libfido2.a + libcbor.a + libcrypto.a + fido/openssl headers; hidapi statically linked on Linux; Windows source-built with MinGW so it links cleanly into MinGW-family consumers)

## 📝 License

All tools maintain their original licenses. See individual tool directories for license information.

## 🪟 Windows Note

Our Windows artifacts are PE/COFF DLLs built via MSYS2 UCRT64 (GCC / MinGW-w64 family), not MSVC — they link against ucrtbase.dll (the Universal CRT) and ship with GCC-style .dll.a import libraries rather than MSVC .lib files. Consumers need a UCRT-family toolchain (MSYS2, MinGW-w64 UCRT, or clang in UCRT mode); plain MSVC can't link them directly due to the CRT coupling and import-lib format differences.