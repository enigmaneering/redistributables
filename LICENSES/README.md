# Third-Party Software Licenses

This project includes the following open-source software components:

## DXC (DirectX Shader Compiler)

- **License**: University of Illinois/NCSA Open Source License (LLVM-based)
- **Source**: https://github.com/microsoft/DirectXShaderCompiler
- **Purpose**: HLSL to SPIR-V compilation
- **License File**: [DXC.LICENSE](DXC.LICENSE)
- **Note**: DXC includes DirectX-Headers as a git submodule (MIT License)

DXC is Microsoft's DirectX Shader Compiler based on LLVM/Clang. It compiles HLSL shaders to DXIL or SPIR-V, enabling cross-platform shader development.

## glslang

- **License**: Multiple (BSD-3-Clause, Apache 2.0, and others - see license file)
- **Source**: https://github.com/KhronosGroup/glslang
- **Purpose**: GLSL to SPIR-V compilation
- **License File**: [glslang.LICENSE](glslang.LICENSE)

glslang is the official reference compiler front end for the OpenGL ES and OpenGL shading languages. It implements a strict interpretation of the specifications for these languages.

## SPIRV-Tools

- **License**: Apache License 2.0
- **Source**: https://github.com/KhronosGroup/SPIRV-Tools
- **Purpose**: SPIR-V optimizer, validator, and disassembler
- **License File**: [SPIRV-Tools.LICENSE](SPIRV-Tools.LICENSE)

SPIRV-Tools provides an API and commands for processing SPIR-V modules. The project includes an assembler, binary module parser, disassembler, validator, and optimizer for SPIR-V.

## SPIRV-Headers

- **License**: MIT-style (modified MIT license - see license file)
- **Source**: https://github.com/KhronosGroup/SPIRV-Headers
- **Purpose**: Machine-readable SPIR-V specification headers
- **License File**: [SPIRV-Headers.LICENSE](SPIRV-Headers.LICENSE)

SPIRV-Headers provides the machine-readable files for the SPIR-V Registry. This includes the header files for various languages, the JSON grammar, and the specification.

## SPIRV-Cross

- **License**: Apache License 2.0
- **Source**: https://github.com/KhronosGroup/SPIRV-Cross
- **Purpose**: Shader transpilation from SPIR-V to GLSL, HLSL, and MSL
- **License File**: [SPIRV-Cross.LICENSE](SPIRV-Cross.LICENSE)

SPIRV-Cross is a practical tool and library for performing reflection on SPIR-V and disassembling SPIR-V back to high level languages.

---

All third-party software is used in accordance with their respective licenses. The full license texts are available in the files listed above.
