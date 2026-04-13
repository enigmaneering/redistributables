/*
 * mental_mlvm.h — C API for LLVM-based GPU compilation
 *
 * This is the translation layer for libmental.  It wraps LLVM/Clang C++
 * internals behind a flat C interface that mental can dlopen at runtime.
 *
 * Capabilities:
 *   - Compile CUDA source to PTX (NVIDIA native execution)
 *   - Compile OpenCL C source to SPIR-V (via Clang + SPIRV-LLVM-Translator)
 *   - Translate SPIR-V ↔ LLVM IR (bridge between SPIR-V and LLVM hubs)
 *   - Compile LLVM IR to PTX or AMDGPU ISA
 *
 * All functions return 0 on success, non-zero on error.
 * Output buffers are allocated by the library — free with mental_mlvm_free().
 */

#ifndef MENTAL_MLVM_H
#define MENTAL_MLVM_H

#include <stddef.h>

#ifdef _WIN32
#define MENTAL_MLVM_EXPORT __declspec(dllexport)
#else
#define MENTAL_MLVM_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/*  Source → GPU code (front-end + back-end in one call)               */
/* ------------------------------------------------------------------ */

/* Compile HLSL source to SPIR-V binary.
 * Uses Clang's upstream HLSL frontend + SPIRV-LLVM-Translator.
 * Replaces the dependency on Microsoft's DXC (LLVM fork). */
MENTAL_MLVM_EXPORT
int mental_mlvm_hlsl_to_spirv(const char* source, size_t source_len,
                               char** spirv_out, size_t* spirv_len,
                               char* error, size_t error_len);

/* Compile CUDA source to NVIDIA PTX assembly.
 * The PTX can be loaded directly by the CUDA driver (cuModuleLoadData). */
MENTAL_MLVM_EXPORT
int mental_mlvm_cuda_to_ptx(const char* source, size_t source_len,
                            char** ptx_out, size_t* ptx_len,
                            char* error, size_t error_len);

/* Compile OpenCL C source to OpenCL SPIR-V binary.
 * Uses Clang's OpenCL frontend + SPIRV-LLVM-Translator.
 * Produces OpenCL-flavored SPIR-V (execution model: Kernel). */
MENTAL_MLVM_EXPORT
int mental_mlvm_opencl_to_spirv(const char* source, size_t source_len,
                                 char** spirv_out, size_t* spirv_len,
                                 char* error, size_t error_len);

/* Compile OpenCL C source to Vulkan SPIR-V binary.
 * Uses clspv (built-in) for memory model transformation —
 * flat pointers → descriptor sets/bindings.
 * Produces Vulkan-flavored SPIR-V (execution model: GLCompute). */
MENTAL_MLVM_EXPORT
int mental_mlvm_opencl_to_vulkan_spirv(const char* source, size_t source_len,
                                        char** spirv_out, size_t* spirv_len,
                                        char* error, size_t error_len);

/* ------------------------------------------------------------------ */
/*  SPIR-V ↔ LLVM IR bridge                                           */
/* ------------------------------------------------------------------ */

/* Translate SPIR-V binary to LLVM IR bitcode.
 * Enables shader languages (GLSL/HLSL/WGSL) to reach GPU-native backends
 * (NVPTX, AMDGPU) by bridging the SPIR-V hub to the LLVM IR hub. */
MENTAL_MLVM_EXPORT
int mental_mlvm_spirv_to_ir(const char* spirv, size_t spirv_len,
                             char** ir_out, size_t* ir_len,
                             char* error, size_t error_len);

/* Translate LLVM IR bitcode to SPIR-V binary.
 * Enables compute languages (CUDA/OpenCL C) to reach shader backends
 * (Vulkan, Metal, WebGPU) by bridging the LLVM IR hub to the SPIR-V hub. */
MENTAL_MLVM_EXPORT
int mental_mlvm_ir_to_spirv(const char* ir, size_t ir_len,
                             char** spirv_out, size_t* spirv_len,
                             char* error, size_t error_len);

/* ------------------------------------------------------------------ */
/*  LLVM IR → GPU code (back-end only)                                 */
/* ------------------------------------------------------------------ */

/* Compile LLVM IR bitcode to NVIDIA PTX assembly. */
MENTAL_MLVM_EXPORT
int mental_mlvm_ir_to_ptx(const char* ir, size_t ir_len,
                           char** ptx_out, size_t* ptx_len,
                           char* error, size_t error_len);

/* Compile LLVM IR bitcode to AMD GPU relocatable code object. */
MENTAL_MLVM_EXPORT
int mental_mlvm_ir_to_amdgpu(const char* ir, size_t ir_len,
                              char** code_out, size_t* code_len,
                              char* error, size_t error_len);

/* ------------------------------------------------------------------ */
/*  Utility                                                            */
/* ------------------------------------------------------------------ */

/* Free an output buffer allocated by any of the above functions. */
MENTAL_MLVM_EXPORT
void mental_mlvm_free(char* buf);

/* Return the LLVM version string (e.g. "20.1.5"). */
MENTAL_MLVM_EXPORT
const char* mental_mlvm_version(void);

#ifdef __cplusplus
}
#endif

#endif /* MENTAL_MLVM_H */
