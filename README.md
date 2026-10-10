<picture>
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_light.png">
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_dark.png">
    <img alt="redistributables logo" src="https://raw.githubusercontent.com/enigmaneering/assets/refs/heads/main/redistributables/redistributables_light.png" >
</picture>

This repository releases pre-built tools for [libmental](https://git.enigmaneering.org/mental). All tools are as faithful of upstream builds as possible
across 8 targets (7 native + WebAssembly).

## Tools

| Tool | Purpose | Source |
|------|---------|--------|
| **glslang** | GLSL/ESSL to SPIR-V (includes SPIRV-Tools) | [Khronos](https://github.com/KhronosGroup/glslang) |
| **SPIRV-Cross** | SPIR-V to GLSL/HLSL/MSL | [Khronos](https://github.com/KhronosGroup/SPIRV-Cross) |
| **spirv-to-dxil** | SPIR-V to DXIL (D3D12 backend; carve-out of Mesa) | [Mesa](https://gitlab.freedesktop.org/mesa/mesa) |
| **Naga** | WGSL to/from SPIR-V (shared library via FFI) | [gfx-rs](https://github.com/gfx-rs/wgpu) |
| **wgpu-native** | WebGPU runtime (Metal/Vulkan/D3D12/OpenGL) | [gfx-rs](https://github.com/gfx-rs/wgpu-native) |
| **LLVM** | LLVM + Clang + LLD dev kit (static archives, headers, tools, source): backends X86, ARM, AArch64, RISC-V, LoongArch, PowerPC, SystemZ, WebAssembly, NVPTX, AMDGPU, SPIRV | [LLVM](https://github.com/llvm/llvm-project) |
| **clang** | the slim pinned toolchain [enigmatic](https://git.enigmaneering.org/enigmatic)'s `e fetch clang` installs: `bin/clang`, `bin/lld`, `bin/llvm-objdump`, the builtin headers — same build, same backends, one commit on every host | [LLVM](https://github.com/llvm/llvm-project) |
| **clspv** | OpenCL C to Vulkan SPIR-V | [Google](https://github.com/google/clspv) |
| **SPIRV-LLVM-Translator** | SPIR-V ↔ LLVM IR bridge | [Khronos](https://github.com/KhronosGroup/SPIRV-LLVM-Translator) |

**NOTE:** The `spirv-to-dxil` build only uses the `src/microsoft/spirv_to_dxil` code and its NIR / `dxil_compiler`
dependencies, not the full library.

## Platforms

All tools except `spirv-to-dxil` and `clang` are provided for:
- macOS ARM64 / x86_64
- Linux x86_64 / ARM64 / RISC-V (riscv64)
- Windows x86_64 / ARM64
- WebAssembly

**NOTE:** `linux-riscv64` is the one cross-compiled native platform: GitHub hosts no riscv64 runner, so
`ubuntu-latest` builds it with Ubuntu's own riscv64 cross toolchain (`scripts/common.sh`'s `IS_CROSS`, the
two-phase shape the WebAssembly build already has), verifies the tools under qemu-user, and `board.yml`
proves the assets natively on a VisionFive 2 registered as a self-hosted runner. Its tools need glibc 2.38
or newer on the target (Ubuntu 24.04 ships 2.39), as the asset's report records. Two tools differ in how
they are made for it: `wgpu-native` is built from source with Rust's riscv64gc target
(`scripts/build-wgpu-native.sh`), since gfx-rs publishes no riscv64 binary, and `libfido2` links the
target's libcrypto and libudev from Ubuntu's riscv64 multiarch packages.

**NOTE:** `spirv-to-dxil` is only used on Windows or WSL targets, as that's the only places where D3D12 lives.

**NOTE:** `clang` (the slim toolchain) is built for the seven native platforms and not for WebAssembly: it is a
compiler that runs on a host, and the WebAssembly LLVM build is a library for running inside one.

## The slim clang (`clang-<platform>.tar.gz`)

One LLVM, pinned, on every host — so a kernel regenerated on a laptop and in CI compiles byte for byte the
same, and a consumer's drift gate (`go generate ./... && git diff --exit-code`) can be a real one. `e fetch
clang` downloads this asset into `<root>/external/clang`; `e` then finds it as the second rung of its
toolchain ladder (after `E_CLANG`, before anything on the host) and records `redistributables vX.Y.Z` beside
the clang version in `e.json` and in every generated header.

What is inside, and why nothing more:

```
clang-<platform>/
  bin/clang[.exe]             the real driver binary (on unix the clang-<major> file itself, not a link)
  bin/clang++                 unix only, symlink → clang
  bin/lld[.exe]               the real LLD driver; every flavor lives in it
  bin/ld.lld, bin/wasm-ld     unix only, symlinks → lld (lld takes its flavor from argv[0];
                              clang's -fuse-ld=lld looks for exactly these names beside itself)
  bin/llvm-objdump[.exe]      e's second decoder
  lib/clang/<major>/include/  the builtin headers (<stdint.h>, <stddef.h>, …) a -ffreestanding
                              -nostdlib compile still includes; found via realpath(argv[0])/../lib
  VERSION                     the LLVM commit (the same string determine-shas pinned)
  LICENSES/                   LLVM-LICENSE.TXT, Clang-LICENSE.TXT, LLD-LICENSE.TXT
```

- **Windows ships no links at all**: one `clang.exe`, one `lld.exe`, one `llvm-objdump.exe`. MSYS2 degrades
  `ln -s` to a copy, a copy of a ~150 MB static binary per alias is not worth shipping, and `e` links
  WebAssembly there as `lld.exe -flavor wasm`. The archive is `.tar.gz` on all seven platforms (e's fetch
  has no xz and no zip need).
- **Statically linked**: the tools depend on the OS alone — no MSYS2 DLLs (`libstdc++-6`, `libwinpthread-1`,
  `libc++`), no Homebrew dylibs, no distro `libstdc++` of a particular release. Linux links glibc
  dynamically (the only sane way); macOS links `/usr/lib` only, with a deployment floor of macOS 12 (Go
  1.26's own floor). `scripts/package-clang.sh` asserts the dependency list of every shipped tool on every
  build and records the glibc floor in `clang-<platform>.report.txt`.
- **Stripped**, with the build tree's own `llvm-strip`; ad-hoc re-signed on macOS.
- **Not inside**: `clang-cl`, `clang-cpp`, `lld-link`, `ld64.lld`, `llvm-mc`, `llvm-readobj`, compiler-rt.
  `e` calls `clang`, `wasm-ld`/`lld` and `llvm-objdump` and nothing else, and the stdsyn dialect is
  freestanding (`-ffreestanding -nostdlib -fno-builtin`; an undefined symbol is a dialect error), so no
  runtime library is ever linked. Nothing from this asset links into any consumer binary — it is a
  subprocess `e` drives; the license texts travel with it under `LICENSES/`.
- `clang --version` names the commit by itself — `clang version 23.0.0git (https://github.com/llvm/llvm-project.git <sha>)`
  — because the build checks LLVM out with git and keeps `LLVM_APPEND_VC_REV=ON`.

### The pin

`CURRENT_VERSIONS.txt` is the one place the LLVM family is pinned: `CLSPV_SHA` (clspv's commit) and
`LLVM_SHA` (the LLVM commit clspv's `deps.json` names at that commit — `build-release.yml` resolves it from
`deps.json` and refuses to build if the two lines disagree). The nightly `check-versions.yml` tracks the
other tools and carries these pins through untouched. A bump is a deliberate edit of those lines followed
by a release; `e` pins the release it fetches, and every consumer regenerates under the new clang before its
drift gate goes green again.

`scripts/package-clang.sh` can also be run by hand against an existing install tree
(`LLVM_INSTALL_DIR=… LLVM_SOURCE_DIR=… PLATFORM=… LLVM_TAG=… OUTPUT_DIR=…`); `PACKAGE_CLANG_STRICT=0`
turns its verifications into warnings for local experiments.

## License

All artifacts have open source licenses, which are verified on every build and packaged alongside each.

If any of the licenses change underneath us, a nightly check will alert us to address it at that time.

## Windows Note

Our Windows artifacts are PE/COFF DLLs built via MSYS2 UCRT64 (GCC / MinGW-w64 family), not MSVC — they
link against ucrtbase.dll (the Universal CRT) and ship with GCC-style .dll.a import libraries rather than
MSVC .lib files. Consumers need a UCRT-family toolchain (MSYS2, MinGW-w64 UCRT, or clang in UCRT mode);
plain MSVC can't link them directly due to the CRT coupling and import-lib format differences.

There are so many reasons for this, mostly from interoperability perspectives.

The executables in the Windows LLVM builds (the dev kit's tools and the whole slim `clang` asset) are the
exception to "needs a toolchain": they are linked `-static`, import Windows system DLLs only, and run on a
machine with no MSYS2 at all. The dev kit's `bin/` on Windows keeps one `clang.exe` and one `lld.exe`;
the aliases cmake would have installed as full copies (`clang++.exe`, `clang-cl.exe`, `clang-cpp.exe`,
`clang-dxc.exe`, `ld.lld.exe`, `ld64.lld.exe`, `lld-link.exe`, `wasm-ld.exe`) are pruned to keep the
artifact under GitHub's 2 GiB asset cap — `clang --driver-mode=g++` and `lld -flavor <x>` are the same
programs.