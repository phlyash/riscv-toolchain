#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PREFIX_FIXTURE="$TMP/prefix"
FAKE_READELF="$TMP/readelf"
mkdir -p "$PREFIX_FIXTURE/bin"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat > "$FAKE_READELF" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    -h)
        printf 'ELF Header:\n  Class: ELF64\n'
        ;;
    -d)
        for dependency in ${FAKE_NEEDED:-}; do
            printf ' 0x0000000000000001 (NEEDED) Shared library: [%s]\n' \
                "$dependency"
        done
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat > "$PREFIX_FIXTURE/bin/riscv32-unknown-elf-gdb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--configuration" ]; then
    printf '%s\n' "${FAKE_GDB_CONFIGURATION:?}"
    exit 0
fi

printf '%s\n' "${FAKE_GDB_XML_OUTPUT:?}" >&2
exit 1
EOF

chmod +x "$FAKE_READELF" "$PREFIX_FIXTURE/bin/riscv32-unknown-elf-gdb"

run_check() {
    local needed="$1"
    local configuration="$2"
    local xml_output="$3"

    FAKE_NEEDED="$needed" \
    FAKE_GDB_CONFIGURATION="$configuration" \
    FAKE_GDB_XML_OUTPUT="$xml_output" \
    READELF="$FAKE_READELF" \
    PREFIX="$PREFIX_FIXTURE" \
    WITH_HOST=Linux \
        bash "$ROOT/build/check-host-runtime.sh" 2>&1
}

run_allowed() {
    local needed="$1" output

    output="$(run_check \
        "$needed" \
        $'--enable-tui\n--with-curses\n--with-expat' \
        'warning: while parsing target description: no element found')" || {
        echo "$output" >&2
        fail "allowed glibc dependencies or working XML support were rejected"
    }

    grep -Fq 'Host runtime dependency check passed.' <<<"$output" || {
        echo "$output" >&2
        fail "successful runtime check did not report success"
    }
}

run_forbidden_dependency() {
    local needed="$1"
    local rejected="$2"
    local output status

    set +e
    output="$(run_check \
        "$needed" \
        $'--enable-tui\n--with-curses\n--with-expat' \
        'warning: while parsing target description: no element found')"
    status=$?
    set -e

    [ "$status" -eq 1 ] || {
        echo "$output" >&2
        fail "forbidden dependency $rejected was accepted"
    }
    grep -Fq 'FORBIDDEN Linux runtime dependency' <<<"$output" || {
        echo "$output" >&2
        fail "forbidden dependency failure did not identify the file"
    }
    grep -Fq "$rejected" <<<"$output" || {
        echo "$output" >&2
        fail "forbidden dependency failure did not name $rejected"
    }
}

run_forbidden_gdb_configuration() {
    local output status

    set +e
    output="$(run_check \
        'libc.so.6 libm.so.6' \
        $'--enable-tui\n--with-curses\n--without-expat' \
        'warning: Can not parse XML target description; XML support was disabled at compile time')"
    status=$?
    set -e

    [ "$status" -eq 1 ] || {
        echo "$output" >&2
        fail "GDB configured without expat was accepted"
    }
    grep -Fq 'GDB built without --with-expat' <<<"$output" || {
        echo "$output" >&2
        fail "missing expat configuration was not diagnosed"
    }
}

run_forbidden_gdb_xml_runtime() {
    local output status

    set +e
    output="$(run_check \
        'libc.so.6 libm.so.6' \
        $'--enable-tui\n--with-curses\n--with-expat' \
        'warning: Can not parse XML target description; XML support was disabled at compile time')"
    status=$?
    set -e

    [ "$status" -eq 1 ] || {
        echo "$output" >&2
        fail "GDB with disabled XML runtime was accepted"
    }
    grep -Fq 'GDB XML parser is disabled' <<<"$output" || {
        echo "$output" >&2
        fail "disabled XML runtime was not diagnosed"
    }
}

run_allowed \
    'libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-x86-64.so.2'
run_allowed 'libc.so.6 libm.so.6 ld-linux-aarch64.so.1'
run_forbidden_dependency 'libc.so.6 libexpat.so.1' 'libexpat.so.1'
run_forbidden_dependency 'libc.so.6 libcurl.so.4' 'libcurl.so.4'
run_forbidden_gdb_configuration
run_forbidden_gdb_xml_runtime

echo "PASS: host runtime dependencies and GDB XML support fail closed"
