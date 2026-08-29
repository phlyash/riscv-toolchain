#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="$SCRIPT_DIR/verify-release-files.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if [ ! -f "$VERIFIER" ]; then
    fail "release asset verifier is missing"
fi

DIST="$TEST_ROOT/dist"
mkdir -p "$DIST"

for archive in \
    niiet-riscv-toolchain-linux-x86_64.tar.gz \
    niiet-riscv-toolchain-linux-x86_64.zip \
    niiet-riscv-toolchain-macos-aarch64.tar.gz \
    niiet-riscv-toolchain-macos-aarch64.zip \
    niiet-riscv-toolchain-windows-x86_64.tar.gz \
    niiet-riscv-toolchain-windows-x86_64.zip
do
    : > "$DIST/$archive"
done

bash "$VERIFIER" "$DIST"

: > "$DIST/unexpected.txt"
if bash "$VERIFIER" "$DIST" >/dev/null 2>&1; then
    fail "release verifier accepted an unexpected file"
fi
rm -f "$DIST/unexpected.txt"

rm -f "$DIST/niiet-riscv-toolchain-windows-x86_64.zip"
if bash "$VERIFIER" "$DIST" >/dev/null 2>&1; then
    fail "release verifier accepted a missing platform archive"
fi

echo "PASS: release verifier requires exactly six platform archives"
