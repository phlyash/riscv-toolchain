#!/usr/bin/env bash
# Build the NIIET RISC-V baremetal (newlib) toolchain:
#
#   patched GCC/binutils/newlib/GDB
#   upstream LLVM/Clang 22.1.8
#   LLD
#   clangd
#   clang-format
#   clang-tidy
#
# GCC and Clang are installed into the same prefix and use
# the GCC-built RISC-V newlib/sysroot.
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
NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
ARCH=rv32i_zicsr_zifencei
ABI=ilp32
TUPLE=riscv32-unknown-elf

# Reduced rv32 subset chain, BARE canonical arch strings (no explicit
# _zicsr_zifencei): these match what clang emits when it normalizes -march, so
# GCC's multilib dir names and clang's multilib lookup keys are identical and both
# compilers select the same .a. Combined with --with-isa-spec=20191213 below.
# Last two add the P (DSP/packed-SIMD) extension: integer DSP (no FPU) + full+DSP.
# newlib-nano is built automatically alongside each variant.
MULTILIB="rv32i-ilp32--;rv32im-ilp32--;rv32imc-ilp32--;rv32imac-ilp32--;rv32imafc-ilp32f--;rv32imafdc-ilp32d--;rv32imcp-ilp32--;rv32imafdcp-ilp32d--"

case "$(uname -s)" in
  Linux)  HOSTOS=linux ;;
  Darwin) HOSTOS=macos ;;
  *)      HOSTOS="$(uname -s | tr 'A-Z' 'a-z')" ;;
esac
[ -n "$WITH_HOST" ] && case "$WITH_HOST" in *mingw*) HOSTOS=windows ;; esac
RAW_HOSTARCH="$(uname -m)"
case "$RAW_HOSTARCH" in
    x86_64|amd64) HOSTARCH="x86_64" ;;
    arm64|aarch64) HOSTARCH="aarch64" ;;
    *) HOSTARCH="$RAW_HOSTARCH" ;;
esac

log(){ echo "" ; echo "=== [$(date +%H:%M:%S)] $* ===" ; }

# Extra `make` flags for gdb's configure; only set for the canadian cross.
GDB_EXTRA=""
GCC_EXTRA=""
BINUTILS_EXTRA=""

gcc_build_into() {
    local prefix="$1" host="$2"

    log "configure GCC/newlib -> $prefix${host:+ (host=$host)}"
    rm -rf "$BUILD"
    mkdir -p "$BUILD"
    cd "$BUILD"

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

    make -j"$NPROC" newlib \
        GCC_EXTRA_CONFIGURE_FLAGS="$GCC_EXTRA" \
        BINUTILS_TARGET_FLAGS_EXTRA="$BINUTILS_EXTRA" \
        GDB_TARGET_FLAGS_EXTRA="$GDB_EXTRA"
}

stage_gcc() {
    local BASE_CPPFLAGS="${CPPFLAGS:-}"
    local BASE_LDFLAGS="${LDFLAGS:-}"
    local DEPS

    if [ -n "$WITH_HOST" ]; then
        local NATIVE="$WORK/native-toolchain"

        if [ ! -x "$NATIVE/bin/${TUPLE}-gcc" ]; then
            log "native pre-pass for canadian cross -> $NATIVE"

            export CPPFLAGS="$BASE_CPPFLAGS"
            export LDFLAGS="-static-libstdc++ -static-libgcc${BASE_LDFLAGS:+ $BASE_LDFLAGS}"

            GCC_EXTRA=""
            BINUTILS_EXTRA=""
            GDB_EXTRA=""

            gcc_build_into "$NATIVE" ""
        fi

        export PATH="$NATIVE/bin:$PATH"
        log "native build->target compiler: $(command -v "${TUPLE}-gcc")"

        DEPS="$(HOST="$WITH_HOST" WORK="$WORK" bash "$SRC/build/prepare-mingw-deps.sh" | tail -1)"

        export CPPFLAGS="-I$DEPS/include -I$DEPS/include/ncursesw${BASE_CPPFLAGS:+ $BASE_CPPFLAGS}"
        export LDFLAGS="-static -static-libgcc -static-libstdc++ -L$DEPS/lib${BASE_LDFLAGS:+ $BASE_LDFLAGS}"

        GCC_EXTRA="--with-gmp=$DEPS --with-mpfr=$DEPS --with-mpc=$DEPS"
        BINUTILS_EXTRA="--with-expat=$DEPS"

        GDB_EXTRA="--enable-tui --with-curses \
--enable-static --disable-shared --with-static-standard-libraries \
--with-gmp=$DEPS --with-mpfr=$DEPS --with-expat=$DEPS \
--with-libexpat-type=static \
--without-python --without-guile \
--with-debuginfod=no --with-lzma=no --with-zstd=no --with-xxhash=no \
--disable-source-highlight --disable-nls"

        log "Windows static deps: $DEPS"
        log "Windows LDFLAGS=$LDFLAGS"

        gcc_build_into "$PREFIX" "$WITH_HOST"
        return
    fi

    DEPS="$(WORK="$WORK" bash "$SRC/build/prepare-host-deps.sh" | tail -1)"

    export CPPFLAGS="-I$DEPS/include -I$DEPS/include/ncursesw${BASE_CPPFLAGS:+ $BASE_CPPFLAGS}"

    if [ "$HOSTOS" = linux ]; then
        export LDFLAGS="-L$DEPS/lib -static-libstdc++ -static-libgcc${BASE_LDFLAGS:+ $BASE_LDFLAGS}"
    else
        export LDFLAGS="-L$DEPS/lib${BASE_LDFLAGS:+ $BASE_LDFLAGS}"
    fi

    GCC_EXTRA="--with-gmp=$DEPS --with-mpfr=$DEPS --with-mpc=$DEPS --with-isl=$DEPS"
    BINUTILS_EXTRA="--with-expat=$DEPS"

    GDB_EXTRA="--enable-tui --with-curses \
--enable-static --disable-shared \
--with-gmp=$DEPS --with-mpfr=$DEPS --with-expat=$DEPS \
--with-libexpat-type=static \
--without-python --without-guile \
--with-debuginfod=no --with-lzma=no --with-zstd=no --with-xxhash=no \
--disable-source-highlight --disable-nls"

    if [ "$HOSTOS" = linux ]; then
        GDB_EXTRA="$GDB_EXTRA --with-static-standard-libraries"
    fi

    log "native static deps: $DEPS"
    gcc_build_into "$PREFIX" ""

    "$PREFIX/bin/${TUPLE}-gcc" -v 2>&1 | tail -3 || true
    "$PREFIX/bin/${TUPLE}-gcc" -print-multi-lib || true
    "$PREFIX/bin/${TUPLE}-gdb" --configuration || true
}

# Cross-build clang/lld for a mingw Windows host (canadian cross). LLVM needs
# RUNNABLE *-tblgen during its build; the host ones are .exe, so build native
# tblgens first and point the cross build at them (LLVM_NATIVE_TOOL_DIR). Host
# link is fully static (-static + static libgcc/libstdc++/winpthread) and all
# optional host deps are disabled so clang.exe/lld.exe carry no extra mingw DLLs.
#   $1 = python   $2 = distribution component list
stage_clang_cross(){
  local PY="$1"
  local LLVM_DIST="$2"

  local NAT="$WORK/llvm-native-tblgen"


  if [ ! -x "$NAT/bin/llvm-tblgen" ] || \
     [ ! -x "$NAT/bin/clang-tblgen" ]; then

    log "native tblgen pre-pass for LLVM cross -> $NAT"

    rm -rf "$NAT"
    mkdir -p "$NAT"
    cd "$NAT"


    cmake -G Ninja "$SRC/llvm/llvm" \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra" \
      -DLLVM_TARGETS_TO_BUILD="RISCV" \
      -DPython3_EXECUTABLE="$PY"


    ninja -j"$NPROC" \
      llvm-tblgen \
      llvm-min-tblgen \
      clang-tblgen
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

# Build clang/lld from Syntacore's LLVM directly with cmake, targeting baremetal
# and reusing the Pass-1 GCC sysroot. Installs ONLY clang + builtin headers + lld,
# stripped (LLVM distribution-components) — keeps it small and avoids clobbering
# the multilib GCC that the Makefile's --enable-llvm path would.
stage_clang(){
  local PY
  PY="$(command -v python3.11 || command -v python3)"
  local LLVM_DIST="clang;clang-resource-headers;lld;clangd;clang-format;clang-tidy"
  if [ -n "$WITH_HOST" ]; then
    stage_clang_cross "$PY" "$LLVM_DIST"
    log "clang cross sanity: file"
    file "$PREFIX/bin/clang.exe" || true
    file "$PREFIX/bin/clangd.exe" || true
    file "$PREFIX/bin/clang-format.exe" || true
    file "$PREFIX/bin/clang-tidy.exe" || true
    return 0
  fi
  log "configure + build upstream LLVM/Clang 22.1.8"
  rm -rf "$LB"
  mkdir -p "$LB"
  cd "$LB"
  local LLVM_STATIC_CXX=OFF
  if [ "$HOSTOS" != macos ]; then
    LLVM_STATIC_CXX=ON
  fi
  cmake -G Ninja "$SRC/llvm/llvm" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DLLVM_STATIC_LINK_CXX_STDLIB="$LLVM_STATIC_CXX" \
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

    local strip_tool="strip"
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

    rm -f \
        "$OUT/${name}.tar.gz" \
        "$OUT/${name}.zip"

    tar -czf "$OUT/${name}.tar.gz" -C "$PREFIX" .

    (
        cd "$PREFIX"
        zip -qr "$OUT/${name}.zip" .
    )

    log "wrote $OUT/${name}.tar.gz ($(du -h "$OUT/${name}.tar.gz" | cut -f1))"
    log "wrote $OUT/${name}.zip ($(du -h "$OUT/${name}.zip" | cut -f1))"
}

case "$STAGE" in
  gcc)     stage_gcc ;;
  clang)   stage_clang ;;
  package) stage_package ;;
  all)     stage_gcc; stage_clang; stage_package ;;
  *) echo "usage: $0 {gcc|clang|package|all}"; exit 2 ;;
esac
log "stage '$STAGE' complete"
