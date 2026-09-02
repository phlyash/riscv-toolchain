#!/usr/bin/env bash
# Build the NIIET RISC-V baremetal toolchain:
#   patched GCC/binutils/newlib/GDB
#   upstream LLVM/Clang 22.1.8
#   LLD, clangd, clang-format, clang-tidy
#
# GCC and Clang are installed into the same prefix.
# Target runtime is GCC-built newlib/libgcc/libstdc++.

set -euo pipefail

STAGE="${1:-all}"
SRC="${SRC:-/src}"
SOURCES="${SOURCES:-/sources}"
WORK="${WORK:-/work}"
PREFIX="${PREFIX:-/opt/riscv}"
OUT="${OUT:-/out}"
WITH_HOST="${WITH_HOST:-}"

BUILD="$WORK/build"
LB="$WORK/llvm-build"
NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

ARCH=rv32i_zicsr_zifencei
ABI=ilp32
TUPLE=riscv32-unknown-elf

# First 6 multilibs are shared GCC/Clang targets.
# Last 2 are NIIET P-extension GCC-only targets.
MULTILIB="rv32i-ilp32--;rv32im-ilp32--;rv32imc-ilp32--;rv32imac-ilp32--;rv32imafc-ilp32f--;rv32imafdc-ilp32d--;rv32imcp-ilp32--;rv32imafdcp-ilp32d--"

case "$(uname -s)" in
    Linux) HOSTOS=linux ;;
    Darwin) HOSTOS=macos ;;
    *) HOSTOS="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
esac

[ -n "$WITH_HOST" ] && case "$WITH_HOST" in
    *mingw*) HOSTOS=windows ;;
esac

RAW_HOSTARCH="$(uname -m)"
case "$RAW_HOSTARCH" in
    x86_64|amd64) HOSTARCH=x86_64 ;;
    arm64|aarch64) HOSTARCH=aarch64 ;;
    *) HOSTARCH="$RAW_HOSTARCH" ;;
esac

log() {
    echo
    echo "=== [$(date +%H:%M:%S)] $* ==="
}

GDB_EXTRA=""
GDB_MAKE_EXTRA=""
# libcc1 is an optional, always-shared bridge for GDB's `compile` command.
# Minimal host artifacts omit it instead of carrying GCC host plugin DSOs.
GCC_EXTRA=""
BINUTILS_EXTRA=""

gcc_build_into() {
    local prefix="$1"
    local host="$2"
    local wrapper_cppflags="${3:-}"
    local wrapper_ldflags="${4:-}"

    log "configure GCC/newlib -> $prefix${host:+ (host=$host)}"

    rm -rf "$BUILD"
    mkdir -p "$BUILD"
    cd "$BUILD"

    # This configure always runs on the build machine.
    # Do not leak MinGW/static host flags into it.
    CPPFLAGS="$wrapper_cppflags" LDFLAGS="$wrapper_ldflags" \
    "$SRC/configure" \
        --prefix="$prefix" \
        --with-arch="$ARCH" \
        --with-abi="$ABI" \
        --with-isa-spec=20191213 \
        --with-multilib-generator="$MULTILIB" \
        --with-languages=c,c++ \
        --without-system-zlib \
        --enable-strip \
        ${host:+--with-host="$host"} \
        --with-gcc-src="$SOURCES/gcc" \
        --with-binutils-src="$SOURCES/binutils" \
        --with-newlib-src="$SOURCES/newlib" \
        --with-gdb-src="$SOURCES/gdb"

    log "make newlib -j$NPROC -> $prefix"

    # Here the exported CPPFLAGS/LDFLAGS are intentionally inherited.
    # Child GCC/binutils/GDB configure scripts receive CONFIGURE_HOST
    # and build the actual Windows host executables.
    make -j"$NPROC" newlib \
        GCC_EXTRA_CONFIGURE_FLAGS="$GCC_EXTRA" \
        BINUTILS_TARGET_FLAGS_EXTRA="$BINUTILS_EXTRA" \
        GDB_TARGET_FLAGS_EXTRA="$GDB_EXTRA" \
        GDB_TARGET_MAKE_FLAGS_EXTRA="$GDB_MAKE_EXTRA"
}

stage_gcc() {
    local BASE_CPPFLAGS="${CPPFLAGS:-}"
    local BASE_LDFLAGS="${LDFLAGS:-}"
    local DEPS

    if [ -n "$WITH_HOST" ]; then
        local NATIVE="$WORK/native-toolchain"

        if [ ! -x "$NATIVE/bin/${TUPLE}-gcc" ]; then
            log "native pre-pass for Canadian cross -> $NATIVE"

            export CPPFLAGS="$BASE_CPPFLAGS"
            export LDFLAGS="-static-libstdc++ -static-libgcc${BASE_LDFLAGS:+ $BASE_LDFLAGS}"

            GCC_EXTRA="--disable-libcc1"
            BINUTILS_EXTRA=""
            GDB_EXTRA=""
            GDB_MAKE_EXTRA=""

            gcc_build_into "$NATIVE" "" "$BASE_CPPFLAGS" "$BASE_LDFLAGS"
        fi

        export PATH="$NATIVE/bin:$PATH"
        log "native build->target compiler: $(command -v "${TUPLE}-gcc")"

        DEPS="$(HOST="$WITH_HOST" WORK="$WORK" bash "$SRC/build/prepare-mingw-deps.sh" | tail -1)"

        log "checking static MinGW ncurses"

        cat > "$WORK/test-curses-win.c" <<'EOF'
#include <curses.h>
int main(void) {
    initscr();
    endwin();
    return 0;
}
EOF

        "${WITH_HOST}-gcc" -DNCURSES_STATIC "$WORK/test-curses-win.c" \
            -static -static-libgcc -lncursesw \
            -o "$WORK/test-curses-win.exe"

        "${WITH_HOST}-objdump" -p "$WORK/test-curses-win.exe" |
            sed -n 's/^[[:space:]]*DLL Name: /  /p'

        rm -f "$WORK/test-curses-win.c" "$WORK/test-curses-win.exe"

        # Do NOT put $DEPS/include into global CPPFLAGS:
        # GCC build generators are native Linux programs and would otherwise
        # consume MinGW headers.
        #
        # NCURSES_STATIC is safe for native build tools and is required so
        # MinGW ncurses headers do not emit __imp_* DLL references.
        export CPPFLAGS="-DNCURSES_STATIC${BASE_CPPFLAGS:+ $BASE_CPPFLAGS}"

        # Do NOT add -L$DEPS/lib globally either. $DEPS is the MinGW sysroot
        # and x86_64-w64-mingw32-gcc already searches its lib directory.
        export LDFLAGS="-static -static-libgcc -static-libstdc++${BASE_LDFLAGS:+ $BASE_LDFLAGS}"

        GCC_EXTRA="--disable-libcc1 --with-gmp=$DEPS --with-mpfr=$DEPS --with-mpc=$DEPS"
        BINUTILS_EXTRA="--with-expat=$DEPS --without-zstd"

        # GDB's final executable link runs through Libtool, where -static only
        # affects uninstalled Libtool libraries. -all-static is the separate
        # mode that reaches the compiler driver and selects libwinpthread.a.
        GDB_MAKE_EXTRA='LDFLAGS="-all-static -static-libgcc -static-libstdc++"'

        GDB_EXTRA="--enable-tui --with-curses \
--enable-static --disable-shared --with-static-standard-libraries \
--with-gmp=$DEPS --with-mpfr=$DEPS --with-expat=yes \
--with-libexpat-prefix=$DEPS \
--with-libexpat-type=static \
--without-python --without-guile \
--with-debuginfod=no --with-lzma=no --with-zstd=no --with-xxhash=no \
--disable-source-highlight --disable-nls \
CFLAGS=\"-O2 -static\" CXXFLAGS=\"-O2 -static\""

        log "Windows static deps: $DEPS"
        log "Windows CPPFLAGS=$CPPFLAGS"
        log "Windows LDFLAGS=$LDFLAGS"

        gcc_build_into "$PREFIX" "$WITH_HOST" "$BASE_CPPFLAGS" "$BASE_LDFLAGS"
        return
    fi

    DEPS="$(WORK="$WORK" bash "$SRC/build/prepare-host-deps.sh" | tail -1)"

    if [ "$HOSTOS" = macos ]; then
        export CPPFLAGS="-I$DEPS/include${BASE_CPPFLAGS:+ $BASE_CPPFLAGS}"
    else
        export CPPFLAGS="-I$DEPS/include -I$DEPS/include/ncursesw${BASE_CPPFLAGS:+ $BASE_CPPFLAGS}"
    fi

    if [ "$HOSTOS" = linux ]; then
        export LDFLAGS="-L$DEPS/lib -static-libstdc++ -static-libgcc${BASE_LDFLAGS:+ $BASE_LDFLAGS}"
    else
        export LDFLAGS="-L$DEPS/lib${BASE_LDFLAGS:+ $BASE_LDFLAGS}"
    fi

    GCC_EXTRA="--disable-libcc1 --with-gmp=$DEPS --with-mpfr=$DEPS --with-mpc=$DEPS --with-isl=$DEPS"
    BINUTILS_EXTRA="--with-expat=$DEPS --without-zstd"

    GDB_EXTRA="--enable-tui --with-curses \
--enable-static --disable-shared \
--with-gmp=$DEPS --with-mpfr=$DEPS --with-expat=yes \
--with-libexpat-prefix=$DEPS \
--with-libexpat-type=static \
--without-python --without-guile \
--with-debuginfod=no --with-lzma=no --with-zstd=no --with-xxhash=no \
--disable-source-highlight --disable-nls"

    if [ "$HOSTOS" = linux ]; then
        GDB_EXTRA="$GDB_EXTRA --with-static-standard-libraries"
    fi

    if [ "$HOSTOS" = macos ]; then
        log "checking macOS system curses"

        cat > "$WORK/test-curses.c" <<'EOF'
#include <curses.h>
int main(void) { return 0; }
EOF

        cc "$WORK/test-curses.c" -lcurses -o "$WORK/test-curses"
        rm -f "$WORK/test-curses.c" "$WORK/test-curses"
    fi

    log "native static deps: $DEPS"
    log "CPPFLAGS=$CPPFLAGS"
    log "LDFLAGS=$LDFLAGS"

    gcc_build_into "$PREFIX" "" "$BASE_CPPFLAGS" "$BASE_LDFLAGS"

    "$PREFIX/bin/${TUPLE}-gcc" -v 2>&1 | tail -3 || true
    "$PREFIX/bin/${TUPLE}-gcc" -print-multi-lib || true
    "$PREFIX/bin/${TUPLE}-gdb" --configuration || true

    if [ "$HOSTOS" = macos ]; then
        log "macOS GDB runtime dependencies"
        otool -L "$PREFIX/bin/${TUPLE}-gdb" || true
    fi
}

# Cross-build LLVM/Clang for a MinGW Windows host.
# Native tblgen binaries are required because Windows .exe cannot run
# directly on the Linux build host.
stage_clang_cross() {
    local PY="$1"
    local LLVM_DIST="$2"
    local NAT="$WORK/llvm-native-tblgen"

    if [ ! -x "$NAT/bin/llvm-tblgen" ] || [ ! -x "$NAT/bin/clang-tblgen" ]; then
        log "native tblgen pre-pass for LLVM cross -> $NAT"

        rm -rf "$NAT"
        mkdir -p "$NAT"
        cd "$NAT"

        cmake -G Ninja "$SRC/llvm/llvm" \
            -DCMAKE_BUILD_TYPE=Release \
            -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra" \
            -DLLVM_TARGETS_TO_BUILD="RISCV" \
            -DPython3_EXECUTABLE="$PY"

        ninja -j"$NPROC" llvm-tblgen llvm-min-tblgen clang-tblgen
    fi

    log "cross-build LLVM/Clang -> $WITH_HOST"

    rm -rf "$LB"
    mkdir -p "$LB"
    cd "$LB"

    cmake -G Ninja "$SRC/llvm/llvm" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER="${WITH_HOST}-gcc" \
        -DCMAKE_CXX_COMPILER="${WITH_HOST}-g++" \
        -DCMAKE_RC_COMPILER="${WITH_HOST}-windres" \
        -DCMAKE_STRIP="${WITH_HOST}-strip" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_EXE_LINKER_FLAGS="-static -static-libgcc -static-libstdc++" \
        -DCMAKE_SHARED_LINKER_FLAGS="-static -static-libgcc -static-libstdc++" \
        -DLLVM_HOST_TRIPLE="${WITH_HOST/-w64-mingw32/-w64-windows-gnu}" \
        -DLLVM_NATIVE_TOOL_DIR="$NAT/bin" \
        -DPython3_EXECUTABLE="$PY" \
        -DLLVM_TARGETS_TO_BUILD="RISCV" \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld" \
        -DLLVM_DEFAULT_TARGET_TRIPLE="$TUPLE" \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_ENABLE_SPHINX=OFF \
        -DLLVM_ENABLE_DOXYGEN=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_CURL=OFF \
        -DLLVM_PARALLEL_LINK_JOBS=2 \
        -DLLVM_BINUTILS_INCDIR="$SOURCES/binutils/include" \
        -DLLVM_DISTRIBUTION_COMPONENTS="$LLVM_DIST"

    ninja -j"$NPROC" distribution
    ninja install-distribution-stripped

    log "cross LLVM done"

    file "$PREFIX/bin/clang.exe" || true
    file "$PREFIX/bin/clangd.exe" || true
    file "$PREFIX/bin/clang-format.exe" || true
    file "$PREFIX/bin/clang-tidy.exe" || true
}

# Build upstream LLVM/Clang 22.1.8 into the same prefix as GCC.
# LLVM target runtimes are not built: Clang reuses GCC-built
# newlib/libgcc/libstdc++.
stage_clang() {
    local PY
    local LLVM_DIST="clang;clang-resource-headers;lld;clangd;clang-format;clang-tidy"

    PY="$(command -v python3.11 || command -v python3)"

    if [ -n "$WITH_HOST" ]; then
        stage_clang_cross "$PY" "$LLVM_DIST"
        return
    fi

    log "configure + build upstream LLVM/Clang 22.1.8"

    rm -rf "$LB"
    mkdir -p "$LB"
    cd "$LB"

    # Keep this array non-empty: macOS ships Bash 3.2, whose nounset mode
    # rejects expansion of an empty array.
    local LLVM_HOST_LINK_ARGS=(-DLLVM_STATIC_LINK_CXX_STDLIB=OFF)

    if [ "$HOSTOS" != macos ]; then
        # LLVM_STATIC_LINK_CXX_STDLIB covers libstdc++, but not GCC's unwind
        # runtime. Apply -static-libgcc to every kind of host link product.
        LLVM_HOST_LINK_ARGS=(
            -DLLVM_STATIC_LINK_CXX_STDLIB=ON
            -DCMAKE_EXE_LINKER_FLAGS=-static-libgcc
            -DCMAKE_SHARED_LINKER_FLAGS=-static-libgcc
            -DCMAKE_MODULE_LINKER_FLAGS=-static-libgcc
        )
    fi

    cmake -G Ninja "$SRC/llvm/llvm" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        "${LLVM_HOST_LINK_ARGS[@]}" \
        -DPython3_EXECUTABLE="$PY" \
        -DLLVM_TARGETS_TO_BUILD="RISCV" \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld" \
        -DLLVM_DEFAULT_TARGET_TRIPLE="$TUPLE" \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_ENABLE_SPHINX=OFF \
        -DLLVM_ENABLE_DOXYGEN=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_CURL=OFF \
        -DLLVM_PARALLEL_LINK_JOBS=2 \
        -DLLVM_BINUTILS_INCDIR="$SOURCES/binutils/include" \
        -DLLVM_DISTRIBUTION_COMPONENTS="$LLVM_DIST"

    ninja -j"$NPROC" distribution
    ninja install-distribution-stripped

    log "LLVM sanity"

    "$PREFIX/bin/clang" --version
    "$PREFIX/bin/clangd" --version
    "$PREFIX/bin/clang-format" --version
    "$PREFIX/bin/clang-tidy" --version
    "$PREFIX/bin/lld" --version || true
}

stage_package() {
    log "package"

    echo "before: $(du -sh "$PREFIX" | cut -f1)"

    local strip_tool=strip
    [ -n "$WITH_HOST" ] && strip_tool="${WITH_HOST}-strip"

    find "$PREFIX" -type f -exec sh -c '
        tool="$1"
        f="$2"
        t="$(file -b "$f" 2>/dev/null || true)"

        case "$t" in
            *ELF*executable*|*ELF*shared*|*Mach-O*executable*|*Mach-O*dynamically*|*PE32*executable*)
                "$tool" "$f" 2>/dev/null || true
                ;;
        esac
    ' _ "$strip_tool" {} \;

    echo "after strip: $(du -sh "$PREFIX" | cut -f1)"

    if [ -x "$SRC/.github/dedup-dir.sh" ]; then
        "$SRC/.github/dedup-dir.sh" "$PREFIX" || true
    fi

    echo "after dedup: $(du -sh "$PREFIX" | cut -f1)"

    mkdir -p "$OUT"

    local name="niiet-riscv-toolchain-${HOSTOS}-${HOSTARCH}"

    rm -f "$OUT/${name}.tar.gz" "$OUT/${name}.zip"

    # No extra root directory:
    # archive directly contains bin/, lib/, share/, riscv32-unknown-elf/, ...
    tar -czf "$OUT/${name}.tar.gz" -C "$PREFIX" .

    (
        cd "$PREFIX"
        zip -qr "$OUT/${name}.zip" .
    )

    log "wrote $OUT/${name}.tar.gz ($(du -h "$OUT/${name}.tar.gz" | cut -f1))"
    log "wrote $OUT/${name}.zip ($(du -h "$OUT/${name}.zip" | cut -f1))"
}

case "$STAGE" in
    gcc) stage_gcc ;;
    clang) stage_clang ;;
    package) stage_package ;;
    all) stage_gcc; stage_clang; stage_package ;;
    *)
        echo "usage: $0 {gcc|clang|package|all}"
        exit 2
        ;;
esac

log "stage '$STAGE' complete"
