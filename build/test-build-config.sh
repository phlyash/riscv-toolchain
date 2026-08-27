#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_CASE="${1:-all}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REAL_MAKE="${MAKE:-}"
if [ -z "$REAL_MAKE" ]; then
    REAL_MAKE="$(command -v make || command -v gmake || true)"
fi

FAKE_BIN="$TMP/bin"
FAKE_SRC="$TMP/src"
FAKE_DEPS="$TMP/deps"
CAPTURE_DIR="$TMP/capture"

mkdir -p \
    "$FAKE_BIN" \
    "$FAKE_SRC/build" \
    "$FAKE_SRC/gdb" \
    "$FAKE_SRC/llvm/llvm" \
    "$FAKE_DEPS/include" \
    "$FAKE_DEPS/lib" \
    "$CAPTURE_DIR"

export CAPTURE_DIR FAKE_DEPS

cat > "$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -m) printf 'x86_64\n' ;;
    *) printf 'Linux\n' ;;
esac
EOF

cat > "$FAKE_BIN/cmake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CAPTURE_DIR/cmake.args"
EOF

cat > "$FAKE_BIN/ninja" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CAPTURE_DIR/ninja.args"

if [[ " $* " == *" install-distribution-stripped "* ]]; then
    mkdir -p "$PREFIX/bin"
    for tool in clang clangd clang-format clang-tidy lld; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$PREFIX/bin/$tool"
        chmod +x "$PREFIX/bin/$tool"
    done
fi
EOF

cat > "$FAKE_BIN/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CAPTURE_DIR/make.args"
printf 'CPPFLAGS=%s\nLDFLAGS=%s\n' \
    "${CPPFLAGS:-}" \
    "${LDFLAGS:-}" \
    > "$CAPTURE_DIR/make.env"

mkdir -p "$PREFIX/bin"
for tool in riscv32-unknown-elf-gcc riscv32-unknown-elf-gdb; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$PREFIX/bin/$tool"
    chmod +x "$PREFIX/bin/$tool"
done
EOF

cat > "$FAKE_BIN/x86_64-w64-mingw32-gcc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""

while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        out="$2"
        shift 2
    else
        shift
    fi
done

[ -z "$out" ] || : > "$out"
EOF

cat > "$FAKE_BIN/x86_64-w64-mingw32-objdump" <<'EOF'
#!/usr/bin/env bash
printf 'DLL Name: KERNEL32.dll\n'
EOF

cat > "$FAKE_SRC/configure" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CAPTURE_DIR/configure.args"
EOF

cat > "$FAKE_SRC/build/prepare-host-deps.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_DEPS"
EOF

cat > "$FAKE_SRC/build/prepare-mingw-deps.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_DEPS"
EOF

chmod +x "$FAKE_BIN"/* "$FAKE_SRC/configure"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_linux_gcc() {
    local prefix="$TMP/prefix-linux-gcc"
    local work="$TMP/work-linux-gcc"

    PATH="$FAKE_BIN:$PATH" \
    SRC="$FAKE_SRC" \
    SOURCES="$TMP/sources" \
    WORK="$work" \
    PREFIX="$prefix" \
    OUT="$TMP/out" \
        bash "$ROOT/build/build-baremetal.sh" gcc >/dev/null
}

run_linux_clang() {
    local prefix="$TMP/prefix-linux-clang"
    local work="$TMP/work-linux-clang"

    PATH="$FAKE_BIN:$PATH" \
    SRC="$FAKE_SRC" \
    SOURCES="$TMP/sources" \
    WORK="$work" \
    PREFIX="$prefix" \
    OUT="$TMP/out" \
        bash "$ROOT/build/build-baremetal.sh" clang >/dev/null
}

run_windows_gcc() {
    local prefix="$TMP/prefix-windows-gcc"
    local work="$TMP/work-windows-gcc"

    mkdir -p "$work/native-toolchain/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' \
        > "$work/native-toolchain/bin/riscv32-unknown-elf-gcc"
    chmod +x "$work/native-toolchain/bin/riscv32-unknown-elf-gcc"

    PATH="$FAKE_BIN:$PATH" \
    SRC="$FAKE_SRC" \
    SOURCES="$TMP/sources" \
    WORK="$work" \
    PREFIX="$prefix" \
    OUT="$TMP/out" \
    WITH_HOST=x86_64-w64-mingw32 \
        bash "$ROOT/build/build-baremetal.sh" gcc >/dev/null
}

test_linux_gcc_disables_libcc1() {
    run_linux_gcc

    grep -Fq -- '--disable-libcc1' "$CAPTURE_DIR/make.args" || {
        cat "$CAPTURE_DIR/make.args" >&2
        fail "Linux GCC configure flags do not disable libcc1"
    }
}

test_linux_clang_statically_links_libgcc() {
    local kind expected

    run_linux_clang

    for kind in EXE SHARED MODULE; do
        expected="-DCMAKE_${kind}_LINKER_FLAGS=-static-libgcc"
        grep -Fxq -- "$expected" "$CAPTURE_DIR/cmake.args" || {
            cat "$CAPTURE_DIR/cmake.args" >&2
            fail "Linux LLVM $kind linker flags do not include -static-libgcc"
        }
    done
}

test_windows_gdb_statically_links_winpthread() {
    local gdb_flags make_output make_work

    run_windows_gcc

    grep -Eq \
        'GDB_TARGET_FLAGS_EXTRA=.*CFLAGS="[^"]*-static[^"]*".*CXXFLAGS="[^"]*-static[^"]*"' \
        "$CAPTURE_DIR/make.args" || {
        cat "$CAPTURE_DIR/make.args" >&2
        fail "Windows GDB configure flags do not pass -static through CFLAGS/CXXFLAGS"
    }

    if [ -z "$REAL_MAKE" ]; then
        echo "SKIP: GNU make is unavailable; driver arguments were checked" >&2
        return
    fi

    gdb_flags="$(sed -n 's/^GDB_TARGET_FLAGS_EXTRA=//p' "$CAPTURE_DIR/make.args")"
    make_work="$TMP/make-work"
    mkdir -p "$make_work"

    make_output="$(
        "$REAL_MAKE" \
            --no-print-directory \
            -C "$make_work" \
            -f "$ROOT/Makefile.in" \
            -n \
            stamps/build-gdb-newlib \
            MAKE=: \
            GDB_SRCDIR="$FAKE_SRC/gdb" \
            GDB_SRC_GIT= \
            PREPARATION_STAMP="$ROOT/build/build-baremetal.sh" \
            NEWLIB_TUPLE=riscv32-unknown-elf \
            CONFIGURE_HOST=--host=x86_64-w64-mingw32 \
            INSTALL_DIR="$TMP/make-prefix" \
            MULTILIB_FLAGS= \
            MULTILIB_GEN= \
            SIM=gdb \
            SED=sed \
            AWK=awk \
            srcdir="$ROOT" \
            builddir="$make_work" \
            "GDB_TARGET_FLAGS_EXTRA=$gdb_flags"
    )" || fail "Makefile.in dry-run for Windows GDB failed"

    grep -Fq -- 'CFLAGS="-O2 -static" CXXFLAGS="-O2 -static"' \
        <<<"$make_output" || {
        echo "$make_output" >&2
        fail "Makefile.in does not propagate static CFLAGS/CXXFLAGS to GDB configure"
    }
}

run_test() {
    local name="$1"
    "$name"
    echo "PASS: $name"
}

case "$TEST_CASE" in
    linux-gcc-no-libcc1)
        run_test test_linux_gcc_disables_libcc1
        ;;
    linux-clang-static-libgcc)
        run_test test_linux_clang_statically_links_libgcc
        ;;
    windows-gdb-static-winpthread)
        run_test test_windows_gdb_statically_links_winpthread
        ;;
    all)
        run_test test_linux_gcc_disables_libcc1
        run_test test_linux_clang_statically_links_libgcc
        run_test test_windows_gdb_statically_links_winpthread
        ;;
    *)
        echo "usage: $0 {linux-gcc-no-libcc1|linux-clang-static-libgcc|windows-gdb-static-winpthread|all}" >&2
        exit 2
        ;;
esac
