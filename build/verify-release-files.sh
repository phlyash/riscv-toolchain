#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 RELEASE_DIR" >&2
    exit 2
fi

RELEASE_DIR="$1"
EXPECTED_FILES=(
    niiet-riscv-toolchain-linux-x86_64.tar.gz
    niiet-riscv-toolchain-linux-x86_64.zip
    niiet-riscv-toolchain-macos-aarch64.tar.gz
    niiet-riscv-toolchain-macos-aarch64.zip
    niiet-riscv-toolchain-windows-x86_64.tar.gz
    niiet-riscv-toolchain-windows-x86_64.zip
)

if [ ! -d "$RELEASE_DIR" ]; then
    echo "release directory not found: $RELEASE_DIR" >&2
    exit 1
fi

shopt -s dotglob nullglob
release_files=("$RELEASE_DIR"/*)

if [ "${#release_files[@]}" -ne "${#EXPECTED_FILES[@]}" ]; then
    echo \
        "expected exactly six release files, found ${#release_files[@]}" \
        >&2
    exit 1
fi

for expected_file in "${EXPECTED_FILES[@]}"; do
    if [ ! -f "$RELEASE_DIR/$expected_file" ]; then
        echo "missing release file: $expected_file" >&2
        exit 1
    fi
done

echo "Verified six release archives in $RELEASE_DIR"
