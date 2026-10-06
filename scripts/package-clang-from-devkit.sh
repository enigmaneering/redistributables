#!/bin/bash
set -eu

# package-clang-from-devkit.sh — the slim clang asset from a CACHED dev kit.
#
# build-llvm.sh packages clang-<platform>.tar.gz at the end of a cold build.
# On a build-llvm cache hit no build runs, so this script makes the same
# asset from the dev kit the cache restored: it takes the members
# package-clang.sh reads out of llvm-<platform>.tar.gz (the cmake --install
# prefix's bin/ tools and lib/clang/<major>/ headers, VERSION, and the three
# license texts of the bundled src/ tree — nothing else of the ~2 GB kit
# is unpacked) and runs package-clang.sh over them, exactly as build-llvm.sh
# does over the fresh install tree. The tools are the same bytes, so the
# asset is the same asset; only tar's recorded mtimes differ.
#
# It is deliberately NOT in build-llvm's cache key (scripts/build-llvm.sh,
# common.sh, package-clang.sh): it runs only on a hit and decides nothing
# about what the cache holds.
#
# Inputs (environment; the workflow's "Package slim clang from the cached
# dev kit" steps set them, a local run sets them by hand):
#   PLATFORM     darwin-arm64 | darwin-amd64 | linux-amd64 | linux-arm64 |
#                windows-amd64 | windows-arm64 (no slim clang for wasm)   required
#   OUTPUT_DIR   where the cache restored llvm-<platform>.tar.gz; the asset
#                clang-<platform>.tar.gz and its .report.txt land here     required
#   WORK_DIR     where the needed dev kit members are extracted (outside
#                OUTPUT_DIR, so the cache and upload globs never see them) required
#   LLVM_SHA     if set, the dev kit's VERSION must equal it                optional
#   CLANG_ASSET_MAX_BYTES, PACKAGE_CLANG_STRICT   pass through to package-clang.sh
#
# Every missing input, member, tool or output is fatal and named.

say() { echo "[package-clang-from-devkit] $*"; }
die() { echo "[package-clang-from-devkit] error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- inputs
for v in PLATFORM OUTPUT_DIR WORK_DIR; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || die "$v is not set"
done
case "$PLATFORM" in
    windows-amd64|windows-arm64) EXE=".exe" ;;
    darwin-arm64|darwin-amd64|linux-amd64|linux-arm64) EXE="" ;;
    *) die "no slim clang is built for PLATFORM='$PLATFORM' (six native platforms only, no wasm)" ;;
esac
# MSYS2: ${{ runner.temp }} arrives Windows-native (D:\a\_temp); tar would
# read the drive letter's colon as host:path. common.sh does the same for
# build-llvm.sh.
case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*)
        OUTPUT_DIR="$(cygpath -u "$OUTPUT_DIR")"
        WORK_DIR="$(cygpath -u "$WORK_DIR")" ;;
esac
for t in tar gzip awk grep sed find du; do
    command -v "$t" >/dev/null 2>&1 || die "$t is not on PATH (on Windows: the cache-hit MSYS2 step installs it)"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGER="$SCRIPT_DIR/package-clang.sh"
[ -f "$PACKAGER" ] || die "$PACKAGER is missing"

KIT_NAME="llvm-$PLATFORM"
KIT="$OUTPUT_DIR/$KIT_NAME.tar.gz"
[ -f "$KIT" ] || die "$KIT is missing — the cache restored no dev kit (nothing to package from)"
say "dev kit: $KIT ($(wc -c < "$KIT" | tr -d ' ') bytes)"
for f in "$OUTPUT_DIR/clang-$PLATFORM.tar.gz" "$OUTPUT_DIR/clang-$PLATFORM.report.txt"; do
    if [ -f "$f" ]; then
        say "the cache also restored $f ($(wc -c < "$f" | tr -d ' ') bytes); it is repackaged from the dev kit below"
    fi
done

# ---------------------------------------------------------------- members
# One pass to list the kit, so every member package-clang.sh will read is
# known to be there before anything is unpacked, and so the unix clang's
# real binary (bin/clang is a link to clang-<major>; cp -L follows it) is
# named exactly — no tar wildcards, which GNU tar and bsdtar spell apart.
ROOT="$WORK_DIR/$KIT_NAME"
LIST="$WORK_DIR/$KIT_NAME.members.txt"
mkdir -p "$WORK_DIR"
rm -rf "$ROOT" "$LIST"
say "listing $KIT_NAME.tar.gz ..."
tar -tzf "$KIT" > "$LIST"
say "$(wc -l < "$LIST" | tr -d ' ') members"

MEMBERS=(
    "$KIT_NAME/VERSION"
    "$KIT_NAME/src/llvm/LICENSE.TXT"
    "$KIT_NAME/src/clang/LICENSE.TXT"
    "$KIT_NAME/src/lld/LICENSE.TXT"
    "$KIT_NAME/bin/clang$EXE"
    "$KIT_NAME/bin/lld$EXE"
    "$KIT_NAME/bin/llvm-objdump$EXE"
    "$KIT_NAME/bin/llvm-strip$EXE"
)
# Windows: package-clang.sh reads the asset's DLL imports with the kit's
# llvm-readobj.exe, else a PATH llvm-readobj, else objdump. On a cache hit
# no MinGW toolchain is installed, so neither fallback exists and the
# "system libraries only" check would pass on an empty list; the kit's
# own copy is therefore required here, not optional (every kit has it:
# cmake installs llvm-readobj.exe beside llvm-objcopy.exe).
if [ -n "$EXE" ]; then
    MEMBERS+=("$KIT_NAME/bin/llvm-readobj$EXE")
fi
MISSING=""
for m in "${MEMBERS[@]}" "$KIT_NAME/lib/clang/"; do
    grep -qxF "$m" "$LIST" || MISSING="$MISSING $m"
done
[ -z "$MISSING" ] || die "the dev kit lacks:$MISSING"
# The directory member: tar extracts the subtree (lib/clang/<major>/include).
MEMBERS+=("$KIT_NAME/lib/clang")
# Format-dependent extras package-clang.sh reaches for when present: the
# unix link targets (llvm-strip → llvm-objcopy, llvm-readelf → llvm-readobj)
# and the readers it uses for the dependency and glibc checks.
EXTRAS=("$KIT_NAME/bin/llvm-objcopy$EXE" "$KIT_NAME/bin/llvm-readelf$EXE")
[ -n "$EXE" ] || EXTRAS+=("$KIT_NAME/bin/llvm-readobj$EXE")   # required above on Windows
for m in "${EXTRAS[@]}"; do
    if grep -qxF "$m" "$LIST"; then MEMBERS+=("$m"); fi
done
if [ -z "$EXE" ]; then
    REAL="$(grep -E "^$KIT_NAME/bin/clang-[0-9]+$" "$LIST" || true)"
    [ -n "$REAL" ] || die "the dev kit has no bin/clang-<major> (on unix bin/clang is a link to it)"
    [ "$(echo "$REAL" | wc -l | tr -d ' ')" -eq 1 ] || die "more than one bin/clang-<major> in the dev kit: $(echo "$REAL" | tr '\n' ' ')"
    MEMBERS+=("$REAL")
fi
say "extracting ${#MEMBERS[@]} members under $WORK_DIR:"
printf '  %s\n' "${MEMBERS[@]}"

# ---------------------------------------------------------------- extract
tar -xzf "$KIT" -C "$WORK_DIR" "${MEMBERS[@]}"
[ -d "$ROOT/bin" ] || die "$ROOT/bin did not land"
[ -d "$ROOT/lib/clang" ] || die "$ROOT/lib/clang did not land"
[ -f "$ROOT/src/llvm/LICENSE.TXT" ] || die "$ROOT/src/llvm/LICENSE.TXT did not land"
[ -e "$ROOT/bin/clang$EXE" ] || die "$ROOT/bin/clang$EXE did not land"
LLVM_TAG="$(tr -d '\r\n ' < "$ROOT/VERSION")"
[ -n "$LLVM_TAG" ] || die "$ROOT/VERSION is empty"
if [ -n "${LLVM_SHA:-}" ] && [ "$LLVM_TAG" != "$LLVM_SHA" ]; then
    die "the dev kit's VERSION is $LLVM_TAG but this build pins LLVM $LLVM_SHA"
fi
say "extracted $(du -sk "$ROOT" | awk '{print $1}') KiB; VERSION $LLVM_TAG"
ls -la "$ROOT/bin"

# ---------------------------------------------------------------- package
say "running package-clang.sh (LLVM_INSTALL_DIR=$ROOT, LLVM_SOURCE_DIR=$ROOT/src, PLATFORM=$PLATFORM, OUTPUT_DIR=$OUTPUT_DIR, cap ${CLANG_ASSET_MAX_BYTES:-<script default>})"
LLVM_INSTALL_DIR="$ROOT" \
LLVM_SOURCE_DIR="$ROOT/src" \
PLATFORM="$PLATFORM" \
LLVM_TAG="$LLVM_TAG" \
OUTPUT_DIR="$OUTPUT_DIR" \
bash "$PACKAGER"

# The two files the "Upload slim clang" step globs for.
for f in "$OUTPUT_DIR/clang-$PLATFORM.tar.gz" "$OUTPUT_DIR/clang-$PLATFORM.report.txt"; do
    [ -s "$f" ] || die "$f was not produced"
done
say "done: $OUTPUT_DIR/clang-$PLATFORM.tar.gz ($(wc -c < "$OUTPUT_DIR/clang-$PLATFORM.tar.gz" | tr -d ' ') bytes) and clang-$PLATFORM.report.txt"
