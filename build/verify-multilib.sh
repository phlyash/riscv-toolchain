#!/usr/bin/env bash
#
# Verify the NIIET RISC-V GCC + upstream LLVM/Clang SDK.
#
# GCC builds and owns the target runtime:
#
#   newlib
#   newlib-nano
#   libgcc
#   libstdc++
#
# Clang must be ABI-compatible with that runtime.
#
# Six standard multilibs are shared between GCC and Clang.
#
# Two NIIET/CloudBEAR P-extension multilibs remain GCC-only because
# upstream LLVM 22.1.8 implements a different experimental P revision.
#
# IMPORTANT:
#
# We intentionally do NOT require:
#
#   clang -print-multi-directory == gcc -print-multi-directory
#
# Clang may legally reuse a compatible GCC multilib and its built-in
# RISC-V GCC multilib detector does not reproduce every custom
# --with-multilib-generator layout exactly.
#
# Instead we verify the actual ABI contract:
#
#   clang compiles object
#        ↓
#   same GCC/newlib/libgcc/libstdc++ runtime links it successfully
#        ↓
#   clang's normal driver discovers and links that runtime itself
#
# Usage:
#
#   PREFIX=/opt/riscv bash build/verify-multilib.sh
#

set -uo pipefail

PREFIX="${PREFIX:-/opt/riscv}"
TUPLE="riscv32-unknown-elf"
GCC="$PREFIX/bin/${TUPLE}-gcc"
GXX="$PREFIX/bin/${TUPLE}-g++"
CLANG="$PREFIX/bin/clang"
CLANGXX="$PREFIX/bin/clang++"
SYSROOT="$PREFIX/$TUPLE"

COMMON_PAIRS=(
    "rv32i:ilp32"
    "rv32im:ilp32"
    "rv32imc:ilp32"
    "rv32imac:ilp32"
    "rv32imafc:ilp32f"
    "rv32imafdc:ilp32d"
)
GCC_ONLY_PAIRS=(
    "rv32imcp:ilp32"
    "rv32imafdcp:ilp32d"
)
fail=0
warnings=0

tmp="$(mktemp -d)"

trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/test.c" <<'EOF'
#include <stdint.h>

volatile uint32_t niiet_test_value;

int main(void)
{
    niiet_test_value = 0x12345678u;
    return niiet_test_value != 0x12345678u;
}
EOF

cat > "$tmp/test.cpp" <<'EOF'
#include <new>

struct TestObject
{
    int value;
};

int main()
{
    TestObject *p = new TestObject{42};

    int result = (p->value != 42);

    delete p;

    return result;
}
EOF

CLANG_COMMON=(
    --target="$TUPLE"
    --gcc-toolchain="$PREFIX"
    --sysroot="$SYSROOT"
)

require_file()
{
    local label="$1"
    local path="$2"

    if [ -z "$path" ] ||
       [ "$path" = "$label" ] ||
       [ ! -f "$path" ]; then
        echo "MISSING $label:"
        echo "  $path"
        return 1
    fi
    return 0
}


show_runtime()
{
    local arch="$1"
    local abi="$2"
    local libgcc
    local libc
    local libnosys
    local libstdcxx
    libgcc="$(
        "$GCC" \
            -march="$arch" \
            -mabi="$abi" \
            -print-libgcc-file-name
    )"
    libc="$(
        "$GCC" \
            -march="$arch" \
            -mabi="$abi" \
            -print-file-name=libc.a
    )"
    libnosys="$(
        "$GCC" \
            -march="$arch" \
            -mabi="$abi" \
            -print-file-name=libnosys.a
    )"
    libstdcxx="$(
        "$GXX" \
            -march="$arch" \
            -mabi="$abi" \
            -print-file-name=libstdc++.a
    )"
    echo "runtime:"
    echo "  libgcc:    $libgcc"
    echo "  libc:      $libc"
    echo "  libnosys:  $libnosys"
    echo "  libstdc++: $libstdcxx"

    require_file \
        "libgcc.a" \
        "$libgcc" \
        || return 1
    require_file \
        "libc.a" \
        "$libc" \
        || return 1
    require_file \
        "libnosys.a" \
        "$libnosys" \
        || return 1
    require_file \
        "libstdc++.a" \
        "$libstdcxx" \
        || return 1

    return 0
}

check_gcc_link()
{
    local arch="$1"
    local abi="$2"

    if ! "$GCC" \
        -march="$arch" \
        -mabi="$abi" \
        --specs=nosys.specs \
        "$tmp/test.c" \
        -o "$tmp/gcc-${arch}-${abi}.elf" \
        2>"$tmp/error.log"; then
        echo "GCC C LINK FAIL $arch/$abi"
        cat "$tmp/error.log"
        return 1
    fi

    return 0
}


check_clang_c()
{
    local arch="$1"
    local abi="$2"
    local obj="$tmp/clang-${arch}-${abi}.o"

    if ! "$CLANG" \
        "${CLANG_COMMON[@]}" \
        -march="$arch" \
        -mabi="$abi" \
        -c "$tmp/test.c" \
        -o "$obj" \
        2>"$tmp/error.log"; then
        echo "CLANG C COMPILE FAIL $arch/$abi"
        cat "$tmp/error.log"

        return 1
    fi


    #
    # Link the LLVM-generated object with the exact GCC-selected
    # newlib/libgcc runtime.
    #
    # This is the important ABI compatibility test.
    #

    if ! "$GCC" \
        -march="$arch" \
        -mabi="$abi" \
        --specs=nosys.specs \
        "$obj" \
        -o "$tmp/clang-gcc-${arch}-${abi}.elf" \
        2>"$tmp/error.log"; then
        echo "CLANG OBJECT + GCC RUNTIME LINK FAIL $arch/$abi"
        cat "$tmp/error.log"

        return 1
    fi

    return 0
}


check_clang_driver_link()
{
    local arch="$1"
    local abi="$2"

    if ! "$CLANG" \
        "${CLANG_COMMON[@]}" \
        -march="$arch" \
        -mabi="$abi" \
        --rtlib=libgcc \
        "$tmp/test.c" \
        -o "$tmp/clang-driver-${arch}-${abi}.elf" \
        2>"$tmp/error.log"; then
        echo "CLANG DRIVER + GCC RUNTIME LINK FAIL $arch/$abi"
        cat "$tmp/error.log"

        return 1
    fi

    return 0
}


check_clang_cpp()
{
    local arch="$1"
    local abi="$2"
    local obj="$tmp/clangxx-${arch}-${abi}.o"

    if ! "$CLANGXX" \
        "${CLANG_COMMON[@]}" \
        -stdlib=libstdc++ \
        -march="$arch" \
        -mabi="$abi" \
        -c "$tmp/test.cpp" \
        -o "$obj" \
        2>"$tmp/error.log"; then
        echo "CLANG C++ COMPILE FAIL $arch/$abi"
        cat "$tmp/error.log"

        return 1
    fi

    if ! "$GXX" \
        -march="$arch" \
        -mabi="$abi" \
        --specs=nosys.specs \
        "$obj" \
        -o "$tmp/clangxx-gcc-${arch}-${abi}.elf" \
        2>"$tmp/error.log"; then
        echo "CLANG C++ OBJECT + GCC RUNTIME LINK FAIL $arch/$abi"
        cat "$tmp/error.log"

        return 1
    fi

    return 0
}


show_multilib_selection()
{
    local arch="$1"
    local abi="$2"
    local gdir
    local cdir

    gdir="$(
        "$GCC" \
            -march="$arch" \
            -mabi="$abi" \
            -print-multi-directory \
            2>/dev/null \
        || true
    )"

    cdir="$(
        "$CLANG" \
            "${CLANG_COMMON[@]}" \
            -march="$arch" \
            -mabi="$abi" \
            -print-multi-directory \
            2>/dev/null \
        || true
    )"

    echo "multilib selection:"
    echo "  GCC:   ${gdir:-<none>}"
    echo "  Clang: ${cdir:-<none>}"

    if [ "$gdir" != "$cdir" ]; then
        echo \
            "  NOTE: GCC/Clang directory selection differs;" \
            "runtime compatibility is tested by actual compile+link."
        warnings=$((warnings + 1))

    fi
}

check_common_pair()
{
    local pair="$1"
    local arch="${pair%%:*}"
    local abi="${pair##*:}"
    local pair_fail=0

    echo
    echo "============================================================"
    echo "COMMON $arch / $abi"
    echo "============================================================"

    show_multilib_selection \
        "$arch" \
        "$abi"

    if ! show_runtime "$arch" "$abi"; then
        pair_fail=1
    fi

    if ! check_gcc_link "$arch" "$abi"; then
        pair_fail=1
    fi

    if ! check_clang_c "$arch" "$abi"; then
        pair_fail=1
    fi

    if ! check_clang_driver_link "$arch" "$abi"; then
        pair_fail=1
    fi

    if ! check_clang_cpp "$arch" "$abi"; then
        pair_fail=1
    fi

    if [ "$pair_fail" -eq 0 ]; then
        echo
        echo "PASS $arch/$abi"
        echo "  GCC runtime exists"
        echo "  GCC links"
        echo "  Clang C object links with GCC runtime"
        echo "  Clang driver selects and links the GCC runtime"
        echo "  Clang C++ object links with GCC libstdc++ runtime"
    else
        echo
        echo "FAIL $arch/$abi"
    fi

    return "$pair_fail"
}


check_gcc_only_pair()
{
    local pair="$1"
    local arch="${pair%%:*}"
    local abi="${pair##*:}"
    local pair_fail=0
    local gdir

    echo
    echo "============================================================"
    echo "NIIET P / GCC-ONLY $arch / $abi"
    echo "============================================================"

    if ! gdir="$(
        "$GCC" \
            -march="$arch" \
            -mabi="$abi" \
            -print-multi-directory \
            2>"$tmp/error.log"
    )"; then
        echo "GCC MULTILIB FAIL $arch/$abi"
        cat "$tmp/error.log"
        pair_fail=1
    else
        echo "GCC multilib:"
        echo "  $gdir"
    fi

    if ! show_runtime "$arch" "$abi"; then
        pair_fail=1
    fi

    if ! check_gcc_link "$arch" "$abi"; then
        pair_fail=1
    fi

    if [ "$pair_fail" -eq 0 ]; then
        echo
        echo "PASS $arch/$abi (GCC-only)"
    else
        echo
        echo "FAIL $arch/$abi"
    fi

    return "$pair_fail"
}

for tool in \
    "$GCC" \
    "$GXX" \
    "$CLANG" \
    "$CLANGXX"
do
    if [ ! -x "$tool" ]; then
        echo "ERROR: tool is missing:"
        echo "  $tool"
        exit 2
    fi
done

if [ ! -d "$SYSROOT" ]; then
    echo "ERROR: sysroot is missing:"
    echo "  $SYSROOT"
    exit 2
fi

echo "============================================================"
echo "GCC MULTILIB TABLE"
echo "============================================================"

"$GCC" -print-multi-lib
echo

echo "============================================================"
echo "SHARED GCC + CLANG VARIANTS"
echo "============================================================"

for pair in "${COMMON_PAIRS[@]}"; do
    check_common_pair "$pair" || fail=1
done

echo
echo "============================================================"
echo "NIIET P VARIANTS — GCC ONLY"
echo "============================================================"

for pair in "${GCC_ONLY_PAIRS[@]}"; do
    check_gcc_only_pair "$pair" || fail=1
done

echo
echo "============================================================"

if [ "$fail" -eq 0 ]; then
    echo "MULTILIB RUNTIME VERIFICATION PASSED"
    echo
    echo "Shared GCC/Clang variants: ${#COMMON_PAIRS[@]}"
    echo "GCC-only NIIET P variants: ${#GCC_ONLY_PAIRS[@]}"
    echo "Clang/GCC multilib-selection differences: $warnings"
    echo
    echo \
        "NOTE: directory-selection differences are informational." \
        "This test proves LLVM-generated objects are ABI-compatible" \
        "with the GCC-built newlib/libgcc/libstdc++ runtime."
else
    echo "MULTILIB RUNTIME VERIFICATION FAILED"
fi

echo "============================================================"

exit "$fail"
