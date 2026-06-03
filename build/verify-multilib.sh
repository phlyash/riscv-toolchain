#!/usr/bin/env bash
#
# Verify the GCC multilib set and the clang<->gcc agreement for the NIIET RISC-V
# baremetal toolchain. For each shipped arch/abi pair this checks:
#   (1) clang accepts -march (compile to object) — catches a clang that can't parse
#       the P extension or a normalized-arch surprise;
#   (2) gcc and clang select the SAME multilib directory (-print-multi-directory)
#       — the core "matching sets" guarantee;
#   (3) gcc links a trivial program with --specs=nosys.specs — proves the multilib
#       .a set (libc/libgcc/libnosys) for that variant is actually present.
# Exits non-zero (failing CI) on any mismatch, parse error, or link failure.
#
# Needs a RUNNABLE native gcc + clang, so run on the Linux host only.
#   PREFIX=/opt/riscv bash build/verify-multilib.sh
#
set -uo pipefail

PREFIX="${PREFIX:-/opt/riscv}"
TUPLE=riscv32-unknown-elf
GCC="$PREFIX/bin/${TUPLE}-gcc"
CLANG="$PREFIX/bin/clang"
SYSROOT="$PREFIX/${TUPLE}"

# The 8 built multilibs (must match MULTILIB in build-baremetal.sh).
PAIRS="
rv32i:ilp32
rv32im:ilp32
rv32imc:ilp32
rv32imac:ilp32
rv32imafc:ilp32f
rv32imafdc:ilp32d
rv32imcp:ilp32
rv32imafdcp:ilp32d
"

echo "=== gcc -print-multi-lib ==="
"$GCC" -print-multi-lib || true
echo

fail=0
tmp="$(mktemp -d)"
echo 'int main(void){return 0;}' > "$tmp/t.c"
CFLAGS_COMMON=(--target="$TUPLE" --gcc-toolchain="$PREFIX" --sysroot="$SYSROOT")

for p in $PAIRS; do
  arch="${p%%:*}"; abi="${p##*:}"

  # (1) clang accepts -march (compile only)
  if ! "$CLANG" "${CFLAGS_COMMON[@]}" -march="$arch" -mabi="$abi" -c "$tmp/t.c" -o "$tmp/t.o" 2>"$tmp/err"; then
    echo "CLANG-MARCH FAIL $arch/$abi:"; cat "$tmp/err"; fail=1; continue
  fi

  # (2) gcc and clang must pick the same multilib dir
  gdir="$("$GCC" -march="$arch" -mabi="$abi" -print-multi-directory 2>/dev/null)"
  cdir="$("$CLANG" "${CFLAGS_COMMON[@]}" -march="$arch" -mabi="$abi" -print-multi-directory 2>/dev/null)"
  if [ "$gdir" != "$cdir" ]; then
    echo "DIR-MISMATCH $arch/$abi: gcc=[$gdir] clang=[$cdir]"; fail=1
  fi

  # (3) the multilib .a set links (via gcc + nosys specs)
  if ! "$GCC" -march="$arch" -mabi="$abi" --specs=nosys.specs "$tmp/t.c" -o "$tmp/t.elf" 2>"$tmp/err"; then
    echo "GCC-LINK FAIL $arch/$abi:"; cat "$tmp/err"; fail=1; continue
  fi

  [ "$fail" = 0 ] && echo "ok  $arch/$abi -> ${gdir:-.}"
done
rm -rf "$tmp"

if [ "$fail" = 0 ]; then
  echo "=== ALL MULTILIBS VERIFIED (clang==gcc, links ok) ==="
else
  echo "=== MULTILIB VERIFICATION FAILED ==="
fi
exit "$fail"
