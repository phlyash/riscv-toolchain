#!/usr/bin/env bash
#
# Prepare patched source trees for the NIIET bare-metal toolchain:
#
#   $SOURCES/binutils
#   $SOURCES/gcc
#   $SOURCES/newlib
#   $SOURCES/gdb
#
# GNU sources are pinned to the exact base commits used by the
# CloudBEAR/NIIET patches.
#
# GitHub mirrors are preferred in CI because sourceware.org may
# rate-limit GitHub-hosted runners with HTTP 429.
#
# Sourceware remains as a fallback.
#
# Usage:
#
#   SOURCES=/sources bash build/prepare-sources.sh
#

set -euo pipefail

SOURCES="${SOURCES:-/sources}"

PATCHDIR="${PATCHDIR:-$(
    cd "$(dirname "$0")/../patch"
    pwd
)}"

mkdir -p "$SOURCES"

GIT_ROBUST=(
    -c http.version=HTTP/1.1
    -c http.postBuffer=1048576000
    -c http.lowSpeedLimit=1000
    -c http.lowSpeedTime=300
)

#
# Format:
#
# name | base sha | patch | mirror1;mirror2;...
#
# RTEMS mirrors preserve the original Sourceware git history,
# therefore the pinned commit SHA values remain the same.
#

COMPONENTS=(
    "binutils|675b9d6|riscv-binutils.patch|https://github.com/RTEMS/sourceware-mirror-binutils-gdb.git;https://sourceware.org/git/binutils-gdb.git"
    "gcc|cd0059a|riscv-gcc.patch|https://github.com/gcc-mirror/gcc.git"
    "newlib|26f7004|riscv-newlib.patch|https://github.com/RTEMS/sourceware-mirror-newlib-cygwin.git;https://github.com/mirror/newlib-cygwin.git;https://sourceware.org/git/newlib-cygwin.git"
    "gdb|6bda1c1|riscv-gdb.patch|https://github.com/RTEMS/sourceware-mirror-binutils-gdb.git;https://sourceware.org/git/binutils-gdb.git"
)


clone_checkout()
{
    local dir="$1"
    local sha="$2"
    local urls_string="$3"

    local url
    local attempt

    local urls=()

    IFS=';' read -r -a urls <<<"$urls_string"

    rm -rf "$dir"

    for url in "${urls[@]}"; do
        echo
        echo "  mirror: $url"
        for attempt in 1 2 3; do
            echo \
                "  [attempt $attempt] treeless partial clone"

            rm -rf "$dir"

            if \
                git "${GIT_ROBUST[@]}" clone \
                    --filter=tree:0 \
                    --no-checkout \
                    --no-tags \
                    "$url" \
                    "$dir"
            then
                if \
                    git -C "$dir" \
                        "${GIT_ROBUST[@]}" \
                        checkout -q "$sha"
                then
                    echo \
                        "  [fetched] $sha from $url"
                    return 0
                fi
            fi
            echo \
                "  [retry] failed from $url"

            sleep $((attempt * 5))
        done
        echo \
            "  [mirror failed] $url"
    done

    echo
    echo "  [FAIL] could not fetch commit $sha from any mirror"

    return 1
}

for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r \
        name \
        sha \
        patch \
        urls \
        <<<"$entry"
    echo
    echo "============================================================"
    echo "### $name"
    echo "base:  $sha"
    echo "patch: $patch"
    echo "============================================================"

    if \
        [ -e "$SOURCES/$name/.git" ] \
        &&
        git -C "$SOURCES/$name" \
            rev-parse HEAD \
            >/dev/null 2>&1
    then
        echo \
            "  [skip] already prepared:" \
            "$(git -C "$SOURCES/$name" log --oneline -1)"
        continue
    fi
    clone_checkout \
        "$SOURCES/$name" \
        "$sha" \
        "$urls"
    echo
    echo "  applying $patch"
    git -C "$SOURCES/$name" \
        -c user.name=ci \
        -c user.email=ci@local \
        am -3 \
        "$PATCHDIR/$patch"
    echo
    echo \
        "  [ok]" \
        "$(git -C "$SOURCES/$name" log --oneline -1)"
done

echo
echo "============================================================"
echo "ALL PATCHED GNU SOURCES PREPARED"
echo "directory: $SOURCES"
echo "============================================================"
