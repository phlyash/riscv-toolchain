#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-x86_64-w64-mingw32}"
WORK="${WORK:-/work}"
NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

GMP_VER="${GMP_VER:-6.3.0}"
MPFR_VER="${MPFR_VER:-4.2.2}"
MPC_VER="${MPC_VER:-1.3.1}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"
EXPAT_VER="${EXPAT_VER:-2.8.2}"
NCURSES_VER="${NCURSES_VER:-6.6}"
EXPAT_TAG="R_$(echo "$EXPAT_VER" | tr . _)"

GCC="$(command -v "${HOST}-gcc")"
SYSROOT="$("${HOST}-gcc" -print-sysroot 2>/dev/null || true)"
{ [ -n "$SYSROOT" ] && [ -d "$SYSROOT/include" ]; } || SYSROOT="$(cd "$(dirname "$GCC")/.." && pwd)/${HOST}"

SUDO=""
[ -w "$SYSROOT" ] || SUDO="sudo"

if [ -f "$SYSROOT/lib/libgmp.a" ] &&
   [ -f "$SYSROOT/lib/libmpfr.a" ] &&
   [ -f "$SYSROOT/lib/libmpc.a" ] &&
   [ -f "$SYSROOT/lib/libz.a" ] &&
   [ -f "$SYSROOT/lib/libexpat.a" ] &&
   { [ -f "$SYSROOT/lib/libncursesw.a" ] || [ -f "$SYSROOT/lib/libncurses.a" ]; }; then
    echo "mingw static host deps already in $SYSROOT" >&2
    echo "$SYSROOT"
    exit 0
fi

fetch() {
    curl -fL --retry 4 --retry-delay 3 --connect-timeout 30 "$1" -o "$2"
}

{
    B="$WORK/mingw-deps"
    rm -rf "$B"
    mkdir -p "$B" "$SYSROOT"
    cd "$B"

    echo "### GMP $GMP_VER"
    fetch "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" gmp.tar.xz
    tar xf gmp.tar.xz
    (cd "gmp-${GMP_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" --disable-shared --enable-static CC_FOR_BUILD=gcc && make -j"$NPROC" && $SUDO make install)

    echo "### MPFR $MPFR_VER"
    fetch "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz" mpfr.tar.xz
    tar xf mpfr.tar.xz
    (cd "mpfr-${MPFR_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" --with-gmp="$SYSROOT" --disable-shared --enable-static && make -j"$NPROC" && $SUDO make install)

    echo "### MPC $MPC_VER"
    fetch "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz" mpc.tar.gz
    tar xf mpc.tar.gz
    (cd "mpc-${MPC_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" --with-gmp="$SYSROOT" --with-mpfr="$SYSROOT" --disable-shared --enable-static && make -j"$NPROC" && $SUDO make install)

    echo "### zlib $ZLIB_VER"
    fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.xz" zlib.tar.xz
    tar xf zlib.tar.xz
    (
        cd "zlib-${ZLIB_VER}"
        CHOST="$HOST" CC="${HOST}-gcc" AR="${HOST}-ar" RANLIB="${HOST}-ranlib" ./configure --static --prefix="$SYSROOT"
        make -j"$NPROC" libz.a
        $SUDO make install
    )

    echo "### Expat $EXPAT_VER"
    fetch "https://github.com/libexpat/libexpat/releases/download/${EXPAT_TAG}/expat-${EXPAT_VER}.tar.xz" expat.tar.xz
    tar xf expat.tar.xz
    (cd "expat-${EXPAT_VER}" && ./configure --host="$HOST" --prefix="$SYSROOT" --disable-shared --enable-static --without-docbook --without-examples --without-tests && make -j"$NPROC" && $SUDO make install)

    echo "### ncurses $NCURSES_VER"
    fetch "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz" ncurses.tar.gz
    tar xf ncurses.tar.gz
    (
        cd "ncurses-${NCURSES_VER}"
        cf_cv_func_nanosleep=no \
        CFLAGS="-O2 -D__USE_MINGW_ACCESS" \
        TIC="$(command -v tic)" \
        INFOCMP="$(command -v infocmp)" \
        ./configure --host="$HOST" --prefix="$SYSROOT" --with-build-cc=gcc \
            --without-shared --with-normal --without-debug --without-ada \
            --without-cxx-binding --without-progs --without-manpages \
            --without-pthread --enable-widec --enable-overwrite \
            --enable-term-driver --disable-database --disable-db-install \
            --with-fallbacks=ansi,vt100,xterm,xterm-256color,screen,screen-256color,cygwin,linux
        make -j"$NPROC"
        $SUDO make install.libs install.includes
    )

    if [ -f "$SYSROOT/lib/libncursesw.a" ]; then
        $SUDO cp -f "$SYSROOT/lib/libncursesw.a" "$SYSROOT/lib/libncurses.a"
        $SUDO cp -f "$SYSROOT/lib/libncursesw.a" "$SYSROOT/lib/libcurses.a"
    fi
} >&2

echo "$SYSROOT"
