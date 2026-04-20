/*
 * Linker version script (GNU ld / Linux) for libLLVMSPIRVLib.so.
 * Consumed via `-Wl,--version-script=<file>` during the shared-lib link.
 * See spirv-llvm-translator-exports.txt for rationale and pattern notes.
 */
{
    global:
        /* llvm:: symbols containing "Spirv" — writeSpirv, readSpirv,
         * regularizeLlvmForSpirv, and their const-qualified variants. */
        _ZN4llvm*Spirv*;
        _ZNK4llvm*Spirv*;

        /* llvm:: symbols containing "SPIRV" — pass initializers. */
        _ZN4llvm*SPIRV*;
        _ZNK4llvm*SPIRV*;

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
