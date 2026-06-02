#!/usr/bin/env bash
#
# Build the NIIET RISC-V baremetal (newlib) toolchain: GCC + clang(snippy)/lld,
# reduced rv32 multilib, as small as possible.
#
# Runs both locally (inside build/Dockerfile.linux) and in CI. All paths are
# environment variables with container-friendly defaults:
#   SRC      this riscv-gnu-toolchain checkout        (default /src)
#   SOURCES  patched trees: binutils gcc newlib llvm-snippy [gdb]  (default /sources)
#   WORK     scratch build dir (fast local IO)        (default /work)
#   PREFIX   install prefix                           (default /opt/riscv)
#   OUT      directory to receive the tarball         (default /out)
#   WITH_HOST  optional canadian-cross host, e.g. x86_64-w64-mingw32 (Windows)
#
# Stages:  gcc | clang | package | all
#
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
ARCH=rv32imafdc_zicsr_zifencei
ABI=ilp32d
TUPLE=riscv32-unknown-elf

# Reduced rv32 imafdc subset chain. newlib-nano built automatically.
# Last entry: bare rv32imafdc/ilp32d (double-float) so '-march=rv32imafdc -mabi=ilp32d'
# without the explicit zicsr/zifencei suffix resolves to a real multilib.
MULTILIB="rv32i_zicsr_zifencei-ilp32--;rv32im_zicsr_zifencei-ilp32--;rv32imc_zicsr_zifencei-ilp32--;rv32imac_zicsr_zifencei-ilp32--;rv32imafc_zicsr_zifencei-ilp32f--;rv32imafdc_zicsr_zifencei-ilp32d--;rv32imafdc-ilp32d--"

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

# Build clang/lld from Syntacore's LLVM directly with cmake, targeting baremetal
# and reusing the Pass-1 GCC sysroot. Installs ONLY clang + builtin headers + lld,
# stripped (LLVM distribution-components) — keeps it small and avoids clobbering
# the multilib GCC that the Makefile's --enable-llvm path would.
stage_clang(){
  if [ -n "$WITH_HOST" ]; then
    log "SKIP clang: cross-building clang to '$WITH_HOST' is not wired yet (TODO: mingw toolchain file + native tablegen). GNU toolchain only for this host."
    return 0
  fi
  log "configure + build clang/lld from snippy LLVM (minimal distribution)"
  rm -rf "$LB" && mkdir -p "$LB" && cd "$LB"
  local PY; PY="$(command -v python3.11 || command -v python3)"
  local LLVM_DIST="clang;clang-resource-headers;lld"
  # Same portability goal as the GNU host: statically link libstdc++/libgcc into
  # the clang/lld binaries (LLVM_STATIC_LINK_CXX_STDLIB) on Linux. Not on macOS.
  local LLVM_STATIC_CXX=OFF
  [ "$HOSTOS" != macos ] && LLVM_STATIC_CXX=ON
  cmake -G Ninja "$SOURCES/llvm-snippy/llvm" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DLLVM_STATIC_LINK_CXX_STDLIB="$LLVM_STATIC_CXX" \
    -DPython3_EXECUTABLE="$PY" \
    -DLLVM_TARGETS_TO_BUILD="RISCV" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$TUPLE" \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=On \
    -DLLVM_ENABLE_SPHINX=OFF \
    -DLLVM_PARALLEL_LINK_JOBS=2 \
    -DLLVM_BINUTILS_INCDIR="$SOURCES/binutils/include" \
    -DLLVM_DISTRIBUTION_COMPONENTS="$LLVM_DIST"
  ninja -j"$NPROC" distribution
  ninja install-distribution-stripped
  log "clang sanity check"
  "$PREFIX/bin/clang" --version || true
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
