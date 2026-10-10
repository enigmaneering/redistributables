#!/bin/bash
set -e

# package-clang.sh — the slim pinned toolchain that `e fetch clang` installs
# (enigmatic's M6a; gameplan DR-12 / §8).
#
# Assembles clang-<platform>.tar.gz from the LLVM install tree build-llvm.sh
# just produced — the SAME ninja/make tree as the llvm-<platform> dev kit, so
# the compiler e drives on every host is byte-for-byte the one this release
# was built from — verifies it, and writes clang-<platform>.report.txt with
# the numbers the owner needs (asset size, stripped tool sizes, backends,
# dynamic dependencies, glibc / macOS floors).
#
# Inputs (environment; build-llvm.sh sets them, a local run sets them by hand):
#   LLVM_INSTALL_DIR  the cmake --install prefix (…/output/llvm-<platform>)       required
#   LLVM_SOURCE_DIR   the llvm-project checkout (llvm/, clang/, lld/ LICENSE.TXT)  required
#   PLATFORM          darwin-arm64 | darwin-amd64 | linux-amd64 | linux-arm64 |
#                     linux-riscv64 | windows-amd64 | windows-arm64
#                     (no slim clang for wasm)                                      required
#   LLVM_TAG          the LLVM commit that was built; becomes VERSION              required
#   OUTPUT_DIR        where clang-<platform>.tar.gz and .report.txt land            required
#   LLVM_NATIVE_TOOLS_DIR  a bin/ of host-native LLVM tools (build-llvm.sh's
#                     Phase 1, or a kit's native/bin): preferred for stripping
#                     and reading the asset when the install tree's own tools
#                     are the target's, as on the cross platform               optional
#   PACKAGE_CLANG_REQUIRE_EXEC  1: a bin/clang this host cannot execute is a
#                     failure, not a skipped check - the cross leg runs the
#                     asset under qemu-user and must prove it starts; default 0
#   CLANG_ASSET_MAX_BYTES  cap for the tarball; default 104857600 (100 MiB, the
#                     gameplan's figure — the report prints the real number so
#                     e's doctor text can say what was measured)
#   PACKAGE_CLANG_STRICT   1 (default): any failed verification fails the script;
#                     0: verifications only warn (local experiments)
#
# The asset's layout — the contract e's fetch (archive root clang-<platform>/,
# stripped to <external>/clang/) and toolchain ladder (rung 2:
# <external>/clang/bin/clang, llvm-objdump beside it, lld beside it) read:
#
#   clang-<platform>/
#     bin/clang[.exe]            the real driver binary. On unix cmake installs
#                                the file as clang-<major> with clang as a
#                                symlink; the asset ships the file under the
#                                name e calls and nothing under the other.
#     bin/clang++                unix only, symlink → clang
#     bin/lld[.exe]              the real lld driver (every flavor lives in it)
#     bin/ld.lld, bin/wasm-ld    unix only, symlinks → lld: lld picks its flavor
#                                from argv[0], and clang's own -fuse-ld=lld
#                                looks for exactly these names beside itself
#     bin/llvm-objdump[.exe]     e's second decoder (DR-13)
#     lib/clang/<major>/include/ the builtin headers (<stdint.h>, <stddef.h>, …)
#                                that -ffreestanding -nostdlib still includes;
#                                clang finds them at realpath(argv[0])/../lib/clang/<major>
#     VERSION                    the LLVM commit (= LLVM_TAG)
#     LICENSES/LLVM-LICENSE.TXT, Clang-LICENSE.TXT, LLD-LICENSE.TXT
#
# Windows ships NO links at all (MSYS2's ln -s degrades to a copy, and e's
# fetch refuses zip symlinks anyway): one clang.exe, one lld.exe, one
# llvm-objdump.exe. e links wasm there as `lld.exe -flavor wasm`.
# Symlinks rather than copies on unix: a statically linked clang is ~150 MB
# and lld ~80 MB, so copies would triple the tarball (gzip's window never
# spans two files) for names e itself never calls. e's fetch materialises
# links as copies after extraction; teaching it os.Symlink on unix is e's
# side of this contract.
#
# Nothing else is shipped: no clang-cl/clang-cpp/clang-dxc, no lld-link/
# ld64.lld, no llvm-mc/llvm-readobj/llvm-ar (e references none of them —
# grep over enigmatic's Go: only clang, wasm-ld and llvm-objdump), no
# compiler-rt (the dialect is freestanding: -ffreestanding -nostdlib
# -fno-builtin, every undefined symbol is a dialect error).

# ---------------------------------------------------------------- helpers
STRICT="${PACKAGE_CLANG_STRICT:-1}"
FAILURES=0
REPORT_LINES=""

say()  { echo "[package-clang] $*"; }
die()  { echo "[package-clang] error: $*" >&2; exit 1; }
warn() { echo "[package-clang] warning: $*" >&2; }
# fail: a verification that did not hold. Fatal unless PACKAGE_CLANG_STRICT=0.
fail() {
    FAILURES=$((FAILURES + 1))
    if [ "$STRICT" = "0" ]; then
        echo "[package-clang] VERIFY FAILED (non-strict, continuing): $*" >&2
    else
        echo "[package-clang] VERIFY FAILED: $*" >&2
    fi
}
pass() { echo "[package-clang] verified: $*"; }
report() { REPORT_LINES="${REPORT_LINES}$*
"; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else die "neither sha256sum nor shasum is available"; fi
}
bytes_of() { wc -c < "$1" | tr -d ' '; }
mib_of()   { echo "$(( $1 / 1048576 )).$(( ($1 % 1048576) * 10 / 1048576 ))"; }
lower()    { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------- inputs
for v in LLVM_INSTALL_DIR LLVM_SOURCE_DIR PLATFORM LLVM_TAG OUTPUT_DIR; do
    eval "val=\$$v"
    [ -n "$val" ] || die "$v is not set"
done
[ -d "$LLVM_INSTALL_DIR/bin" ] || die "LLVM_INSTALL_DIR=$LLVM_INSTALL_DIR has no bin/"
[ -f "$LLVM_SOURCE_DIR/llvm/LICENSE.TXT" ] || die "LLVM_SOURCE_DIR=$LLVM_SOURCE_DIR has no llvm/LICENSE.TXT"
mkdir -p "$OUTPUT_DIR"

case "$PLATFORM" in
    windows-amd64|windows-arm64) EXE=".exe"; LINKS=0 ;;
    darwin-arm64|darwin-amd64|linux-amd64|linux-arm64|linux-riscv64) EXE=""; LINKS=1 ;;
    *) die "no slim clang is built for PLATFORM='$PLATFORM' (seven native platforms only, no wasm)" ;;
esac
case "$(uname -s)" in
    Darwin) HOST=darwin ;;
    Linux)  HOST=linux ;;
    MSYS*|MINGW*|CYGWIN*) HOST=windows ;;
    *) HOST=unknown ;;
esac
# A Linux asset of another architecture than this host's (linux-riscv64 on
# ubuntu-latest): its tools run here only under qemu-user, and the reads that
# ldd cannot do on a foreign binary go through llvm-readobj instead.
CROSS=0
if [ "$HOST" = linux ]; then
    case "$PLATFORM" in
        linux-*) [ "${PLATFORM#linux-}" = "$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')" ] || CROSS=1 ;;
    esac
fi
NATIVE_TOOLS="${LLVM_NATIVE_TOOLS_DIR:-}"
REQUIRE_EXEC="${PACKAGE_CLANG_REQUIRE_EXEC:-0}"
CAP="${CLANG_ASSET_MAX_BYTES:-104857600}"

NAME="clang-$PLATFORM"
STAGE="$OUTPUT_DIR/$NAME"
TARBALL="$OUTPUT_DIR/$NAME.tar.gz"
REPORT="$OUTPUT_DIR/$NAME.report.txt"

say "packaging $NAME from $LLVM_INSTALL_DIR (LLVM $LLVM_TAG, host $HOST$([ "$CROSS" -eq 1 ] && echo ", cross: the asset runs here under qemu-user"))"

# The resource directory: exactly one lib/clang/<major>/include is expected.
MAJOR=""
for d in "$LLVM_INSTALL_DIR"/lib/clang/*/; do
    d="${d%/}"
    [ -d "$d/include" ] || continue
    [ -z "$MAJOR" ] || die "more than one lib/clang/<ver>/include under $LLVM_INSTALL_DIR"
    MAJOR="${d##*/}"
done
[ -n "$MAJOR" ] || die "no lib/clang/<ver>/include under $LLVM_INSTALL_DIR — was clang installed?"
say "clang resource directory: lib/clang/$MAJOR"

# ---------------------------------------------------------------- stage
rm -rf "$STAGE" "$TARBALL" "$REPORT"
mkdir -p "$STAGE/bin" "$STAGE/lib/clang/$MAJOR" "$STAGE/LICENSES"

# One real file per tool. cp -L follows the unix clang → clang-<major> link so
# the asset carries the binary under the name e calls, never a dangling link.
copy_tool() {
    local src="$LLVM_INSTALL_DIR/bin/$1$EXE" dst="$STAGE/bin/$1$EXE"
    [ -e "$src" ] || die "$src is missing (is \"$1\" built? lld needs LLVM_ENABLE_PROJECTS=clang;lld)"
    cp -L "$src" "$dst"
    chmod 0755 "$dst"
}
copy_tool clang
copy_tool lld
copy_tool llvm-objdump

if [ "$LINKS" -eq 1 ]; then
    ( cd "$STAGE/bin" && ln -s clang clang++ && ln -s lld ld.lld && ln -s lld wasm-ld )
fi

cp -R "$LLVM_INSTALL_DIR/lib/clang/$MAJOR/include" "$STAGE/lib/clang/$MAJOR/include"
[ -f "$STAGE/lib/clang/$MAJOR/include/stdint.h" ] || die "builtin stdint.h did not land in the asset"
[ -f "$STAGE/lib/clang/$MAJOR/include/stddef.h" ] || die "builtin stddef.h did not land in the asset"

printf '%s\n' "$LLVM_TAG" > "$STAGE/VERSION"

# Licenses are hard copies: Apache-2.0 WITH LLVM-exception §4(a) binds the
# binary redistribution (the exception only waives it for compiler OUTPUT),
# and the verify-licenses job hashes the same three source files.
cp "$LLVM_SOURCE_DIR/llvm/LICENSE.TXT"  "$STAGE/LICENSES/LLVM-LICENSE.TXT"
cp "$LLVM_SOURCE_DIR/clang/LICENSE.TXT" "$STAGE/LICENSES/Clang-LICENSE.TXT"
cp "$LLVM_SOURCE_DIR/lld/LICENSE.TXT"   "$STAGE/LICENSES/LLD-LICENSE.TXT"

# ---------------------------------------------------------------- strip
# A host-native llvm-strip first when one was handed over (the cross leg's
# Phase 1 tools: the tree's own would run under qemu), then the tree's own
# llvm-strip (one tool, three object formats, always present because
# llvm-objcopy is in LLVM's default build; verified locally to leave an arm64
# Mach-O ad-hoc signature valid), then a PATH llvm-strip, then GNU strip,
# then Apple's strip (no --version, no --strip-all).
STRIP=""
STRIP_KIND=""
for cand in "${NATIVE_TOOLS:+$NATIVE_TOOLS/llvm-strip}" "$LLVM_INSTALL_DIR/bin/llvm-strip$EXE" "$(command -v llvm-strip 2>/dev/null || true)" "$(command -v strip 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if "$cand" --version >/dev/null 2>&1; then
        STRIP="$cand"
        case "$("$cand" --version 2>/dev/null | head -1)" in
            *LLVM*|*llvm-strip*) STRIP_KIND=llvm ;;
            *) STRIP_KIND=gnu ;;
        esac
        break
    elif [ "$HOST" = darwin ] && [ "$(basename "$cand")" = strip ]; then
        STRIP="$cand"; STRIP_KIND=apple
        break
    fi
done
[ -n "$STRIP" ] || die "no usable strip found (tried the install tree's llvm-strip, PATH llvm-strip, strip)"
say "stripping with $STRIP ($STRIP_KIND)"
for tool in clang lld llvm-objdump; do
    f="$STAGE/bin/$tool$EXE"
    before=$(bytes_of "$f")
    case "$STRIP_KIND" in
        llvm|gnu) "$STRIP" --strip-all "$f" ;;
        apple)    "$STRIP" "$f" ;;
    esac
    after=$(bytes_of "$f")
    say "  $tool$EXE: $before → $after bytes"
    report "tool $tool$EXE: $after bytes stripped (was $before)"
done

# macOS: an arm64 Mach-O must carry a valid (ad-hoc is enough) signature or
# the kernel kills it; stripping rewrites the file, so re-sign ad hoc and
# verify. Harmless for x86_64 slices.
if [ "$HOST" = darwin ]; then
    for tool in clang lld llvm-objdump; do
        f="$STAGE/bin/$tool$EXE"
        codesign --force --sign - "$f" >/dev/null 2>&1 || die "codesign --sign - failed on $f"
        codesign --verify "$f" || die "codesign --verify failed on $f"
    done
    say "ad-hoc signed bin/clang$EXE bin/lld$EXE bin/llvm-objdump$EXE"
fi

# ---------------------------------------------------------------- verify
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CLANG="$STAGE/bin/clang$EXE"
LLD="$STAGE/bin/lld$EXE"
OBJDUMP="$STAGE/bin/llvm-objdump$EXE"

# Can this host execute the asset at all? darwin-amd64 is cross-built on an
# arm64 runner and needs Rosetta; without it bash reports 126. Everything
# that does not need to run the binaries is still checked.
CAN_RUN=1
set +e
"$CLANG" --version > "$TMP/version.txt" 2>&1
rc=$?
set -e
if [ $rc -eq 126 ] && [ "$REQUIRE_EXEC" = "1" ]; then
    cat "$TMP/version.txt" >&2
    fail "bin/clang cannot execute on this host (exit 126) and PACKAGE_CLANG_REQUIRE_EXEC=1: is qemu-user-static installed and QEMU_LD_PREFIX (${QEMU_LD_PREFIX:-unset}) the cross libc?"
    CAN_RUN=0
elif [ $rc -eq 126 ]; then
    CAN_RUN=0
    warn "bin/clang cannot execute on this host (exit 126: foreign architecture, no Rosetta?) — skipping the execution checks"
    report "execution checks: SKIPPED (cannot run $PLATFORM binaries on this host)"
elif [ $rc -ne 0 ]; then
    cat "$TMP/version.txt" >&2
    fail "bin/clang --version exited $rc"
    CAN_RUN=0
fi

if [ "$CAN_RUN" -eq 1 ]; then
    VERSION_LINE="$(head -1 "$TMP/version.txt")"
    report "clang --version: $VERSION_LINE"
    case "$VERSION_LINE" in
        *"clang version"*) pass "bin/clang --version: $VERSION_LINE" ;;
        *) fail "bin/clang --version first line is not a clang version line: $VERSION_LINE" ;;
    esac
    # LLVM_APPEND_VC_REV=ON with LLVM_FORCE_VC_REPOSITORY/REVISION (build-llvm.sh)
    # put exactly "(https://github.com/llvm/llvm-project.git <sha>)" into the
    # version line, which is how e.json and every generated header name the pin
    # by themselves - and what a blocking drift gate compares byte for byte, so
    # the whole parenthesis is held, not just the commit: a build that let git
    # answer instead reports the URL as the builder's git config rewrites it
    # (ssh://git@github.com/… on a host with url.<base>.insteadOf).
    IDENTITY="(https://github.com/llvm/llvm-project.git $LLVM_TAG)"
    case "$VERSION_LINE" in
        *"$IDENTITY") pass "the version line ends with $IDENTITY" ;;
        *"$LLVM_TAG"*) fail "bin/clang --version names the commit but not as $IDENTITY (LLVM_FORCE_VC_REPOSITORY unset? git answered with the builder's URL): $VERSION_LINE" ;;
        *) fail "bin/clang --version does not mention $LLVM_TAG (LLVM_APPEND_VC_REV off, or LLVM_FORCE_VC_REVISION unset?): $(cat "$TMP/version.txt" | tr '\n' ' ')" ;;
    esac

    # Every backend an e target names (enigmatic internal/targets/targets.go).
    "$CLANG" -print-targets > "$TMP/targets.txt" 2>&1 || fail "bin/clang -print-targets exited $?"
    MISSING=""
    for b in x86-64 x86 aarch64 arm riscv64 loongarch64 ppc64 ppc64le systemz wasm32 wasm64 nvptx64 amdgcn spirv64; do
        grep -qE "^[[:space:]]+$b[[:space:]]+-" "$TMP/targets.txt" || MISSING="$MISSING $b"
    done
    if [ -z "$MISSING" ]; then
        pass "-print-targets lists every e backend"
    else
        fail "-print-targets lacks:$MISSING (LLVM_TARGETS_TO_BUILD / LLVM_EXPERIMENTAL_TARGETS_TO_BUILD?)"
    fi
    BACKENDS="$(grep -E '^[[:space:]]+[a-z0-9_-]+[[:space:]]+-' "$TMP/targets.txt" | awk '{print $1}' | tr '\n' ' ')"
    report "backends ($(echo "$BACKENDS" | wc -w | tr -d ' ')): $BACKENDS"

    # The resource dir must be the asset's own lib/clang/<major>: the driver
    # derives it from realpath(argv[0])/../lib/clang/<major>, so a copied or
    # relocated bin/clang finds its headers wherever the asset is unpacked.
    RES="$("$CLANG" -print-resource-dir 2>/dev/null | tr -d '\r' | tr '\\' '/')"
    case "$RES" in
        */"$NAME"/lib/clang/"$MAJOR") pass "-print-resource-dir is the asset's lib/clang/$MAJOR" ;;
        *) fail "-print-resource-dir is '$RES', expected …/$NAME/lib/clang/$MAJOR" ;;
    esac

    # Freestanding compiles with the builtin headers, for every triple an e
    # target uses (Go, native, elf, wasm families), the way e compiles:
    # -ffreestanding -nostdlib -fno-builtin and <stdint.h>/<stddef.h> included.
    cat > "$TMP/probe.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>
uint64_t e_probe(const uint8_t *p, size_t n) {
    uint64_t acc = 0;
    for (size_t i = 0; i < n; i++) acc = acc * 31u + p[i];
    return acc;
}
EOF
    PROBE_MODE="-c"
    probe() { # <triple> <output> [extra flags...]; PROBE_MODE is -c (object) or -S (assembly text)
        local triple="$1" out="$2"; shift 2
        "$CLANG" --target="$triple" -ffreestanding -nostdlib -fno-builtin -O2 "$@" "$PROBE_MODE" -x c "$TMP/probe.c" -o "$out" > "$TMP/probe.log" 2>&1
    }
    for triple in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu riscv64-unknown-linux-gnu \
                  loongarch64-unknown-linux-gnu powerpc64le-unknown-linux-gnu powerpc64-unknown-linux-gnu \
                  s390x-unknown-linux-gnu i386-unknown-linux-gnu armv7-unknown-linux-gnueabihf \
                  x86_64-apple-macos arm64-apple-macos x86_64-pc-windows-gnu aarch64-pc-windows-gnu \
                  x86_64-elf aarch64-none-elf riscv64-unknown-elf \
                  wasm32-unknown-unknown wasm64-unknown-unknown; do
        if probe "$triple" "$TMP/probe-$triple.o"; then
            pass "freestanding compile for $triple"
        else
            cat "$TMP/probe.log" >&2
            fail "freestanding compile for $triple failed"
        fi
    done
    # The GPU triples are e's deferred tier: proven to compile, but not fatal.
    # nvptx64 is text-only (e's gpu/ptx target emits .ptx with -march=sm_80);
    # -c there would call ptxas, which only a CUDA toolkit provides.
    for triple in nvptx64-nvidia-cuda amdgcn-amd-amdhsa spirv64; do
        extra=""; PROBE_MODE="-c"
        if [ "$triple" = nvptx64-nvidia-cuda ]; then extra="-march=sm_80"; PROBE_MODE="-S"; fi
        if probe "$triple" "$TMP/probe-$triple.out" $extra; then
            pass "freestanding compile for $triple (gpu tier)"
        else
            warn "freestanding compile for $triple failed (gpu tier, not fatal): $(tail -1 "$TMP/probe.log")"
        fi
    done
    PROBE_MODE="-c"

    # The second decoder reads what the first emitted (DR-13).
    if "$OBJDUMP" --version 2>/dev/null | grep -q LLVM; then
        pass "bin/llvm-objdump identifies as LLVM: $("$OBJDUMP" --version | head -1)"
        report "llvm-objdump --version: $("$OBJDUMP" --version | head -1)"
    else
        fail "bin/llvm-objdump --version does not say LLVM"
    fi
    for arch in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
        if "$OBJDUMP" -d "$TMP/probe-$arch.o" 2>/dev/null | grep -q "e_probe"; then
            pass "llvm-objdump disassembles the $arch object"
        else
            fail "llvm-objdump -d could not disassemble the $arch object"
        fi
    done

    # lld: the flavor e names on Windows, and the names e finds on unix.
    if "$LLD" -flavor wasm --version 2>/dev/null | grep -q LLD; then
        pass "bin/lld -flavor wasm --version: $("$LLD" -flavor wasm --version | head -1)"
        report "lld -flavor wasm --version: $("$LLD" -flavor wasm --version | head -1)"
    else
        fail "bin/lld -flavor wasm --version does not say LLD"
    fi
    link_wasm() { # <linker...> -- links the wasm32 probe object, checks the magic
        "$@" --no-entry --export=e_probe -o "$TMP/probe.wasm" "$TMP/probe-wasm32-unknown-unknown.o" > "$TMP/link.log" 2>&1 || return 1
        [ "$(od -An -tx1 -N4 "$TMP/probe.wasm" | tr -d ' \n')" = "0061736d" ]
    }
    if link_wasm "$LLD" -flavor wasm; then
        pass "lld -flavor wasm links a wasm32 module"
    else
        cat "$TMP/link.log" >&2
        fail "lld -flavor wasm could not link the wasm32 probe"
    fi
    if [ "$LINKS" -eq 1 ]; then
        if link_wasm "$STAGE/bin/wasm-ld"; then
            pass "bin/wasm-ld (symlink) links a wasm32 module"
        else
            cat "$TMP/link.log" >&2
            fail "bin/wasm-ld could not link the wasm32 probe"
        fi
        if "$STAGE/bin/ld.lld" --version 2>/dev/null | grep -q LLD; then
            pass "bin/ld.lld (symlink) identifies as LLD"
        else
            fail "bin/ld.lld --version does not say LLD"
        fi
        if "$STAGE/bin/clang++" --version 2>/dev/null | head -1 | grep -q "clang version"; then
            pass "bin/clang++ (symlink) runs"
        else
            fail "bin/clang++ --version failed"
        fi
    fi
fi

# Links: exactly the unix set, none on Windows.
if [ "$LINKS" -eq 1 ]; then
    for l in clang++:clang ld.lld:lld wasm-ld:lld; do
        n="${l%%:*}"; t="${l##*:}"
        if [ -L "$STAGE/bin/$n" ] && [ "$(readlink "$STAGE/bin/$n")" = "$t" ]; then
            pass "bin/$n → $t"
        else
            fail "bin/$n is not a symlink to $t"
        fi
    done
else
    if [ -n "$(find "$STAGE" -type l 2>/dev/null)" ]; then
        fail "the Windows asset contains symlinks: $(find "$STAGE" -type l | tr '\n' ' ')"
    else
        pass "no links in the Windows asset"
    fi
fi

# Dynamic dependencies: system libraries only. The whole point of the asset
# is to run on a host with nothing installed — no MSYS2 DLLs, no Homebrew
# dylibs, no distro libstdc++ of a particular release.
deps_of() { # prints one dependency name per line for the host's format
    case "$HOST" in
        darwin)
            otool -L "$1" | tail -n +2 | awk '{print $1}' ;;
        linux)
            if [ "$CROSS" -eq 1 ]; then
                # ldd cannot follow a foreign binary; the DT_NEEDED list is the
                # same question asked of the ELF itself. Transitive needs of
                # libc are libc's own business on the target.
                local ro=""
                for cand in "${NATIVE_TOOLS:+$NATIVE_TOOLS/llvm-readobj}" "$LLVM_INSTALL_DIR/bin/llvm-readobj" "$(command -v llvm-readobj 2>/dev/null || true)"; do
                    [ -n "$cand" ] && [ -x "$cand" ] && "$cand" --version >/dev/null 2>&1 && { ro="$cand"; break; }
                done
                [ -n "$ro" ] || die "no llvm-readobj to read the dependencies of a $PLATFORM binary on this host"
                "$ro" --needed-libs "$1" | grep -E '^[[:space:]]+[^[:space:]]+\.so' | awk '{print $1}'
            else
                ldd "$1" 2>/dev/null | awk '{print $1}' | grep -v '^statically'
            fi ;;
        windows)
            local ro="$LLVM_INSTALL_DIR/bin/llvm-readobj$EXE"
            [ -x "$ro" ] || ro="$(command -v llvm-readobj 2>/dev/null || true)"
            if [ -n "$ro" ]; then
                "$ro" --coff-imports "$1" | grep -E '^[[:space:]]+Name: ' | awk '{print $2}'
            else
                objdump -p "$1" | grep 'DLL Name:' | awk '{print $3}'
            fi ;;
        *) echo "" ;;
    esac
}
allowed_dep() {
    local d; d="$(lower "$1")"
    case "$HOST" in
        darwin)  case "$d" in /usr/lib/*|/system/*) return 0 ;; esac ;;
        linux)   case "$d" in
                     linux-vdso.so.*|libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|libgcc_s.so.1) return 0 ;;
                     ld-linux*.so.*|/lib/ld-linux*.so.*|/lib64/ld-linux*.so.*|/lib/ld-*.so.*) return 0 ;;
                 esac ;;
        windows) case "$d" in
                     kernel32.dll|user32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|ws2_32.dll|version.dll|psapi.dll|dbghelp.dll|bcrypt.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|rpcrt4.dll|crypt32.dll|shlwapi.dll) return 0 ;;
                     # winhttp.dll ships with every Windows since XP (System32); LLVM
                     # main's llvm/lib/HTTP has a WinHTTP backend for debuginfod, which
                     # llvm-objdump links - the v0.0.84 build failed here on it.
                     winhttp.dll) return 0 ;;
                     api-ms-win-*.dll|ext-ms-win-*.dll) return 0 ;;
                 esac ;;
    esac
    return 1
}
if [ "$HOST" != unknown ]; then
    for tool in clang lld llvm-objdump; do
        f="$STAGE/bin/$tool$EXE"
        DEPS="$(deps_of "$f" | tr -d '\r')"
        report "dynamic deps of $tool$EXE: $(echo "$DEPS" | tr '\n' ' ')"
        BAD=""
        for d in $DEPS; do
            allowed_dep "$d" || BAD="$BAD $d"
        done
        if [ -z "$BAD" ]; then
            pass "$tool$EXE links system libraries only"
        else
            fail "$tool$EXE links non-system libraries:$BAD (the tool would not start on a host without them)"
        fi
    done
    case "$HOST" in
        linux)
            RE="$LLVM_INSTALL_DIR/bin/llvm-readelf"
            if [ -n "$NATIVE_TOOLS" ] && [ -x "$NATIVE_TOOLS/llvm-readelf" ]; then RE="$NATIVE_TOOLS/llvm-readelf"; fi
            if [ -x "$RE" ] && "$RE" --version >/dev/null 2>&1; then
                FLOOR="$("$RE" --dyn-syms "$CLANG" | grep -o 'GLIBC_[0-9][0-9.]*' | sort -uV | tail -1)"
            else
                FLOOR="$(objdump -T "$CLANG" | grep -o 'GLIBC_[0-9][0-9.]*' | sort -uV | tail -1)"
            fi
            say "highest glibc symbol version referenced by bin/clang: ${FLOOR:-none}"
            report "glibc floor (highest GLIBC_ version referenced): ${FLOOR:-none}" ;;
        darwin)
            MINOS="$(otool -l "$CLANG" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
            say "macOS deployment floor (LC_BUILD_VERSION minos): ${MINOS:-unknown}"
            report "macOS floor (minos): ${MINOS:-unknown}" ;;
    esac
fi

# ---------------------------------------------------------------- tarball
# gzip, not xz: e's fetch has no third-party decompressor by design. Root
# directory clang-<platform> is what fetch strips to <external>/clang.
# On macOS, bsdtar would record every file's xattrs (com.apple.provenance,
# quarantine) as PAX headers that GNU tar then warns about on every entry;
# the asset carries none of that.
if [ "$HOST" = darwin ]; then
    ( cd "$OUTPUT_DIR" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -cf - "$NAME" | gzip -9 > "$TARBALL" )
else
    ( cd "$OUTPUT_DIR" && tar -cf - "$NAME" | gzip -9 > "$TARBALL" )
fi
SIZE=$(bytes_of "$TARBALL")
SHA=$(sha256_of "$TARBALL")
UNCOMPRESSED=$(du -sk "$STAGE" | awk '{print $1}')
say "created $TARBALL: $SIZE bytes ($(mib_of "$SIZE") MiB gzip; $UNCOMPRESSED KiB unpacked), sha256 $SHA"

LIST="$(tar -tzf "$TARBALL")"
for need in "$NAME/VERSION" "$NAME/bin/clang$EXE" "$NAME/bin/lld$EXE" "$NAME/bin/llvm-objdump$EXE" \
            "$NAME/LICENSES/LLVM-LICENSE.TXT" "$NAME/LICENSES/Clang-LICENSE.TXT" "$NAME/LICENSES/LLD-LICENSE.TXT" \
            "$NAME/lib/clang/$MAJOR/include/stdint.h" "$NAME/lib/clang/$MAJOR/include/stddef.h"; do
    echo "$LIST" | grep -qx "$need" || fail "tarball lacks $need"
done
if [ "$LINKS" -eq 0 ] && tar -tvzf "$TARBALL" | grep -q ' -> '; then
    fail "the Windows tarball carries link entries"
fi
if [ "$SIZE" -gt "$CAP" ]; then
    fail "$NAME.tar.gz is $SIZE bytes, over the cap CLANG_ASSET_MAX_BYTES=$CAP"
else
    pass "$NAME.tar.gz is $SIZE bytes (cap $CAP)"
fi

# ---------------------------------------------------------------- report
{
    echo "asset: $NAME.tar.gz"
    echo "platform: $PLATFORM (packaged on $HOST, $(uname -m))"
    echo "llvm: $LLVM_TAG"
    echo "resource dir: lib/clang/$MAJOR"
    echo "tarball bytes: $SIZE ($(mib_of "$SIZE") MiB)"
    echo "tarball sha256: $SHA"
    echo "unpacked KiB: $UNCOMPRESSED"
    echo "cap bytes: $CAP"
    echo "verification failures: $FAILURES (strict=$STRICT)"
    printf '%s' "$REPORT_LINES"
    echo "contents:"
    echo "$LIST" | sed 's/^/  /'
} > "$REPORT"
cat "$REPORT"

if [ "$FAILURES" -ne 0 ]; then
    if [ "$STRICT" = "0" ]; then
        warn "$FAILURES verification(s) failed; PACKAGE_CLANG_STRICT=0 so the asset was still written"
    else
        rm -f "$TARBALL"
        die "$FAILURES verification(s) failed; $NAME.tar.gz removed"
    fi
fi
say "done: $TARBALL"
