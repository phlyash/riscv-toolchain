#!/usr/bin/env bash
#
# Cross-build gmp + mpfr (static) for a MinGW host and install them into the mingw
# sysroot, so the canadian-cross gdb can link them. (GCC builds its own gmp/mpfr/mpc
# in-tree via download_prerequisites; only gdb needs external host copies. expat is
# provided by the mingw64-expat package.)
#
#   HOST=x86_64-w64-mingw32 bash build/prepare-mingw-deps.sh
#
# Prints the sysroot it installed into on the last line (consume with `tail -1`).
#
set -euo pipefail

HOST="${HOST:-x86_64-w64-mingw32}"
GMP_VER="${GMP_VER:-6.3.0}"
MPFR_VER="${MPFR_VER:-4.2.1}"
WORK="${WORK:-/work}/mingw-deps"

SYSROOT="$("${HOST}-gcc" -print-sysroot 2>/dev/null)/mingw"
[ -d "$SYSROOT" ] || SYSROOT="/usr/${HOST}/sys-root/mingw"
mkdir -p "$SYSROOT"

if [ -f "$SYSROOT/lib/libmpfr.a" ] && [ -f "$SYSROOT/lib/libgmp.a" ]; then
  echo "mingw gmp+mpfr already present in $SYSROOT" >&2
  echo "$SYSROOT"; exit 0
fi

rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

echo "### cross-building gmp-$GMP_VER for $HOST" >&2
curl -fLsS "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" -o gmp.tar.xz
tar xf gmp.tar.xz && cd "gmp-${GMP_VER}"
./configure --host="$HOST" --prefix="$SYSROOT" \
            --disable-shared --enable-static CC_FOR_BUILD=gcc >/dev/null
make -j"$(nproc)" >/dev/null && make install >/dev/null
cd "$WORK"

echo "### cross-building mpfr-$MPFR_VER for $HOST" >&2
curl -fLsS "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz" -o mpfr.tar.xz
tar xf mpfr.tar.xz && cd "mpfr-${MPFR_VER}"
./configure --host="$HOST" --prefix="$SYSROOT" --with-gmp="$SYSROOT" \
            --disable-shared --enable-static >/dev/null
make -j"$(nproc)" >/dev/null && make install >/dev/null

echo "### mingw gmp+mpfr installed into $SYSROOT" >&2
echo "$SYSROOT"
