#!/usr/bin/env bash
#
# Cross-build the host libraries the canadian-cross GNU tools need but that aren't
# shipped with the mingw toolchain, installed into the mingw gcc's own sysroot so
# configure finds them with no extra flags:
#   gmp, mpfr, mpc  -> required by the mingw-hosted GCC
#   zlib             -> required by the mingw-hosted GCC (lto-compress.cc)
#   gmp, mpfr        -> required by gdb
#   expat            -> required by binutils + gdb
#
#   HOST=x86_64-w64-mingw32 bash build/prepare-mingw-deps.sh
#
# Prints ONLY the sysroot path on stdout (progress to stderr).
#
set -euo pipefail

HOST="${HOST:-x86_64-w64-mingw32}"
GMP_VER="${GMP_VER:-6.3.0}"
MPFR_VER="${MPFR_VER:-4.2.1}"
MPC_VER="${MPC_VER:-1.3.1}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"
EXPAT_VER="${EXPAT_VER:-2.6.4}"
EXPAT_TAG="R_$(echo "$EXPAT_VER" | tr . _)"
WORK="${WORK:-/work}"

GCC="$(command -v "${HOST}-gcc")"
SYSROOT="$("${HOST}-gcc" -print-sysroot 2>/dev/null || true)"
{ [ -n "$SYSROOT" ] && [ -d "$SYSROOT/include" ]; } || SYSROOT="$(cd "$(dirname "$GCC")/.." && pwd)/${HOST}"
# The mingw sysroot is usually root-owned (e.g. /usr/x86_64-w64-mingw32); sudo the install.
SUDO=""; [ -w "$SYSROOT" ] || SUDO="sudo"

if [ -f "$SYSROOT/lib/libmpfr.a" ] && [ -f "$SYSROOT/lib/libexpat.a" ] && \
   [ -f "$SYSROOT/lib/libgmp.a" ] && [ -f "$SYSROOT/lib/libmpc.a" ] && \
   [ -f "$SYSROOT/lib/libz.a" ]; then
  echo "mingw gmp+mpfr+mpc+zlib+expat already in $SYSROOT" >&2; echo "$SYSROOT"; exit 0
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

  echo "### mpc-$MPC_VER -> $SYSROOT"
  curl -fLSs "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz" -o mpc.tar.gz && tar xf mpc.tar.gz
  cd "mpc-${MPC_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" \
      --with-gmp="$SYSROOT" --with-mpfr="$SYSROOT" \
      --disable-shared --enable-static && make -j"$(nproc)" && $SUDO make install
  cd "$B"

  echo "### zlib-$ZLIB_VER -> $SYSROOT"
  # zlib has its own (non-autoconf) configure: honour CHOST/CC/AR/RANLIB to cross,
  # --static so only libz.a is built+installed (no DLL).
  curl -fLSs "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.xz" -o zlib.tar.xz && tar xf zlib.tar.xz
  cd "zlib-${ZLIB_VER}" && CHOST="$HOST" CC="${HOST}-gcc" AR="${HOST}-ar" RANLIB="${HOST}-ranlib" \
      ./configure --static --prefix="$SYSROOT" && make -j"$(nproc)" libz.a && $SUDO make install
  cd "$B"

  echo "### expat-$EXPAT_VER -> $SYSROOT"
  curl -fLSs "https://github.com/libexpat/libexpat/releases/download/${EXPAT_TAG}/expat-${EXPAT_VER}.tar.xz" -o expat.tar.xz && tar xf expat.tar.xz
  cd "expat-${EXPAT_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" \
      --disable-shared --enable-static --without-docbook --without-examples --without-tests && make -j"$(nproc)" && $SUDO make install
} >&2

echo "$SYSROOT"
