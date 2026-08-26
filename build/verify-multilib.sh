#!/usr/bin/env bash
#
# Verify the multilib layout of the NIIET RISC-V bare-metal SDK.
#
# The SDK ships 8 GCC/newlib multilib variants:
#   - 6 standard rv32 variants shared by GCC and upstream LLVM/Clang;
#   - 2 NIIET P-extension variants that are intentionally GCC-only.
#
# For COMMON_PAIRS this checks:
#   1. GCC selects the expected multilib directory.
#   2. Clang accepts the -march/-mabi pair.
#   3. Clang and GCC select the same GCC multilib directory.
#   4. GCC can link a trivial bare-metal program with nosys.specs.
#
# For GCC_ONLY_PAIRS this checks:
#   1. GCC selects the expected multilib directory.
#   2. GCC can link a trivial bare-metal program with nosys.specs.
#
# The NIIET P variants are not checked with upstream LLVM 22.1.8 because the
# NIIET/CloudBEAR GCC patch implements a different P-extension revision from
# upstream LLVM's experimental P support.
#
# Requires runnable host GCC and Clang binaries, so use it for native-host SDKs
# (Linux/macOS), not the Linux->Windows Canadian-cross output.
#
# Usage:
#   PREFIX=/opt/riscv bash build/verify-multilib.sh
#

set -uo pipefail

PREFIX="${PREFIX:-/opt/riscv}"
TUPLE="riscv32-unknown-elf"

GCC="$PREFIX/bin/${TUPLE}-gcc"
CLANG="$PREFIX/bin/clang"
SYSROOT="$PREFIX/${TUPLE}"

COMMON_PAIRS="
rv32i:ilp32
rv32im:ilp32
rv32imc:ilp32
rv32imac:ilp32
rv32imafc:ilp32f
rv32imafdc:ilp32d
"

GCC_ONLY_PAIRS="
rv32imcp:ilp32
rv32imafdcp:ilp32d
"

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/t.c" <<'EOF_C'
int main(void)
{
    return 0;
}
EOF_C
CLANG_COMMON=(
    --target="$TUPLE"
    --gcc-toolchain="$PREFIX"
    --sysroot="$SYSROOT"
)
expected_multilib_dir()
{
    local arch="$1"
    local abi="$2"
    if [ "$arch" = "rv32i" ] &&
       [ "$abi" = "ilp32" ]; then
        printf '%s\n' "."
    else
        printf '%s/%s\n' "$arch" "$abi"
    fi
}

check_gcc_multilib_dir()
{
    local arch="$1"
    local abi="$2"
    local expected="$3"
    local actual

    if ! actual="$(
        "$GCC" \
            -march="$arch" \
            -mabi="$abi" \
            -print-multi-directory \
            2>"$tmp/err"
    )"; then
        echo "GCC-MULTILIB FAIL $arch/$abi:"
        cat "$tmp/err"
        return 1
    fi
    if [ "$actual" != "$expected" ]; then
        echo \
            "GCC-DIR-MISMATCH $arch/$abi:" \
            "expected=[$expected]" \
            "actual=[$actual]"
        return 1
    fi
    printf '%s\n' "$actual"
}


check_gcc_link()
{
    local arch="$1"
    local abi="$2"
    if ! "$GCC" \
        -march="$arch" \
        -mabi="$abi" \
        --specs=nosys.specs \
        "$tmp/t.c" \
        -o "$tmp/gcc-${arch}-${abi}.elf" \
        2>"$tmp/err"; then
        echo "GCC-LINK FAIL $arch/$abi:"
        cat "$tmp/err"
        return 1
    fi
}


check_common_pair()
{
    local pair="$1"
    local arch="${pair%%:*}"
    local abi="${pair##*:}"
    local expected
    local gdir
    local cdir
    local pair_fail=0

    expected="$(
        expected_multilib_dir "$arch" "$abi"
    )"

    echo "--- common $arch/$abi ---"

    if ! gdir="$(
        check_gcc_multilib_dir \
            "$arch" \
            "$abi" \
            "$expected"
    )"; then

        pair_fail=1

    fi

    if ! "$CLANG" \
        "${CLANG_COMMON[@]}" \
        -march="$arch" \
        -mabi="$abi" \
        -c "$tmp/t.c" \
        -o "$tmp/clang-${arch}-${abi}.o" \
        2>"$tmp/err"; then
        echo "CLANG-MARCH FAIL $arch/$abi:"
        cat "$tmp/err"
        pair_fail=1
    fi

    if cdir="$(
        "$CLANG" \
            "${CLANG_COMMON[@]}" \
            -march="$arch" \
            -mabi="$abi" \
            -print-multi-directory \
            2>"$tmp/err"
    )"; then
        if [ -n "${gdir:-}" ] &&
           [ "$gdir" != "$cdir" ]; then
            echo \
                "DIR-MISMATCH $arch/$abi:" \
                "gcc=[$gdir]" \
                "clang=[$cdir]"
            pair_fail=1
        fi
    else
        echo "CLANG-MULTILIB FAIL $arch/$abi:"
        cat "$tmp/err"
        pair_fail=1
    fi
    if ! check_gcc_link "$arch" "$abi"; then
        pair_fail=1
    fi

    if [ "$pair_fail" -eq 0 ]; then
        echo \
            "ok  $arch/$abi -> ${gdir:-$expected}" \
            "(gcc == clang)"
    fi

    return "$pair_fail"
}


check_gcc_only_pair()
{
    local pair="$1"
    local arch="${pair%%:*}"
    local abi="${pair##*:}"
    local expected
    local gdir
    local pair_fail=0
    expected="$(
        expected_multilib_dir "$arch" "$abi"
    )"

    echo "--- gcc-only $arch/$abi ---"

    if ! gdir="$(
        check_gcc_multilib_dir \
            "$arch" \
            "$abi" \
            "$expected"
    )"; then
        pair_fail=1
    fi

    if ! check_gcc_link "$arch" "$abi"; then
        pair_fail=1
    fi

    if [ "$pair_fail" -eq 0 ]; then
        echo \
            "ok  $arch/$abi -> ${gdir:-$expected}" \
            "(NIIET P, GCC-only)"
    fi
    return "$pair_fail"
}

if [ ! -x "$GCC" ]; then
    echo "ERROR: GCC is not runnable:"
    echo "  $GCC"
    exit 2
fi


if [ ! -x "$CLANG" ]; then
    echo "ERROR: Clang is not runnable:"
    echo "  $CLANG"
    exit 2
fi

if [ ! -d "$SYSROOT" ]; then
    echo "ERROR: sysroot does not exist:"
    echo "  $SYSROOT"
    exit 2
fi

echo "=== GCC multilib table ==="
"$GCC" -print-multi-lib || fail=1
echo
echo "=== Shared GCC + Clang multilibs ==="
for pair in $COMMON_PAIRS; do
    check_common_pair "$pair" || fail=1
    echo
done

echo \
    "=== NIIET P multilibs" \
    "(GCC-only with upstream LLVM 22.1.8) ==="

for pair in $GCC_ONLY_PAIRS; do
    check_gcc_only_pair "$pair" || fail=1
    echo
done


if [ "$fail" -eq 0 ]; then
    echo "=== MULTILIB VERIFICATION PASSED ==="
    echo "6 shared GCC/Clang variants verified."
    echo "2 NIIET P variants verified with GCC only."

else
    echo "=== MULTILIB VERIFICATION FAILED ==="
fi

exit "$fail"
