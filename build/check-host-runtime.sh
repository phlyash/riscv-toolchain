#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/opt/riscv}"
WITH_HOST="${WITH_HOST:-}"
TUPLE="riscv32-unknown-elf"
fail=0

is_linux_system_library() {
    case "$1" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|\
        ld-linux-x86-64.so.2|ld-linux-aarch64.so.1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

check_linux() {
    local f="$1" deps dependency readelf
    readelf="${READELF:-readelf}"

    "$readelf" -h "$f" >/dev/null 2>&1 || return 0
    deps="$("$readelf" -d "$f" 2>/dev/null || true)"

    while IFS= read -r dependency; do
        [ -z "$dependency" ] && continue
        if ! is_linux_system_library "$dependency"; then
            echo "FORBIDDEN Linux runtime dependency: $f -> $dependency"
            echo "$deps"
            fail=1
        fi
    done < <(sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' <<<"$deps")
}

check_native_gdb_features() {
    local gdb="$PREFIX/bin/${TUPLE}-gdb"
    local cfg xml_file xml_output

    if ! cfg="$("$gdb" --configuration 2>&1)"; then
        echo "Unable to read GDB configuration: $gdb"
        echo "$cfg"
        fail=1
        return
    fi

    grep -q -- '--enable-tui' <<<"$cfg" || {
        echo "GDB built without --enable-tui"
        fail=1
    }
    grep -q -- '--with-curses' <<<"$cfg" || {
        echo "GDB built without --with-curses"
        fail=1
    }
    if grep -q -- '--without-expat' <<<"$cfg" ||
       ! grep -q -- '--with-expat' <<<"$cfg"; then
        echo "GDB built without --with-expat"
        fail=1
    fi

    xml_file="$(mktemp "${TMPDIR:-/tmp}/gdb-xml-check.XXXXXX")"
    printf '%s\n' '<?xml version="1.0"?><target>' > "$xml_file"
    xml_output="$(
        "$gdb" -nx -batch -ex "set tdesc filename $xml_file" 2>&1 || true
    )"
    rm -f "$xml_file"

    if grep -Fq 'XML support was disabled at compile time' <<<"$xml_output"; then
        echo "GDB XML parser is disabled"
        echo "$xml_output"
        fail=1
    elif ! grep -Eq \
        'while parsing target description|Could not load XML target description' \
        <<<"$xml_output"; then
        echo "GDB XML probe did not reach the XML parser"
        echo "$xml_output"
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

        check_native_gdb_features
        ;;

    Darwin)
        while IFS= read -r -d '' f; do
            check_macos "$f"
        done < <(find "$PREFIX" -type f -print0)

        check_native_gdb_features
        ;;
esac

[ "$fail" -eq 0 ] && echo "Host runtime dependency check passed."
exit "$fail"
