#!/bin/bash
set -e

# Build LLVM + Clang (+ LLD on the native platforms) for libmental.
# Produces the llvm-<platform> dev kit (static archives, headers, tools and the
# full source tree) that clspv and spirv-llvm-translator build against, and —
# on the six native platforms — the slim clang-<platform> asset that
# enigmatic's `e fetch clang` installs (scripts/package-clang.sh, from the
# SAME build tree, so e's compiler on every host is this release's compiler).

. "$(dirname "$0")/common.sh"

echo "Building llvm for $PLATFORM ($NCPU jobs)..."

if [ -z "$CMAKE" ]; then echo "Error: cmake not found"; exit 1; fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Resolve which LLVM commit to build. Policy: track whatever clspv pins in
# its deps.json. clspv tracks LLVM main (no stable tags), uses bleeding-edge
# intrinsics, and drives the rest of our cross-compile stack (spirv-llvm-
# translator also tracks main to match). Pinning to clspv keeps the whole
# chain coherent without us manually bumping versions — when clspv updates
# deps.json we pick up the new SHA on the next build.
#
# Resolution order:
#   1. $LLVM_SHA env var (set by CI; exposed to the cache key so bumps
#      invalidate correctly)
#   2. clspv's deps.json (for local dev — same source CI consults)
#   3. latest llvmorg-* release tag (last-resort fallback)
if [ -z "$LLVM_TAG" ]; then LLVM_TAG="$LLVM_SHA"; fi
if [ -z "$LLVM_TAG" ] && [ -n "$PYTHON" ]; then
    echo "Resolving LLVM SHA from clspv's deps.json..."
    LLVM_TAG=$(curl -sSLf https://raw.githubusercontent.com/google/clspv/main/deps.json \
        | "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print(next(c["commit"] for c in d["commits"] if c["name"]=="llvm"))' \
        2>/dev/null || true)
fi
if [ -z "$LLVM_TAG" ]; then
    echo "deps.json fetch failed; falling back to latest llvmorg release tag"
    LLVM_TAG=$(curl -s https://api.github.com/repos/llvm/llvm-project/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
fi
if [ -z "$LLVM_TAG" ]; then
    echo "Error: could not determine LLVM version to build"; exit 1
fi
if [ ! -d "llvm-project" ]; then
    echo "Fetching LLVM at $LLVM_TAG..."
    # Fetch via git (not tarball) so Windows MSYS2 handles symlinks safely.
    # MSYS2's tar fails on symlink entries it can't create natively (needs
    # winsymlinks:nativestrict + privilege, neither available on GH Actions
    # runners), which historically took down Windows LLVM builds whenever
    # the tree contained test-fixture or utility-script symlinks. Git on
    # Windows degrades symlinks to regular text files when native symlink
    # support isn't available — same visibility as Unix, no broken builds.
    #
    # We avoid cloning the full llvm-project history (hundreds of thousands
    # of commits, ~2GB+ of metadata) by doing init + targeted-SHA fetch.
    # GitHub allows `git fetch <SHA>` on any commit via uploadpack.allowAny
    # SHA1InWant, so `--depth 1 origin <SHA>` is a single-commit download.
    mkdir llvm-project
    (
        cd llvm-project
        git init -q
        git remote add origin https://github.com/llvm/llvm-project.git
        git -c advice.detachedHead=false fetch --depth 1 origin "$LLVM_TAG"
        git -c advice.detachedHead=false checkout FETCH_HEAD
    )
    # Canary check: the core build trees must be present.
    for required in "llvm-project/llvm/lib/Target" "llvm-project/llvm/CMakeLists.txt" \
                    "llvm-project/clang/lib" "llvm-project/clang/CMakeLists.txt" \
                    "llvm-project/cmake"; do
        if [ ! -e "$required" ]; then
            echo "Error: LLVM checkout incomplete — $required missing"
            exit 1
        fi
    done
fi

# Verify license
if [ ! -f "llvm-project/llvm/LICENSE.TXT" ]; then
    echo "Error: LLVM LICENSE not found"; exit 1
fi

# WASM: build native tools first. Tablegen must run on the host during
# cross-compile (Phase 2). We also build native clang + llvm-link here so
# the WASM artifact ships a natively-executable toolchain for downstream
# consumers that need to emit LLVM bitcode on the host (e.g. clspv's libclc
# build, which compiles .cl → spir-- .bc using a real process-exec'd clang).
# These native binaries end up in $PACKAGE_DIR/bin-native/ (see packaging
# step below); they are x86_64 Linux since the WASM LLVM job runs there.
if [ "$IS_WASM" -eq 1 ]; then
    echo "=== WASM Phase 1: Building native tools (tablegen + clang + llvm-link) ==="
    cd llvm-project
    mkdir -p build-native
    cd build-native

    $CMAKE ../llvm \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang" \
        -DLLVM_TARGETS_TO_BUILD="X86" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_ZLIB=OFF

    # Native tools: tablegen/llvm-config for Phase 2 cross-compile, plus a
    # broader set bundled into the artifact for downstream consumers.
    # libclc's CLC language (commit 121f5a96ff38 onward) invokes
    # find_llvm_tool for an expanding set of binaries — we've seen it
    # demand clang, opt, llvm-as, llvm-link, llvm-ar so far. Ship the
    # common LLVM binutils set proactively so future additions in this
    # pipeline don't cost another multi-hour cache invalidation.
    $CMAKE --build . --config Release \
        --target llvm-min-tblgen llvm-tblgen clang-tblgen llvm-config \
                 clang llvm-as llvm-link opt \
                 llvm-ar llvm-dis llvm-nm llvm-objcopy llvm-objdump \
                 llvm-ranlib llvm-readobj llvm-strip \
        -j$NCPU

    NATIVE_TOOLS_DIR="$(pwd)/bin"
    echo "Native tools at: $NATIVE_TOOLS_DIR"
    ls -la "$NATIVE_TOOLS_DIR/"

    cd "$BUILD_DIR"
    echo "=== WASM Phase 2: Building LLVM for WebAssembly ==="
fi

cd llvm-project
mkdir -p build
cd build

# Configure
WASM_FLAGS=""
if [ "$IS_WASM" -eq 1 ]; then
    WASM_FLAGS="-DLLVM_TABLEGEN=$NATIVE_TOOLS_DIR/llvm-tblgen -DCLANG_TABLEGEN=$NATIVE_TOOLS_DIR/clang-tblgen -DLLVM_CONFIG_PATH=$NATIVE_TOOLS_DIR/llvm-config -DLLVM_NATIVE_TOOL_DIR=$NATIVE_TOOLS_DIR -DLLVM_ENABLE_EH=ON -DLLVM_ENABLE_RTTI=ON -DLLVM_BUILD_TOOLS=OFF -DCLANG_BUILD_TOOLS=OFF"
    export LDFLAGS="-sNO_DISABLE_EXCEPTION_CATCHING -sNO_DISABLE_EXCEPTION_THROWING"
    CMAKE_CMD="emcmake $CMAKE"
    MAKE_CMD="emmake $CMAKE"
    LLVM_TARGETS="X86"
    LLVM_PROJECTS="clang"
    NATIVE_FLAGS=""
else
    CMAKE_CMD="$CMAKE"
    MAKE_CMD="$CMAKE"
    # Every backend an enigmatic target names (enigmatic/internal/targets/
    # targets.go: x86-64, x86, aarch64, arm, riscv64, loongarch64, ppc64,
    # ppc64le, systemz, wasm32, wasm64, nvptx64, amdgcn, spirv64) plus NVPTX
    # and AMDGPU for clspv. Spelled out rather than "Native;…" so the dev kit
    # and the slim clang carry the SAME backend list on all six platforms —
    # e records the backends in e.json, and a drift gate that compares e.json
    # byte for byte across hosts needs one list, not a per-host one. SPIRV is
    # a core target at the pin (llvm/CMakeLists.txt LLVM_ALL_TARGETS) and is
    # still passed through the experimental list below, which is what every
    # release since the pin has done; the two are merged and de-duplicated.
    LLVM_TARGETS="X86;ARM;AArch64;RISCV;LoongArch;PowerPC;SystemZ;WebAssembly;NVPTX;AMDGPU"
    # lld joins the native build: the slim asset ships bin/lld (wasm-ld for e's
    # wasm targets, every other flavor for free), and the dev kit gains the
    # liblld* archives and lld headers. The wasm phases stay clang-only.
    LLVM_PROJECTS="clang;lld"
    # Determinism and self-containment of the shipped tools:
    #   LLVM_APPEND_VC_REV=ON  the commit goes into `clang --version`, which is
    #                          how e.json and every generated header name the
    #                          pin by themselves (explicit; it is the default)
    #   LLVM_FORCE_VC_REPOSITORY / LLVM_FORCE_VC_REVISION  the repository and
    #                          commit spelled out, so the version line is
    #                          "clang version 23.0.0git (https://github.com/llvm/llvm-project.git <sha>)"
    #                          on every builder. Without them LLVM asks git
    #                          (`git remote get-url origin`, VersionFromVCS.cmake),
    #                          which reports the URL as the builder's git config
    #                          rewrites it - a url.<base>.insteadOf on the M6a
    #                          build host turned it into ssh://git@github.com/… -
    #                          and that line is the identity e records in e.json
    #                          and every generated header, which a blocking drift
    #                          gate compares byte for byte. GenerateVersionFromVCS
    #                          .cmake honours the pair for LLVM, Clang and LLD
    #                          alike, and it works for a tarball checkout too.
    #   LIBXML2/LIBEDIT/LIBPFM/CURL/HTTPLIB=OFF  nothing optional is linked in,
    #                          so the tools depend on the OS alone and no
    #                          non-LLVM license rides along (zlib/zstd are
    #                          already off); the dev kit's archives lose
    #                          nothing a consumer links today
    NATIVE_FLAGS="-DLLVM_APPEND_VC_REV=ON -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git -DLLVM_FORCE_VC_REVISION=$LLVM_TAG -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # One deployment floor for every darwin build instead of the runner's
        # OS version: 12.0 is Go 1.26's own macOS floor, so a host that can run
        # e can run this clang. Lowering the floor is safe for the dev kit —
        # ld64 accepts archives built for an older macOS than the dylib that
        # links them, never the reverse.
        NATIVE_FLAGS="$NATIVE_FLAGS -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_DEPLOYMENT_TARGET:-12.0}"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # libstdc++ and libgcc static (HandleLLVMStdlib.cmake adds
        # -static-libstdc++; -static-libgcc is ours), glibc dynamic: a fully
        # static glibc is both discouraged and LGPL-encumbered. The tools
        # depend on libc/libm/libdl/libpthread/librt and the loader only —
        # package-clang.sh asserts the list and records the glibc floor.
        NATIVE_FLAGS="$NATIVE_FLAGS -DLLVM_STATIC_LINK_CXX_STDLIB=ON -DCMAKE_EXE_LINKER_FLAGS=-static-libgcc"
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
        # MSYS2 executables import libstdc++-6/libgcc_s_seh-1/libwinpthread-1
        # (UCRT64) or libc++/libunwind (CLANGARM64) by default — absent on a
        # consumer's machine, which fails to start the tool with 0xC0000135
        # and no message. -static folds them in; the import table then names
        # Windows system DLLs only (package-clang.sh asserts it).
        # LLVM_PARALLEL_LINK_JOBS caps simultaneous links (Ninja only): each
        # link of a static all-backends tool wants a few GB and the runner has
        # 16 GB, while compiles use every core (common.sh NCPU).
        NATIVE_FLAGS="$NATIVE_FLAGS -DLLVM_STATIC_LINK_CXX_STDLIB=ON -DCMAKE_EXE_LINKER_FLAGS=-static -DLLVM_PARALLEL_LINK_JOBS=2"
    fi
fi

$CMAKE_CMD ../llvm \
    $CMAKE_GENERATOR \
    $CMAKE_OSX_ARCH_FLAG \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    $WASM_FLAGS \
    $NATIVE_FLAGS \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS" \
    -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
    -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD="SPIRV" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_DOCS=OFF \
    -DCLANG_ENABLE_HLSL=ON

echo "Building LLVM (this may take a while)..."
$MAKE_CMD --build . --config Release -j$NCPU

# Package
PACKAGE_DIR="$OUTPUT_DIR/llvm-$PLATFORM"
mkdir -p "$PACKAGE_DIR/lib" "$PACKAGE_DIR/include"

if [ "$IS_WASM" -eq 1 ]; then
    # WASM: cmake --install (plain, NOT emcmake — install is just file ops)
    # generates a relocatable CMake config. Do NOT copy build-tree
    # cmake files: those have hardcoded absolute paths that break when
    # the artifact is downloaded by a different job.
    echo "Installing WASM build to $PACKAGE_DIR..."
    "$CMAKE" --install . --prefix "$PACKAGE_DIR"

    # Ship the Phase 1 native binaries alongside the wasm-compiled install.
    # Downstream consumers (clspv's wasm libclc build) need a real,
    # process-exec'd clang + llvm-link on the host — the wasm-compiled
    # ones in $PACKAGE_DIR/bin/ can't be invoked as subprocesses.
    #
    # Laid out under $PACKAGE_DIR/native/{bin,lib} (not the top-level bin/lib
    # which are owned by the wasm install) so clang's own prefix resolution
    # — realpath(argv[0])/../.. — finds its resource dir at
    # $PACKAGE_DIR/native/lib/clang/<ver>/ without us passing -resource-dir.
    NATIVE_PREFIX="$PACKAGE_DIR/native"
    echo "Bundling native clang + llvm-link into $NATIVE_PREFIX/bin/..."
    mkdir -p "$NATIVE_PREFIX/bin"
    # The real clang binary is clang-<major>; clang and clang++ are symlinks
    # to it. Copy the real binary + preserve any clang* symlinks so invoking
    # "clang" or "clang++" from native/bin/ resolves correctly. Ship:
    #   - clang/clang++ (compilation)
    #   - tablegen tools (llvm-min-tblgen, llvm-tblgen, clang-tblgen) so
    #     downstream wasm cross-compiles (clspv) can pass them via
    #     LLVM_TABLEGEN/CLANG_TABLEGEN and skip building their own NATIVE
    #     sub-tree. Without these, clspv's "NATIVE" sub-build gets compiled
    #     by emmake's inherited em++ env → produces Emscripten JS binaries
    #     that run under Node's MEMFS → can't see host filesystem files
    #     like AArch64.td.
    #   - llvm-config (version/flag queries)
    #   - common LLVM binutils (ar, as, dis, link, nm, objcopy, objdump,
    #     opt, ranlib, readobj, strip) — libclc's CLC language calls
    #     find_llvm_tool on a growing set of these, and we'd rather ship
    #     them proactively than eat another cache invalidation per tool.
    for f in "$NATIVE_TOOLS_DIR"/clang "$NATIVE_TOOLS_DIR"/clang-[0-9]* \
             "$NATIVE_TOOLS_DIR"/clang++ \
             "$NATIVE_TOOLS_DIR"/llvm-config \
             "$NATIVE_TOOLS_DIR"/llvm-min-tblgen \
             "$NATIVE_TOOLS_DIR"/llvm-tblgen \
             "$NATIVE_TOOLS_DIR"/clang-tblgen \
             "$NATIVE_TOOLS_DIR"/llvm-ar \
             "$NATIVE_TOOLS_DIR"/llvm-as \
             "$NATIVE_TOOLS_DIR"/llvm-dis \
             "$NATIVE_TOOLS_DIR"/llvm-link \
             "$NATIVE_TOOLS_DIR"/llvm-nm \
             "$NATIVE_TOOLS_DIR"/llvm-objcopy \
             "$NATIVE_TOOLS_DIR"/llvm-objdump \
             "$NATIVE_TOOLS_DIR"/llvm-ranlib \
             "$NATIVE_TOOLS_DIR"/llvm-readobj \
             "$NATIVE_TOOLS_DIR"/llvm-strip \
             "$NATIVE_TOOLS_DIR"/opt; do
        [ -e "$f" ] && cp -P "$f" "$NATIVE_PREFIX/bin/"
    done
    # Clang looks up its builtin headers (stddef.h, stdint.h, opencl-c.h, ...)
    # via <prefix>/lib/clang/<ver>/include/, prefix = dirname(dirname(clang)).
    # Ship the resource headers next to the native binaries.
    NATIVE_BUILD_ROOT="$(dirname "$NATIVE_TOOLS_DIR")"
    if [ -d "$NATIVE_BUILD_ROOT/lib/clang" ]; then
        mkdir -p "$NATIVE_PREFIX/lib/clang"
        cp -r "$NATIVE_BUILD_ROOT/lib/clang/"* "$NATIVE_PREFIX/lib/clang/"
    fi
else
    # Native: cmake --install generates relocatable CMake config
    echo "Installing to $PACKAGE_DIR..."
    cmake --install . --prefix "$PACKAGE_DIR"

    # Fix rpaths on macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        find "$PACKAGE_DIR/lib" -name "*.dylib" | while read d; do
            install_name_tool -id "@rpath/$(basename "$d")" "$d" 2>/dev/null || true
        done
    fi

    # The slim clang asset — clang-<platform>.tar.gz — packaged from this very
    # install tree before anything below touches it. A failure here fails the
    # job: the asset is a release deliverable, and a job that fails caches
    # nothing, so a half-made asset never lands in the cache either.
    echo "Packaging the slim clang asset (scripts/package-clang.sh)..."
    LLVM_INSTALL_DIR="$PACKAGE_DIR" \
    LLVM_SOURCE_DIR="$BUILD_DIR/llvm-project" \
    PLATFORM="$PLATFORM" \
    LLVM_TAG="$LLVM_TAG" \
    OUTPUT_DIR="$OUTPUT_DIR" \
    bash "$SCRIPT_DIR/package-clang.sh"

    # Windows dev kit: cmake --install copies instead of symlinking there
    # (LLVM_USE_SYMLINKS defaults to CMAKE_HOST_UNIX, and LLVMInstallSymlink
    # .cmake then runs `cmake -E copy`), so clang's four driver aliases and
    # lld's four flavor names are each a full copy of a ~230 MB static
    # binary. v0.0.82's llvm-windows-amd64.tar.gz was already 91% of GitHub's
    # 2 GiB asset cap before lld and eight more backends; the copies are
    # pure redundancy, so drop every alias that is byte-identical to the
    # real binary. clang.exe and lld.exe stay (they ARE the real binaries on
    # Windows — no clang-<major>.exe exists there); `clang --driver-mode=g++`
    # and `lld -flavor <x>` reach every removed name's behaviour.
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
        prune_alias() { # <alias.exe> <real.exe>
            [ -f "$1" ] && [ -f "$2" ] || return 0
            if [ "$(wc -c < "$1")" = "$(wc -c < "$2")" ] && \
               [ "$(sha256sum "$1" | awk '{print $1}')" = "$(sha256sum "$2" | awk '{print $1}')" ]; then
                echo "  dev kit: removing $(basename "$1") (a copy of $(basename "$2"))"
                rm -f "$1"
            fi
        }
        for a in clang++ clang-cl clang-cpp clang-dxc; do
            prune_alias "$PACKAGE_DIR/bin/$a.exe" "$PACKAGE_DIR/bin/clang.exe"
        done
        for a in ld.lld ld64.lld lld-link wasm-ld; do
            prune_alias "$PACKAGE_DIR/bin/$a.exe" "$PACKAGE_DIR/bin/lld.exe"
        done
    fi
fi

# Bundle the FULL llvm-project source tree into the artifact so downstream
# consumers (clspv, spirv-llvm-translator) can reference any file they need.
# LLVM is a monorepo with heavy cross-subtree dependencies — clspv alone
# touches llvm/, clang/, cmake/, third-party/ (SipHash), runtimes/ and the
# add_subdirectory() graph reaches into test/, examples/, unittests/, etc.
# Earlier attempts to prune heavy bits (test/, examples/, docs/...) triggered
# cascading "missing directory" failures. Bundle everything minus .git and
# build outputs; let CMake flags decide what actually gets built.
#
# common.sh normalizes $OUTPUT_DIR (and therefore $PACKAGE_DIR) to POSIX form
# on MSYS2 via cygpath, so no drive-letter colons reach tar's path parser here.
echo "Bundling full llvm-project source tree into $PACKAGE_DIR/src..."
mkdir -p "$PACKAGE_DIR/src"
tar -cf - \
    --exclude=.git \
    --exclude=build \
    --exclude=build-native \
    -C .. . | tar -xf - -C "$PACKAGE_DIR/src"

# Record the LLVM commit/tag we built so consumers can verify version
# match. $LLVM_TAG is whatever the resolver produced: a SHA (typical CI
# path — from determine-llvm-sha via clspv's deps.json), or an llvmorg-*
# release tag (fallback). Either form is a valid upstream identifier.
echo "$LLVM_TAG" > "$PACKAGE_DIR/VERSION"

# Licenses — hard copies, no `|| true`: clang is always built, and the native
# dev kit now carries lld's archives, so its license text travels with them.
# The three texts differ (each names its own legacy UIUC copyright line), and
# the verify-licenses job hashes all three source files.
mkdir -p "$PACKAGE_DIR/LICENSES"
cp ../llvm/LICENSE.TXT "$PACKAGE_DIR/LICENSES/LLVM-LICENSE.TXT"
cp ../clang/LICENSE.TXT "$PACKAGE_DIR/LICENSES/Clang-LICENSE.TXT"
if [ "$IS_WASM" -eq 0 ]; then
    cp ../lld/LICENSE.TXT "$PACKAGE_DIR/LICENSES/LLD-LICENSE.TXT"
fi

cd "$OUTPUT_DIR"
tar -czf "llvm-${PLATFORM}.tar.gz" "llvm-$PLATFORM"
echo "Created: llvm-${PLATFORM}.tar.gz"
echo "Build complete!"
