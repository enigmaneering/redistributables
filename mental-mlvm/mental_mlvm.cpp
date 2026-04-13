/*
 * mental_mlvm.cpp — LLVM/Clang C++ wrapper for libmental
 *
 * Implements the C API defined in mental_mlvm.h by wrapping:
 *   - Clang CompilerInstance + CodeGenAction (CUDA/OpenCL C → LLVM IR)
 *   - LLVM TargetMachine (LLVM IR → PTX/AMDGPU)
 *   - SPIRV-LLVM-Translator (SPIR-V ↔ LLVM IR)
 */

#include "mental_mlvm.h"

#include <cstring>
#include <cstdlib>
#include <string>
#include <sstream>
#include <memory>

/* LLVM core */
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/LegacyPassManager.h>
#include <llvm/Bitcode/BitcodeReader.h>
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/Support/TargetSelect.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/MC/TargetRegistry.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/Target/TargetOptions.h>
#include <llvm/Config/llvm-config.h>

/* Clang */
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CompilerInvocation.h>
#include <clang/CodeGen/CodeGenAction.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <clang/Basic/TargetOptions.h>

/* SPIRV-LLVM-Translator */
#include <LLVMSPIRVLib.h>

/* clspv (compiled into this library) */
#include <clspv/Compiler.h>

/* ------------------------------------------------------------------ */
/*  One-time initialization                                           */
/* ------------------------------------------------------------------ */

static bool g_initialized = false;

static void ensure_initialized() {
    if (g_initialized) return;
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmPrinters();
    llvm::InitializeAllAsmParsers();
    g_initialized = true;
}

/* ------------------------------------------------------------------ */
/*  Internal: compile source string via Clang to LLVM IR              */
/* ------------------------------------------------------------------ */

static std::unique_ptr<llvm::Module> compile_to_ir(
    llvm::LLVMContext& ctx,
    const char* source, size_t source_len,
    const std::string& lang,  /* "cuda" or "cl" */
    const std::string& triple,
    std::string& error_msg)
{
    /* Create virtual file with source */
    std::string filename = (lang == "cuda") ? "input.cu" : "input.cl";
    std::string source_str(source, source_len);

    /* Set up compiler invocation */
    auto invocation = std::make_shared<clang::CompilerInvocation>();

    std::vector<const char*> args;
    args.push_back("-x");
    args.push_back(lang.c_str());
    args.push_back(filename.c_str());
    args.push_back("-emit-llvm");
    args.push_back("--target");
    args.push_back(triple.c_str());

    if (lang == "cuda") {
        args.push_back("--cuda-device-only");
        args.push_back("--cuda-gpu-arch=sm_52");
    } else {
        args.push_back("-cl-std=CL2.0");
    }

    auto diag_opts = llvm::makeIntrusiveRefCnt<clang::DiagnosticOptions>();
    std::string diag_str;
    llvm::raw_string_ostream diag_os(diag_str);
    auto diag_printer = new clang::TextDiagnosticPrinter(diag_os, diag_opts.get());
    auto diag_ids = new clang::DiagnosticIDs();
    clang::DiagnosticsEngine diags(diag_ids, diag_opts.get(), diag_printer);

    bool ok = clang::CompilerInvocation::CreateFromArgs(*invocation, args, diags);
    if (!ok) {
        error_msg = "Failed to create compiler invocation: " + diag_str;
        return nullptr;
    }

    /* Create compiler instance */
    clang::CompilerInstance compiler;
    compiler.setInvocation(invocation);
    compiler.createDiagnostics(diag_printer, false);

    /* Create virtual file */
    auto buf = llvm::MemoryBuffer::getMemBufferCopy(source_str, filename);
    compiler.getPreprocessorOpts().addRemappedFile(filename, buf.release());

    /* Execute codegen action */
    auto action = std::make_unique<clang::EmitLLVMOnlyAction>(&ctx);
    if (!compiler.ExecuteAction(*action)) {
        error_msg = "Compilation failed: " + diag_str;
        return nullptr;
    }

    return action->takeModule();
}

/* ------------------------------------------------------------------ */
/*  Internal: compile LLVM IR module to target code                    */
/* ------------------------------------------------------------------ */

static int emit_to_target(
    llvm::Module& module,
    const std::string& triple,
    const std::string& cpu,
    char** out, size_t* out_len,
    std::string& error_msg)
{
    std::string err;
    auto target = llvm::TargetRegistry::lookupTarget(triple, err);
    if (!target) {
        error_msg = "Target not found: " + err;
        return -1;
    }

    llvm::TargetOptions opts;
    auto tm = target->createTargetMachine(
        triple, cpu, "", opts, llvm::Reloc::PIC_);
    if (!tm) {
        error_msg = "Failed to create target machine for " + triple;
        return -1;
    }

    module.setDataLayout(tm->createDataLayout());
    module.setTargetTriple(triple);

    std::string output;
    llvm::raw_string_ostream os(output);

    llvm::legacy::PassManager pm;
    if (tm->addPassesToEmitFile(pm, os, nullptr,
            llvm::CodeGenFileType::AssemblyFile)) {
        error_msg = "Target does not support assembly emission";
        return -1;
    }

    pm.run(module);
    os.flush();

    *out_len = output.size();
    *out = (char*)malloc(output.size());
    if (!*out) {
        error_msg = "Failed to allocate output buffer";
        return -1;
    }
    memcpy(*out, output.data(), output.size());
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Public API: Source → GPU code                                      */
/* ------------------------------------------------------------------ */

extern "C" int mental_mlvm_hlsl_to_spirv(
    const char* source, size_t source_len,
    char** spirv_out, size_t* spirv_len,
    char* error, size_t error_len)
{
    ensure_initialized();

    llvm::LLVMContext ctx;
    std::string err;

    auto module = compile_to_ir(ctx, source, source_len,
                                 "hlsl", "dxil-ms-dx", err);
    if (!module) {
        if (error) snprintf(error, error_len, "%s", err.c_str());
        return -1;
    }

    /* LLVM IR → SPIR-V via SPIRV-LLVM-Translator */
    std::ostringstream os;
    if (!writeSpirv(module.get(), os, err)) {
        if (error) snprintf(error, error_len, "SPIRV write failed: %s", err.c_str());
        return -1;
    }

    std::string spirv_data = os.str();
    *spirv_len = spirv_data.size();
    *spirv_out = (char*)malloc(spirv_data.size());
    if (!*spirv_out) {
        if (error) snprintf(error, error_len, "Failed to allocate output buffer");
        return -1;
    }
    memcpy(*spirv_out, spirv_data.data(), spirv_data.size());
    return 0;
}

extern "C" int mental_mlvm_cuda_to_ptx(
    const char* source, size_t source_len,
    char** ptx_out, size_t* ptx_len,
    char* error, size_t error_len)
{
    ensure_initialized();

    llvm::LLVMContext ctx;
    std::string err;

    auto module = compile_to_ir(ctx, source, source_len,
                                 "cuda", "nvptx64-nvidia-cuda", err);
    if (!module) {
        if (error) snprintf(error, error_len, "%s", err.c_str());
        return -1;
    }

    if (emit_to_target(*module, "nvptx64-nvidia-cuda", "sm_52",
                        ptx_out, ptx_len, err) != 0) {
        if (error) snprintf(error, error_len, "%s", err.c_str());
        return -1;
    }

    return 0;
}

extern "C" int mental_mlvm_opencl_to_spirv(
    const char* source, size_t source_len,
    char** spirv_out, size_t* spirv_len,
    char* error, size_t error_len)
{
    ensure_initialized();

    llvm::LLVMContext ctx;
    std::string err;

    auto module = compile_to_ir(ctx, source, source_len,
                                 "cl", "spir64-unknown-unknown", err);
    if (!module) {
        if (error) snprintf(error, error_len, "%s", err.c_str());
        return -1;
    }

    /* LLVM IR → SPIR-V via SPIRV-LLVM-Translator */
    std::ostringstream os;
    if (!writeSpirv(module.get(), os, err)) {
        if (error) snprintf(error, error_len, "SPIRV write failed: %s", err.c_str());
        return -1;
    }

    std::string spirv_data = os.str();
    *spirv_len = spirv_data.size();
    *spirv_out = (char*)malloc(spirv_data.size());
    if (!*spirv_out) {
        if (error) snprintf(error, error_len, "Failed to allocate output buffer");
        return -1;
    }
    memcpy(*spirv_out, spirv_data.data(), spirv_data.size());
    return 0;
}

extern "C" int mental_mlvm_opencl_to_vulkan_spirv(
    const char* source, size_t source_len,
    char** spirv_out, size_t* spirv_len,
    char* error, size_t error_len)
{
    /* Use clspv's C API — it handles memory model transformation
     * (flat pointers → descriptor sets) that Vulkan requires. */
    const char* programs[] = { source };
    size_t sizes[] = { source_len };
    char* output_binary = NULL;
    size_t output_size = 0;
    char* output_log = NULL;

    ClspvError rc = clspvCompileFromSourcesString(
        1, sizes, programs, "",
        &output_binary, &output_size, &output_log);

    if (rc != CLSPV_SUCCESS) {
        if (error) {
            if (output_log && output_log[0])
                snprintf(error, error_len, "clspv: %s", output_log);
            else
                snprintf(error, error_len, "clspv: Compilation failed (error %d)", (int)rc);
        }
        clspvFreeOutputBuildObjs(output_binary, output_log);
        return -1;
    }

    *spirv_len = output_size;
    *spirv_out = output_binary;  /* clspv allocates with malloc */
    free(output_log);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Public API: SPIR-V ↔ LLVM IR bridge                               */
/* ------------------------------------------------------------------ */

extern "C" int mental_mlvm_spirv_to_ir(
    const char* spirv, size_t spirv_len,
    char** ir_out, size_t* ir_len,
    char* error, size_t error_len)
{
    ensure_initialized();

    llvm::LLVMContext ctx;
    std::string err;

    std::istringstream is(std::string(spirv, spirv_len));
    llvm::Module* module = nullptr;

    if (!readSpirv(ctx, is, module, err)) {
        if (error) snprintf(error, error_len, "SPIRV read failed: %s", err.c_str());
        return -1;
    }

    /* Serialize LLVM IR to bitcode */
    std::string bc;
    llvm::raw_string_ostream os(bc);
    llvm::WriteBitcodeToFile(*module, os);
    os.flush();
    delete module;

    *ir_len = bc.size();
    *ir_out = (char*)malloc(bc.size());
    if (!*ir_out) {
        if (error) snprintf(error, error_len, "Failed to allocate output buffer");
        return -1;
    }
    memcpy(*ir_out, bc.data(), bc.size());
    return 0;
}

extern "C" int mental_mlvm_ir_to_spirv(
    const char* ir, size_t ir_len,
    char** spirv_out, size_t* spirv_len,
    char* error, size_t error_len)
{
    ensure_initialized();

    llvm::LLVMContext ctx;
    std::string err;

    /* Parse LLVM IR bitcode */
    auto buf = llvm::MemoryBuffer::getMemBuffer(
        llvm::StringRef(ir, ir_len), "", false);
    auto mod_or_err = llvm::parseBitcodeFile(buf->getMemBufferRef(), ctx);
    if (!mod_or_err) {
        if (error) snprintf(error, error_len, "Failed to parse LLVM IR bitcode");
        return -1;
    }

    auto module = std::move(mod_or_err.get());

    /* LLVM IR → SPIR-V */
    std::ostringstream os;
    if (!writeSpirv(module.get(), os, err)) {
        if (error) snprintf(error, error_len, "SPIRV write failed: %s", err.c_str());
        return -1;
    }

    std::string spirv_data = os.str();
    *spirv_len = spirv_data.size();
    *spirv_out = (char*)malloc(spirv_data.size());
    if (!*spirv_out) {
        if (error) snprintf(error, error_len, "Failed to allocate output buffer");
        return -1;
    }
    memcpy(*spirv_out, spirv_data.data(), spirv_data.size());
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Public API: LLVM IR → GPU code                                     */
/* ------------------------------------------------------------------ */

extern "C" int mental_mlvm_ir_to_ptx(
    const char* ir, size_t ir_len,
    char** ptx_out, size_t* ptx_len,
    char* error, size_t error_len)
{
    ensure_initialized();

    llvm::LLVMContext ctx;
    std::string err;

    auto buf = llvm::MemoryBuffer::getMemBuffer(
        llvm::StringRef(ir, ir_len), "", false);
    auto mod_or_err = llvm::parseBitcodeFile(buf->getMemBufferRef(), ctx);
    if (!mod_or_err) {
        if (error) snprintf(error, error_len, "Failed to parse LLVM IR bitcode");
        return -1;
    }

    if (emit_to_target(*mod_or_err.get(), "nvptx64-nvidia-cuda", "sm_52",
                        ptx_out, ptx_len, err) != 0) {
        if (error) snprintf(error, error_len, "%s", err.c_str());
        return -1;
    }

    return 0;
}

extern "C" int mental_mlvm_ir_to_amdgpu(
    const char* ir, size_t ir_len,
    char** code_out, size_t* code_len,
    char* error, size_t error_len)
{
    ensure_initialized();

    llvm::LLVMContext ctx;
    std::string err;

    auto buf = llvm::MemoryBuffer::getMemBuffer(
        llvm::StringRef(ir, ir_len), "", false);
    auto mod_or_err = llvm::parseBitcodeFile(buf->getMemBufferRef(), ctx);
    if (!mod_or_err) {
        if (error) snprintf(error, error_len, "Failed to parse LLVM IR bitcode");
        return -1;
    }

    if (emit_to_target(*mod_or_err.get(), "amdgcn-amd-amdhsa", "gfx900",
                        code_out, code_len, err) != 0) {
        if (error) snprintf(error, error_len, "%s", err.c_str());
        return -1;
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/*  Utility                                                            */
/* ------------------------------------------------------------------ */

extern "C" void mental_mlvm_free(char* buf) {
    free(buf);
}

extern "C" const char* mental_mlvm_version(void) {
    return LLVM_VERSION_STRING;
}
