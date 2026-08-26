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
HOSTARCH="$(uname -m)"

log(){ echo "" ; echo "=== [$(date +%H:%M:%S)] $* ===" ; }

# Extra `make` flags for gdb's configure; only set for the canadian cross.
GDB_EXTRA=""

# One full GCC + reduced-multilib + newlib(+nano) + gdb build via the repo Makefile.
#   $1 = install prefix     $2 = canadian-cross host ("" for a normal build->target)
gcc_build_into(){
  local prefix="$1" host="$2"
  log "configure (GCC + multilib newlib) -> $prefix${host:+ (canadian host=$host)}"
  rm -rf "$BUILD" && mkdir -p "$BUILD" && cd "$BUILD"
  "$SRC/configure" \
    --prefix="$prefix" \
    --with-arch="$ARCH" --with-abi="$ABI" \
    --with-isa-spec=20191213 \
    --with-multilib-generator="$MULTILIB" \
    --with-languages=c,c++ \
    --enable-strip \
    ${host:+--with-host="$host"} \
    --with-gcc-src="$SOURCES/gcc" \
    --with-binutils-src="$SOURCES/binutils" \
    --with-newlib-src="$SOURCES/newlib" \
    --with-gdb-src="$SOURCES/gdb"
  log "make newlib -j$NPROC -> $prefix"
  make -j"$NPROC" newlib ${GDB_EXTRA:+GDB_TARGET_FLAGS_EXTRA="$GDB_EXTRA"}
}

stage_gcc(){
  # Statically link the C++ runtime into the host tools so the binaries don't
  # carry GLIBCXX_*/CXXABI_* deps on a newer libstdc++.so than the deployment
  # box has. Applies to the GNU (gcc/g++) host -> Linux + the mingw Windows host;
  # NOT macOS (clang/libc++ has no static libstdc++).
  if [ "$HOSTOS" != macos ]; then
    export LDFLAGS="-static-libstdc++ -static-libgcc${LDFLAGS:+ $LDFLAGS}"
  fi

  if [ -n "$WITH_HOST" ]; then
    # Canadian cross (build=this machine, host=Windows, target=riscv): the host
    # cc1/xgcc are Windows .exe's that can't run here, so GCC needs a *native*
    # (build->target) riscv gcc on PATH to compile target libgcc/libstdc++ and
    # dump specs. The repo's --with-host doesn't build one (it just adds
    # --host=... everywhere), so do a native pre-pass into a throwaway prefix and
    # put it FIRST on PATH. The canadian pass installs the Windows .exe's into its
    # own $PREFIX; PATH order keeps the runnable native gcc for target steps.
    local NATIVE="$WORK/native-toolchain"
    if [ ! -x "$NATIVE/bin/${TUPLE}-gcc" ]; then
      log "native pre-pass for the canadian cross -> $NATIVE"
      gcc_build_into "$NATIVE" ""
    fi
    export PATH="$NATIVE/bin:$PATH"
    log "native build->target compiler on PATH: $(command -v "${TUPLE}-gcc")"

    # gdb needs host gmp/mpfr (not packaged for mingw) -> cross-built into the
    # mingw sysroot; and the canadian gdb can't use the build host's Python.
    local DEPS; DEPS="$(HOST="$WITH_HOST" WORK="$WORK" bash "$SRC/build/prepare-mingw-deps.sh" | tail -1)"
    GDB_EXTRA="--with-gmp=$DEPS --with-mpfr=$DEPS --without-python"
    log "mingw gdb deps in $DEPS; GDB_TARGET_FLAGS_EXTRA=$GDB_EXTRA"
  fi

  gcc_build_into "$PREFIX" "$WITH_HOST"
  log "GCC pass done; sanity check"
  if [ -z "$WITH_HOST" ]; then
    "$PREFIX/bin/${TUPLE}-gcc" -v 2>&1 | tail -3 || true
    "$PREFIX/bin/${TUPLE}-gcc" -print-multi-lib || true
  fi
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

stage_package(){
  log "package"
  echo "before: $(du -sh "$PREFIX" | cut -f1)"
  # Strip standalone executables / shared libs; skip ar archives (.a) so they stay linkable.
  find "$PREFIX" -type f -exec sh -c '
    t=$(file -b "$1")
    case "$t" in
      *ELF*executable*|*ELF*shared*|*Mach-O*executable*|*Mach-O*dynamically*|*PE32*executable*) strip "$1" 2>/dev/null || true ;;
    esac' _ {} \; || true
  echo "after strip: $(du -sh "$PREFIX" | cut -f1)"
  if [ -x "$SRC/.github/dedup-dir.sh" ]; then "$SRC/.github/dedup-dir.sh" "$PREFIX" || true; fi
  echo "after dedup: $(du -sh "$PREFIX" | cut -f1)"
  mkdir -p "$OUT"
  local name="riscv32-imafdc-elf-${HOSTARCH}-${HOSTOS}-gcc-clang"
  XZ_OPT="-e -T0" tar cJf "$OUT/${name}.tar.xz" -C "$(dirname "$PREFIX")" "$(basename "$PREFIX")"
  log "wrote $OUT/${name}.tar.xz ($(du -h "$OUT/${name}.tar.xz" | cut -f1))"
}

case "$STAGE" in
  gcc)     stage_gcc ;;
  clang)   stage_clang ;;
  package) stage_package ;;
  all)     stage_gcc; stage_clang; stage_package ;;
  *) echo "usage: $0 {gcc|clang|package|all}"; exit 2 ;;
esac
log "stage '$STAGE' complete"
