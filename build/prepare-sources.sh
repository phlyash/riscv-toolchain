#!/usr/bin/env bash
#
# Assemble the patched source trees the baremetal toolchain builds from:
#   $SOURCES/binutils   (pinned base + patch/riscv-binutils.patch)
#   $SOURCES/gcc        (pinned base + patch/riscv-gcc.patch)
#   $SOURCES/newlib     (pinned base + patch/riscv-newlib.patch)
#   $SOURCES/llvm-snippy (Syntacore LLVM fork; clang/lld source)
#
# Pinned bases come from patch/riscv-gnu-toolchain-from-github.sh (CloudBEAR/NIIET).
# Robust against flaky/proxied networks: HTTP/1.1 + treeless partial clone + retries.
#
#   SOURCES=/sources bash build/prepare-sources.sh
#
set -euo pipefail

SOURCES="${SOURCES:-/sources}"
PATCHDIR="${PATCHDIR:-$(cd "$(dirname "$0")/../patch" && pwd)}"
SNIPPY_REF="${SNIPPY_REF:-main}"   # branch/tag of syntacore/snippy for clang/lld
mkdir -p "$SOURCES"

GIT_ROBUST=(-c http.version=HTTP/1.1 -c http.postBuffer=1048576000 \
            -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=300)

# name | git url | pinned base sha | patch file
COMPONENTS=(
  "binutils|https://sourceware.org/git/binutils-gdb.git|675b9d6|riscv-binutils.patch"
  "gcc|https://github.com/gcc-mirror/gcc.git|cd0059a|riscv-gcc.patch"
  "newlib|https://sourceware.org/git/newlib-cygwin.git|26f7004|riscv-newlib.patch"
)

clone_checkout(){  # dir url sha
  local dir="$1" url="$2" sha="$3" a
  [ -e "$dir/.git" ] && { echo "  [skip] $dir already present"; return 0; }
  for a in 1 2 3 4; do
    echo "  [attempt $a] treeless partial clone $url"
    rm -rf "$dir"
    if git "${GIT_ROBUST[@]}" clone --filter=tree:0 --no-checkout --no-tags "$url" "$dir" \
       && git -C "$dir" "${GIT_ROBUST[@]}" checkout -q "$sha"; then
      return 0
    fi
    sleep 5
  done
  echo "  [FAIL] could not fetch $url @ $sha"; return 1
}

for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r name url sha patch <<<"$entry"
  echo "### $name (base $sha, $patch)"
  if [ -e "$SOURCES/$name/.git" ] && git -C "$SOURCES/$name" rev-parse HEAD >/dev/null 2>&1; then
    echo "  [skip] $SOURCES/$name already prepared ($(git -C "$SOURCES/$name" log --oneline -1))"
    continue
  fi
  clone_checkout "$SOURCES/$name" "$url" "$sha"
  echo "  applying $patch"
  git -C "$SOURCES/$name" -c user.name=ci -c user.email=ci@local am -3 "$PATCHDIR/$patch"
  echo "  [ok] $(git -C "$SOURCES/$name" log --oneline -1)"
done

echo "### llvm-snippy (Syntacore LLVM, ref $SNIPPY_REF)"
if [ -e "$SOURCES/llvm-snippy/.git" ]; then
  echo "  [skip] already present ($(git -C "$SOURCES/llvm-snippy" log --oneline -1))"
else
  for a in 1 2 3 4; do
    rm -rf "$SOURCES/llvm-snippy"
    if git "${GIT_ROBUST[@]}" clone --filter=tree:0 --no-tags --depth 1 -b "$SNIPPY_REF" \
       https://github.com/syntacore/snippy.git "$SOURCES/llvm-snippy"; then break; fi
    [ "$a" = 4 ] && { echo "  [FAIL] snippy clone"; exit 1; }
    sleep 5
  done
  echo "  [ok] $(git -C "$SOURCES/llvm-snippy" log --oneline -1)"
fi

echo "ALL SOURCES PREPARED in $SOURCES"
