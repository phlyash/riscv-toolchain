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

stage_gcc(){
  log "configure (GCC + multilib newlib)${WITH_HOST:+ canadian-cross host=$WITH_HOST}"
  rm -rf "$BUILD" && mkdir -p "$BUILD" && cd "$BUILD"
  "$SRC/configure" \
    --prefix="$PREFIX" \
    --with-arch="$ARCH" --with-abi="$ABI" \
    --with-multilib-generator="$MULTILIB" \
    --with-languages=c,c++ \
    --enable-strip \
    ${WITH_HOST:+--with-host="$WITH_HOST"} \
    ${WITH_HOST:+--disable-gdb} \
    --with-gcc-src="$SOURCES/gcc" \
    --with-binutils-src="$SOURCES/binutils" \
    --with-newlib-src="$SOURCES/newlib"
  log "make newlib -j$NPROC"
  make -j"$NPROC" newlib
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
  cmake -G Ninja "$SOURCES/llvm-snippy/llvm" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
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
