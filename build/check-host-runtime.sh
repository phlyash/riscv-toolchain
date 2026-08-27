#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/opt/riscv}"
WITH_HOST="${WITH_HOST:-}"
TUPLE="riscv32-unknown-elf"
fail=0

check_linux() {
    local f="$1" deps
    file -b "$f" 2>/dev/null | grep -Eq 'ELF .* (executable|shared object)' || return 0
    deps="$(ldd "$f" 2>/dev/null || true)"

    if echo "$deps" | grep -Eqi 'lib(stdc\+\+|gcc_s|gmp|mpfr|mpc|isl|ncurses|tinfo|expat|zstd|lzma|readline|python|iconv|intl)[^ ]*\.so|libz\.so'; then
        echo "FORBIDDEN Linux runtime dependency: $f"
        echo "$deps"
        fail=1
    fi
}

check_macos() {
    local f="$1" deps
    file -b "$f" 2>/dev/null | grep -q 'Mach-O' || return 0
    deps="$(otool -L "$f" 2>/dev/null || true)"

    if echo "$deps" | grep -Eq '/opt/homebrew|/usr/local/(opt|Cellar)'; then
        echo "FORBIDDEN Homebrew runtime dependency: $f"
        echo "$deps"
        fail=1
    fi
}

is_windows_system_dll() {
    local d
    d="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

    case "$d" in
        kernel32.dll|kernelbase.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|shlwapi.dll|\
        ws2_32.dll|ole32.dll|oleaut32.dll|version.dll|comdlg32.dll|comctl32.dll|rpcrt4.dll|\
        crypt32.dll|bcrypt.dll|ntdll.dll|imm32.dll|winmm.dll|psapi.dll|iphlpapi.dll|dbghelp.dll|\
        secur32.dll|setupapi.dll|userenv.dll|netapi32.dll|normaliz.dll|dnsapi.dll|powrprof.dll|\
        imagehlp.dll|msvcrt.dll|ucrtbase.dll|api-ms-win-*.dll|ext-ms-win-*.dll)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

check_windows() {
    local f="$1" dll objdump
    objdump="${WITH_HOST:-x86_64-w64-mingw32}-objdump"

    while IFS= read -r dll; do
        [ -z "$dll" ] && continue

        if ! is_windows_system_dll "$dll"; then
            echo "FORBIDDEN Windows runtime DLL: $f -> $dll"
            fail=1
        fi
    done < <("$objdump" -p "$f" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name: //p')
}

case "${WITH_HOST:-$(uname -s)}" in
    *mingw*)
        while IFS= read -r -d '' f; do
            check_windows "$f"
        done < <(find "$PREFIX" -type f -name '*.exe' -print0)
        ;;

    Linux)
        while IFS= read -r -d '' f; do
            check_linux "$f"
        done < <(find "$PREFIX" -type f -print0)

        cfg="$("$PREFIX/bin/${TUPLE}-gdb" --configuration)"
        grep -q -- '--enable-tui' <<<"$cfg" || { echo "GDB built without --enable-tui"; fail=1; }
        grep -q -- '--with-curses' <<<"$cfg" || { echo "GDB built without --with-curses"; fail=1; }
        ;;

    Darwin)
        while IFS= read -r -d '' f; do
            check_macos "$f"
        done < <(find "$PREFIX" -type f -print0)

        cfg="$("$PREFIX/bin/${TUPLE}-gdb" --configuration)"
        grep -q -- '--enable-tui' <<<"$cfg" || { echo "GDB built without --enable-tui"; fail=1; }
        grep -q -- '--with-curses' <<<"$cfg" || { echo "GDB built without --with-curses"; fail=1; }
        ;;
esac

[ "$fail" -eq 0 ] && echo "Host runtime dependency check passed."
exit "$fail"
