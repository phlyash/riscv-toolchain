#!/usr/bin/env bash
# Apply the local Clang driver compatibility changes to the pinned LLVM tree.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LLVM_SRC="${1:-$ROOT/llvm}"
PATCH_FILE="$ROOT/patch/llvm-riscv-gcc14-multilib.patch"
GNU_TOOLCHAIN="$LLVM_SRC/clang/lib/Driver/ToolChains/Gnu.cpp"

single='{"rv32imafc_zicsr", "ilp32f"}'
double='{"rv32imafdc_zicsr", "ilp32d"}'

if [ ! -f "$GNU_TOOLCHAIN" ]; then
    echo "LLVM source is missing: $GNU_TOOLCHAIN" >&2
    exit 1
fi

has_single=0
has_double=0
grep -Fq -- "$single" "$GNU_TOOLCHAIN" && has_single=1
grep -Fq -- "$double" "$GNU_TOOLCHAIN" && has_double=1

if [ "$has_single" -eq 1 ] && [ "$has_double" -eq 1 ]; then
    echo "LLVM RISC-V GCC 14 multilib compatibility patch already applied"
    exit 0
fi

if [ "$has_single" -ne "$has_double" ]; then
    echo "LLVM RISC-V multilib source is only partially patched" >&2
    exit 1
fi

(
    cd "$LLVM_SRC"
    patch -f -p1 < "$PATCH_FILE"
)

grep -Fq -- "$single" "$GNU_TOOLCHAIN"
grep -Fq -- "$double" "$GNU_TOOLCHAIN"

echo "Applied LLVM RISC-V GCC 14 multilib compatibility patch"
