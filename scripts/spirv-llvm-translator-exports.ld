/*
 * Linker version script (GNU ld / Linux) for libLLVMSPIRVLib.so.
 * Consumed via `-Wl,--version-script=<file>` during the shared-lib link.
 * See spirv-llvm-translator-exports.txt for rationale and pattern notes.
 */
{
    global:
        /* llvm:: symbols containing "Spirv" — writeSpirv, readSpirv,
         * regularizeLlvmForSpirv, convertSpirvToLLVM, and their
         * const-qualified variants. */
        _ZN4llvm*Spirv*;
        _ZNK4llvm*Spirv*;

        /* llvm:: symbols containing "SPIRV" — pass initializers. */
        _ZN4llvm*SPIRV*;
        _ZNK4llvm*SPIRV*;

        /* Public llvm:: entry points whose names don't embed Spirv/SPIRV
         * but ARE part of the translator's public API (LLVMSPIRVLib.h).
         * Without these, llvm-spirv's own link fails with "undefined
         * reference".  Listed explicitly to avoid broadening a pattern
         * that would expose LLVM internals. */
        _ZN4llvm*SpecConst*;         /* getSpecConstInfo + SpecConstInfoTy */
        _ZNK4llvm*SpecConst*;
        _ZN4llvm*Preprocess*Metadata*;  /* initializePreprocessMetadataLegacyPass */
        _ZNK4llvm*Preprocess*Metadata*;

        /* SPIRV:: namespace — helper classes and free functions
         * (getErrorMessage, SPIRVModule, TranslatorOpts, …).
         * Length prefix is 5 (chars in "SPIRV"), not 6 — earlier
         * bug here caused llvm-spirv's link to fail with
         * "undefined reference to SPIRV::getErrorMessage". */
        _ZN5SPIRV*;
        _ZNK5SPIRV*;

        /* C-linkage helpers if any. */
        writeSpirv*;
        readSpirv*;
        getSpirvLib*;

    local:
        *;
};
