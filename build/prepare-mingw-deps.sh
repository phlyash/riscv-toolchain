#!/usr/bin/env bash
#
# Cross-build the host libraries the canadian-cross binutils/gdb need but that aren't
# shipped with the (niXman) mingw toolchain: gmp + mpfr (gdb) and expat (binutils+gdb).
# They are installed into the mingw gcc's own sysroot so configure finds them with no
# extra flags. (GCC builds its own gmp/mpfr/mpc in-tree, so it isn't covered here.)
#
#   HOST=x86_64-w64-mingw32 bash build/prepare-mingw-deps.sh
#
# Prints ONLY the sysroot path on stdout (progress to stderr).
#
set -euo pipefail

HOST="${HOST:-x86_64-w64-mingw32}"
GMP_VER="${GMP_VER:-6.3.0}"
MPFR_VER="${MPFR_VER:-4.2.1}"
EXPAT_VER="${EXPAT_VER:-2.6.4}"
EXPAT_TAG="R_$(echo "$EXPAT_VER" | tr . _)"
WORK="${WORK:-/work}"

GCC="$(command -v "${HOST}-gcc")"
SYSROOT="$("${HOST}-gcc" -print-sysroot 2>/dev/null || true)"
{ [ -n "$SYSROOT" ] && [ -d "$SYSROOT/include" ]; } || SYSROOT="$(cd "$(dirname "$GCC")/.." && pwd)/${HOST}"
# The mingw sysroot is usually root-owned (e.g. /usr/x86_64-w64-mingw32); sudo the install.
SUDO=""; [ -w "$SYSROOT" ] || SUDO="sudo"

if [ -f "$SYSROOT/lib/libmpfr.a" ] && [ -f "$SYSROOT/lib/libexpat.a" ] && [ -f "$SYSROOT/lib/libgmp.a" ]; then
  echo "mingw gmp+mpfr+expat already in $SYSROOT" >&2; echo "$SYSROOT"; exit 0
fi

{
  B="$WORK/mingw-deps"; rm -rf "$B"; mkdir -p "$B" "$SYSROOT"; cd "$B"

  echo "### gmp-$GMP_VER -> $SYSROOT"
  curl -fLSs "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" -o gmp.tar.xz && tar xf gmp.tar.xz
  cd "gmp-${GMP_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" \
      --disable-shared --enable-static CC_FOR_BUILD=gcc && make -j"$(nproc)" && $SUDO make install
  cd "$B"

  echo "### mpfr-$MPFR_VER -> $SYSROOT"
  curl -fLSs "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz" -o mpfr.tar.xz && tar xf mpfr.tar.xz
  cd "mpfr-${MPFR_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" --with-gmp="$SYSROOT" \
      --disable-shared --enable-static && make -j"$(nproc)" && $SUDO make install
  cd "$B"

  echo "### expat-$EXPAT_VER -> $SYSROOT"
  curl -fLSs "https://github.com/libexpat/libexpat/releases/download/${EXPAT_TAG}/expat-${EXPAT_VER}.tar.xz" -o expat.tar.xz && tar xf expat.tar.xz
  cd "expat-${EXPAT_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" \
      --disable-shared --enable-static --without-docbook --without-examples --without-tests && make -j"$(nproc)" && $SUDO make install
} >&2

echo "$SYSROOT"
