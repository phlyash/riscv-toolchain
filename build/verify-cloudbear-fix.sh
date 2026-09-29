#!/usr/bin/env bash
#
# Verify that every installed target library carries the CloudBEAR 0001
# erratum workaround (-mfix-cloudbear-0001).
#
# The workaround emits a nop immediately before each iterative instruction:
#
#   div divu rem remu fdiv.s fdiv.d fsqrt.s fsqrt.d clmul clmulh clmulr
#
# This script disassembles every .a/.o under the target sysroot and the GCC
# runtime directory and fails if any of those instructions is not directly
# preceded by a nop. Hand-written assembly and inline asm are not rewritten
# by the compiler flag, so this also catches unpatched runtime sources.
#
# Before scanning, the checker is validated against a compiler-generated
# object without the flag (must be rejected) and with it (must pass).
#
# Usage:
#
#   PREFIX=/opt/riscv bash build/verify-cloudbear-fix.sh
#

set -uo pipefail

PREFIX="${PREFIX:-/opt/riscv}"
TUPLE="riscv32-unknown-elf"
GCC="$PREFIX/bin/${TUPLE}-gcc"
OBJDUMP="$PREFIX/bin/${TUPLE}-objdump"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for tool in "$GCC" "$OBJDUMP"; do
    if [ ! -x "$tool" ]; then
        echo "ERROR: tool is missing:"
        echo "  $tool"
        exit 2
    fi
done

# Print "<checked> <violations>" on the last line, preceded by one line per
# violation. Exit status 2 means objdump itself failed.
scan_file()
{
    local file="$1"

    if ! "$OBJDUMP" -d --no-show-raw-insn "$file" > "$tmp/disasm.txt" \
        2> "$tmp/objdump.err"; then
        echo "OBJDUMP FAIL $file"
        cat "$tmp/objdump.err"
        return 2
    fi

    awk -v file="$file" '
        BEGIN {
            split("div divu rem remu fdiv.s fdiv.d fsqrt.s fsqrt.d " \
                  "clmul clmulh clmulr", list, " ")
            for (i in list)
                guarded[list[i]] = 1
            checked = 0
            bad = 0
            member = ""
            func = ""
            prev = ""
        }
        /:[ \t]+file format / {
            member = $1
            sub(/:$/, "", member)
            prev = ""
            next
        }
        /^[0-9a-f]+ <.*>:$/ {
            func = $2
            prev = ""
            next
        }
        /^Disassembly of section / {
            prev = ""
            next
        }
        /^[ \t]*[0-9a-f]+:\t/ {
            n = split($0, field, "\t")
            if (n < 2)
                next
            insn = field[2]
            gsub(/[ \t]+$/, "", insn)
            sub(/[ \t].*$/, "", insn)
            if (insn in guarded) {
                checked++
                if (prev != "nop") {
                    bad++
                    addr = field[1]
                    gsub(/[ \t:]/, "", addr)
                    printf "  MISSING NOP %s(%s) %s+0x%s: %s after %s\n", \
                        file, member, func, addr, insn, \
                        (prev == "" ? "<start>" : prev)
                }
            }
            prev = insn
        }
        END {
            print checked, bad
        }
    ' "$tmp/disasm.txt"
}

self_test()
{
    local out counts

    cat > "$tmp/probe.c" <<'EOF'
int probe_div(int a, int b) { return a / b; }
unsigned probe_remu(unsigned a, unsigned b) { return a % b; }
float probe_fdiv(float a, float b) { return a / b; }
float probe_fsqrt(float a) { return __builtin_sqrtf(a); }
EOF

    local flags=(-march=rv32imafc -mabi=ilp32f -O2 -fno-math-errno -c)

    if ! "$GCC" "${flags[@]}" "$tmp/probe.c" -o "$tmp/probe-nofix.o" \
        2> "$tmp/error.log" ||
       ! "$GCC" "${flags[@]}" -mfix-cloudbear-0001 \
        "$tmp/probe.c" -o "$tmp/probe-fix.o" 2>> "$tmp/error.log"; then
        echo "SELF-TEST COMPILE FAIL"
        cat "$tmp/error.log"
        return 1
    fi

    out="$(scan_file "$tmp/probe-nofix.o")" || return 1
    counts="$(tail -n 1 <<<"$out")"
    if [ "${counts% *}" -lt 4 ] || [ "${counts#* }" -lt 4 ]; then
        echo "SELF-TEST FAIL: checker did not reject an object built without the flag"
        echo "$out"
        return 1
    fi

    out="$(scan_file "$tmp/probe-fix.o")" || return 1
    counts="$(tail -n 1 <<<"$out")"
    if [ "${counts% *}" -lt 4 ] || [ "${counts#* }" -ne 0 ]; then
        echo "SELF-TEST FAIL: -mfix-cloudbear-0001 output was not accepted"
        echo "$out"
        return 1
    fi

    echo "self-test: OK (no-flag object rejected, flagged object accepted)"
    return 0
}

echo "============================================================"
echo "CLOUDBEAR 0001 ERRATUM WORKAROUND IN TARGET LIBRARIES"
echo "============================================================"

if ! self_test; then
    exit 1
fi

fail=0
files=0
total_checked=0
total_bad=0

while IFS= read -r -d '' file; do
    files=$((files + 1))
    if ! out="$(scan_file "$file")"; then
        echo "$out"
        fail=1
        continue
    fi
    counts="$(tail -n 1 <<<"$out")"
    checked="${counts% *}"
    bad="${counts#* }"
    total_checked=$((total_checked + checked))
    total_bad=$((total_bad + bad))
    if [ "$bad" -ne 0 ]; then
        sed '$d' <<<"$out"
        fail=1
    fi
done < <(
    find "$PREFIX/$TUPLE/lib" "$PREFIX/lib/gcc/$TUPLE" \
        -type f \( -name '*.a' -o -name '*.o' \) -print0 | sort -z
)

echo
echo "files scanned:          $files"
echo "guarded instructions:   $total_checked"
echo "missing nop:            $total_bad"

if [ "$files" -eq 0 ] || [ "$total_checked" -eq 0 ]; then
    echo "FAIL: nothing was checked; the scan is vacuous"
    fail=1
fi

echo "============================================================"
if [ "$fail" -eq 0 ]; then
    echo "CLOUDBEAR 0001 VERIFICATION PASSED"
else
    echo "CLOUDBEAR 0001 VERIFICATION FAILED"
fi
echo "============================================================"

exit "$fail"
