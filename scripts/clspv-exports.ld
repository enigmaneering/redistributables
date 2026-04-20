/*
 * Linker version script (GNU ld / Linux) for libclspv_core.so.
 * Consumed via `-Wl,--version-script=<file>` during the shared-lib link.
 * See clspv-exports.txt for the darwin equivalent and rationale.
 *
 * Wildcards have ld-glob semantics (not shell): * matches any character
 * sequence including empty; ? matches a single character; [abc] classes
 * are supported.  Mangled C++ names are matched directly (GNU ld version
 * scripts don't need the leading underscore that mach-o requires).
 */
{
    global:
        /* C API */
        clspv*;

        /* C++ namespace clspv:: */
        _ZN5clspv*;
        _ZNK5clspv*;

    local:
        *;
};
