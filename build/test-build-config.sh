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
FAKE_LLVM_MINGW="$TMP/llvm-mingw"
CAPTURE_DIR="$TMP/capture"

mkdir -p \
    "$FAKE_BIN" \
    "$FAKE_SRC/build" \
    "$FAKE_SRC/gdb" \
    "$FAKE_SRC/llvm/clang/lib/Driver/ToolChains" \
    "$FAKE_SRC/llvm/llvm" \
    "$FAKE_DEPS/include" \
    "$FAKE_DEPS/lib" \
    "$FAKE_LLVM_MINGW/bin" \
    "$CAPTURE_DIR"

cp "$ROOT/llvm/clang/lib/Driver/ToolChains/Gnu.cpp" \
    "$FAKE_SRC/llvm/clang/lib/Driver/ToolChains/Gnu.cpp"
cp "$ROOT/llvm/clang/lib/Driver/ToolChains/Gnu.cpp" \
    "$TMP/Gnu.cpp.pristine"
cp "$ROOT/build/apply-llvm-patches.sh" "$FAKE_SRC/build/"
mkdir -p "$FAKE_SRC/patch"
cp "$ROOT/patch/llvm-riscv-gcc14-multilib.patch" "$FAKE_SRC/patch/"
git -C "$FAKE_SRC/llvm" init -q

export CAPTURE_DIR FAKE_DEPS

cat > "$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -m) printf 'x86_64\n' ;;
    *) printf '%s\n' "${FAKE_UNAME_SYSTEM:-Linux}" ;;
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

cat > "$FAKE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
printf 'PE32+ executable (console) x86-64\n'
EOF

cat > "$FAKE_BIN/patch" <<'EOF'
#!/usr/bin/env bash
echo "host patch implementation must not be used for LLVM sources" >&2
exit 97
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

for tool in \
    x86_64-w64-mingw32-clang \
    x86_64-w64-mingw32-clang++ \
    x86_64-w64-mingw32-windres \
    llvm-ar \
    llvm-ranlib \
    llvm-strip; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_LLVM_MINGW/bin/$tool"
    chmod +x "$FAKE_LLVM_MINGW/bin/$tool"
done

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_gdb_embeds_static_expat() {
    local gdb_flags

    gdb_flags="$(sed -n 's/^GDB_TARGET_FLAGS_EXTRA=//p' \
        "$CAPTURE_DIR/make.args")"

    for expected in \
        '--with-expat=yes' \
        "--with-libexpat-prefix=$FAKE_DEPS" \
        '--with-libexpat-type=auto' \
        '--enable-tui' \
        '--with-curses'; do
        case " $gdb_flags " in
            *" $expected "*) ;;
            *)
                cat "$CAPTURE_DIR/make.args" >&2
                fail "GDB configure flags are missing $expected"
                ;;
        esac
    done

    case " $gdb_flags " in
        *" --with-expat=$FAKE_DEPS "*)
            cat "$CAPTURE_DIR/make.args" >&2
            fail "GDB uses its boolean --with-expat option as a path"
            ;;
    esac

    case " $gdb_flags " in
        *" --with-libexpat-type=static "*)
            cat "$CAPTURE_DIR/make.args" >&2
            fail "GDB forces Expat system dependencies such as libm to be static"
            ;;
    esac
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

    cp "$TMP/Gnu.cpp.pristine" \
        "$FAKE_SRC/llvm/clang/lib/Driver/ToolChains/Gnu.cpp"

    PATH="$FAKE_BIN:$PATH" \
    SRC="$FAKE_SRC" \
    SOURCES="$TMP/sources" \
    WORK="$work" \
    PREFIX="$prefix" \
    OUT="$TMP/out" \
        bash "$ROOT/build/build-baremetal.sh" clang >/dev/null
}

run_macos_clang() {
    local prefix="$TMP/prefix-macos-clang"
    local work="$TMP/work-macos-clang"

    cp "$TMP/Gnu.cpp.pristine" \
        "$FAKE_SRC/llvm/clang/lib/Driver/ToolChains/Gnu.cpp"

    PATH="$FAKE_BIN:$PATH" \
    FAKE_UNAME_SYSTEM=Darwin \
    SRC="$FAKE_SRC" \
    SOURCES="$TMP/sources" \
    WORK="$work" \
    PREFIX="$prefix" \
    OUT="$TMP/out" \
        bash "$ROOT/build/build-baremetal.sh" clang >/dev/null
}

test_llvm_multilib_patch_is_host_patch_independent() {
    cp "$TMP/Gnu.cpp.pristine" \
        "$FAKE_SRC/llvm/clang/lib/Driver/ToolChains/Gnu.cpp"

    PATH="$FAKE_BIN:$PATH" \
        bash "$FAKE_SRC/build/apply-llvm-patches.sh" \
            "$FAKE_SRC/llvm" >/dev/null || {
        fail "LLVM multilib patch depends on the host patch implementation"
    }
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
    LLVM_MINGW_ROOT="$TMP/does-not-exist" \
    WITH_HOST=x86_64-w64-mingw32 \
        bash "$ROOT/build/build-baremetal.sh" gcc >/dev/null
}

run_windows_clang() {
    local prefix="$TMP/prefix-windows-clang"
    local work="$TMP/work-windows-clang"

    cp "$TMP/Gnu.cpp.pristine" \
        "$FAKE_SRC/llvm/clang/lib/Driver/ToolChains/Gnu.cpp"

    mkdir -p "$work/llvm-native-tblgen/bin"
    for tool in llvm-tblgen clang-tblgen; do
        printf '#!/usr/bin/env bash\nexit 0\n' \
            > "$work/llvm-native-tblgen/bin/$tool"
        chmod +x "$work/llvm-native-tblgen/bin/$tool"
    done

    PATH="$FAKE_BIN:$PATH" \
    SRC="$FAKE_SRC" \
    SOURCES="$TMP/sources" \
    WORK="$work" \
    PREFIX="$prefix" \
    OUT="$TMP/out" \
    LLVM_MINGW_ROOT="$FAKE_LLVM_MINGW" \
    WITH_HOST=x86_64-w64-mingw32 \
        bash "$ROOT/build/build-baremetal.sh" clang >/dev/null
}

test_linux_gcc_disables_libcc1() {
    run_linux_gcc

    grep -Fq -- '--disable-libcc1' "$CAPTURE_DIR/make.args" || {
        cat "$CAPTURE_DIR/make.args" >&2
        fail "Linux GCC configure flags do not disable libcc1"
    }

    assert_gdb_embeds_static_expat
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

test_macos_clang_works_with_empty_static_link_flags() {
    if ! run_macos_clang; then
        fail "macOS LLVM configuration is not compatible with Bash 3.2 nounset"
    fi

    grep -Fxq -- '-DLLVM_STATIC_LINK_CXX_STDLIB=OFF' \
        "$CAPTURE_DIR/cmake.args" || {
        cat "$CAPTURE_DIR/cmake.args" >&2
        fail "macOS LLVM does not disable static C++ standard library linking"
    }

    if grep -Eq -- '^-DCMAKE_(EXE|SHARED|MODULE)_LINKER_FLAGS=' \
        "$CAPTURE_DIR/cmake.args"; then
        cat "$CAPTURE_DIR/cmake.args" >&2
        fail "macOS LLVM unexpectedly receives Linux-only static linker flags"
    fi
}

test_windows_gdb_statically_links_winpthread() {
    local gdb_flags gdb_make_flags make_output make_work

    run_windows_gcc

    assert_gdb_embeds_static_expat

    gdb_make_flags="$(sed -n 's/^GDB_TARGET_MAKE_FLAGS_EXTRA=//p' \
        "$CAPTURE_DIR/make.args")"

    [ "$gdb_make_flags" = \
        'LDFLAGS="-all-static -static-libgcc -static-libstdc++"' ] || {
        cat "$CAPTURE_DIR/make.args" >&2
        fail "Windows GDB build does not request Libtool's complete static linking mode"
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
            "GDB_TARGET_FLAGS_EXTRA=$gdb_flags" \
            "GDB_TARGET_MAKE_FLAGS_EXTRA=$gdb_make_flags"
    )" || fail "Makefile.in dry-run for Windows GDB failed"

    if grep -Eq -- \
        '^: -C build-gdb-newlib( |$).*LDFLAGS=.*-all-static' \
        <<<"$make_output"; then
        echo "$make_output" >&2
        fail "Libtool-only -all-static leaks into the top-level GDB build"
    fi

    grep -Fxq -- 'rm -f build-gdb-newlib/gdb/gdb.exe' \
        <<<"$make_output" || {
        echo "$make_output" >&2
        fail "Makefile.in does not force the Windows GDB executable to relink"
    }

    grep -Fxq -- \
        ': -C build-gdb-newlib/gdb LDFLAGS="-all-static -static-libgcc -static-libstdc++" gdb.exe' \
        <<<"$make_output" || {
        echo "$make_output" >&2
        fail "Makefile.in does not isolate complete static linking to gdb.exe"
    }
}

test_windows_clang_uses_pinned_llvm_mingw() {
    local variable tool expected no_root_status incomplete_status
    local incomplete_root="$TMP/incomplete-llvm-mingw"

    run_windows_clang

    for arch in rv32imafc_zicsr rv32imafdc_zicsr; do
        grep -Fq -- "{\"$arch\"," \
            "$FAKE_SRC/llvm/clang/lib/Driver/ToolChains/Gnu.cpp" || {
            fail "Windows LLVM source does not recognize GCC 14 multilib $arch"
        }
    done

    bash "$FAKE_SRC/build/apply-llvm-patches.sh" \
        "$FAKE_SRC/llvm" >/dev/null || {
        fail "LLVM multilib compatibility patch is not idempotent"
    }

    while IFS=' ' read -r variable tool; do
        expected="-$variable=$FAKE_LLVM_MINGW/bin/$tool"
        grep -Fxq -- "$expected" "$CAPTURE_DIR/cmake.args" || {
            cat "$CAPTURE_DIR/cmake.args" >&2
            fail "Windows LLVM configuration is missing $expected"
        }
    done <<'EOF'
DCMAKE_C_COMPILER x86_64-w64-mingw32-clang
DCMAKE_CXX_COMPILER x86_64-w64-mingw32-clang++
DCMAKE_RC_COMPILER x86_64-w64-mingw32-windres
DCMAKE_AR llvm-ar
DCMAKE_RANLIB llvm-ranlib
DCMAKE_STRIP llvm-strip
EOF

    for expected in \
        '-DLLVM_HOST_TRIPLE=x86_64-w64-windows-gnu' \
        '-DCMAKE_EXE_LINKER_FLAGS=-static' \
        '-DCMAKE_SHARED_LINKER_FLAGS=-static' \
        '-DCMAKE_MODULE_LINKER_FLAGS=-static'; do
        grep -Fxq -- "$expected" "$CAPTURE_DIR/cmake.args" || {
            cat "$CAPTURE_DIR/cmake.args" >&2
            fail "Windows LLVM configuration is missing $expected"
        }
    done

    if grep -Eq -- \
        '^-DCMAKE_(C|CXX)_COMPILER=.*x86_64-w64-mingw32-(gcc|g\+\+)$' \
        "$CAPTURE_DIR/cmake.args"; then
        cat "$CAPTURE_DIR/cmake.args" >&2
        fail "Windows LLVM still uses the GNU MinGW compiler driver"
    fi

    set +e
    env -u LLVM_MINGW_ROOT \
        PATH="$FAKE_BIN:$PATH" \
        SRC="$FAKE_SRC" \
        SOURCES="$TMP/sources" \
        WORK="$TMP/work-windows-clang-no-root" \
        PREFIX="$TMP/prefix-windows-clang-no-root" \
        OUT="$TMP/out" \
        WITH_HOST=x86_64-w64-mingw32 \
        bash "$ROOT/build/build-baremetal.sh" clang >/dev/null 2>&1
    no_root_status=$?
    set -e

    [ "$no_root_status" -ne 0 ] ||
        fail "Windows LLVM accepted a missing LLVM_MINGW_ROOT"

    mkdir -p "$incomplete_root/bin"
    cp "$FAKE_LLVM_MINGW/bin/x86_64-w64-mingw32-clang" \
        "$incomplete_root/bin/"

    set +e
    PATH="$FAKE_BIN:$PATH" \
    SRC="$FAKE_SRC" \
    SOURCES="$TMP/sources" \
    WORK="$TMP/work-windows-clang-incomplete-root" \
    PREFIX="$TMP/prefix-windows-clang-incomplete-root" \
    OUT="$TMP/out" \
    LLVM_MINGW_ROOT="$incomplete_root" \
    WITH_HOST=x86_64-w64-mingw32 \
        bash "$ROOT/build/build-baremetal.sh" clang >/dev/null 2>&1
    incomplete_status=$?
    set -e

    [ "$incomplete_status" -ne 0 ] ||
        fail "Windows LLVM accepted an incomplete llvm-mingw root"
}

run_test() {
    local name="$1"
    "$name"
    echo "PASS: $name"
}

case "$TEST_CASE" in
    llvm-multilib-patch-portable)
        run_test test_llvm_multilib_patch_is_host_patch_independent
        ;;
    linux-gcc-no-libcc1)
        run_test test_linux_gcc_disables_libcc1
        ;;
    linux-clang-static-libgcc)
        run_test test_linux_clang_statically_links_libgcc
        ;;
    macos-clang-no-static-gcc-flags)
        run_test test_macos_clang_works_with_empty_static_link_flags
        ;;
    windows-gdb-static-winpthread)
        run_test test_windows_gdb_statically_links_winpthread
        ;;
    windows-clang-llvm-mingw)
        run_test test_windows_clang_uses_pinned_llvm_mingw
        ;;
    all)
        run_test test_llvm_multilib_patch_is_host_patch_independent
        run_test test_linux_gcc_disables_libcc1
        run_test test_linux_clang_statically_links_libgcc
        run_test test_macos_clang_works_with_empty_static_link_flags
        run_test test_windows_gdb_statically_links_winpthread
        run_test test_windows_clang_uses_pinned_llvm_mingw
        ;;
    *)
        echo "usage: $0 {llvm-multilib-patch-portable|linux-gcc-no-libcc1|linux-clang-static-libgcc|macos-clang-no-static-gcc-flags|windows-gdb-static-winpthread|windows-clang-llvm-mingw|all}" >&2
        exit 2
        ;;
esac
