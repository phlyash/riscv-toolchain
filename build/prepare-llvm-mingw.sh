#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fetch-source.sh
source "$SCRIPT_DIR/fetch-source.sh"

LLVM_MINGW_VERSION=20260616
LLVM_MINGW_VARIANT=msvcrt
LLVM_MINGW_ASSET="llvm-mingw-20260616-msvcrt-ubuntu-22.04-x86_64.tar.xz"
LLVM_MINGW_SHA256=a1f7968b48ba8d949194d6dee6c76f3cd0f61cba91658599af2c2c834a55ab87
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20260616/$LLVM_MINGW_ASSET"

LLVM_MINGW_TEMP_ROOT=""

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

verify_archive() {
    local archive="$1"
    local expected="$2"
    local actual

    actual="$(sha256_file "$archive")" || return 1
    if [ "$actual" != "$expected" ]; then
        echo "llvm-mingw SHA-256 mismatch: $archive" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        return 1
    fi
}

validate_root() {
    local root="$1"
    local tool

    for tool in \
        bin/x86_64-w64-mingw32-clang \
        bin/x86_64-w64-mingw32-clang++ \
        bin/x86_64-w64-mingw32-windres \
        bin/llvm-ar \
        bin/llvm-ranlib \
        bin/llvm-strip; do
        if [ ! -x "$root/$tool" ]; then
            echo "llvm-mingw is missing executable: $root/$tool" >&2
            return 1
        fi
    done
}

cleanup_llvm_mingw_temp() {
    if [ -n "$LLVM_MINGW_TEMP_ROOT" ] &&
       [ -d "$LLVM_MINGW_TEMP_ROOT" ]; then
        rm -rf -- "$LLVM_MINGW_TEMP_ROOT"
    fi
}

main() {
    local version="$1"
    local variant="$2"
    local asset="$3"
    local expected_sha256="$4"
    local url="$5"
    local work archive install_root

    work="${WORK:-/work}"
    mkdir -p "$work/downloads"
    work="$(cd "$work" && pwd -P)"
    archive="$work/downloads/$asset"
    install_root="$work/llvm-mingw-$version-$variant"

    if [ -f "$install_root/.complete" ] && validate_root "$install_root"; then
        printf '%s\n' "$install_root"
        return 0
    fi

    if [ -e "$install_root" ]; then
        rm -rf -- "$install_root"
    fi

    if [ -f "$archive" ] && ! verify_archive "$archive" "$expected_sha256"; then
        rm -f -- "$archive"
    fi

    if [ ! -f "$archive" ]; then
        fetch_source "$archive" "$url"
    fi

    if ! verify_archive "$archive" "$expected_sha256"; then
        rm -f -- "$archive"
        return 1
    fi

    LLVM_MINGW_TEMP_ROOT="$(
        mktemp -d "$work/.llvm-mingw-$version-$variant.XXXXXX"
    )"
    trap cleanup_llvm_mingw_temp EXIT

    if ! tar -xJf "$archive" -C "$LLVM_MINGW_TEMP_ROOT" \
        --strip-components=1; then
        return 1
    fi
    validate_root "$LLVM_MINGW_TEMP_ROOT" || return 1
    touch "$LLVM_MINGW_TEMP_ROOT/.complete"

    if ! mv "$LLVM_MINGW_TEMP_ROOT" "$install_root"; then
        return 1
    fi
    LLVM_MINGW_TEMP_ROOT=""
    trap - EXIT

    printf '%s\n' "$install_root"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main \
        "$LLVM_MINGW_VERSION" \
        "$LLVM_MINGW_VARIANT" \
        "$LLVM_MINGW_ASSET" \
        "$LLVM_MINGW_SHA256" \
        "$LLVM_MINGW_URL"
fi
