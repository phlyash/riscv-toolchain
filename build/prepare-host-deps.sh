#!/usr/bin/env bash
set -euo pipefail

WORK="${WORK:-/work}"
PREFIX="${HOST_DEPS_PREFIX:-$WORK/host-deps}"
NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

GMP_VER="${GMP_VER:-6.3.0}"
MPFR_VER="${MPFR_VER:-4.2.2}"
MPC_VER="${MPC_VER:-1.3.1}"
ISL_VER="${ISL_VER:-0.27}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"
EXPAT_VER="${EXPAT_VER:-2.8.2}"
NCURSES_VER="${NCURSES_VER:-6.6}"
EXPAT_TAG="R_$(echo "$EXPAT_VER" | tr . _)"

[ -f "$PREFIX/.complete" ] && { echo "$PREFIX"; exit 0; }

B="$WORK/host-deps-build"
rm -rf "$B" "$PREFIX"
mkdir -p "$B" "$PREFIX"
cd "$B"

fetch() {
    curl -fL --retry 4 --retry-delay 3 --connect-timeout 30 "$1" -o "$2"
}

{
    echo "### GMP $GMP_VER"
    fetch "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" gmp.tar.xz
    tar xf gmp.tar.xz
    (cd "gmp-${GMP_VER}" && ./configure --prefix="$PREFIX" --disable-shared --enable-static && make -j"$NPROC" && make install)

    echo "### MPFR $MPFR_VER"
    fetch "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz" mpfr.tar.xz
    tar xf mpfr.tar.xz
    (cd "mpfr-${MPFR_VER}" && ./configure --prefix="$PREFIX" --with-gmp="$PREFIX" --disable-shared --enable-static && make -j"$NPROC" && make install)

    echo "### MPC $MPC_VER"
    fetch "https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz" mpc.tar.gz
    tar xf mpc.tar.gz
    (cd "mpc-${MPC_VER}" && ./configure --prefix="$PREFIX" --with-gmp="$PREFIX" --with-mpfr="$PREFIX" --disable-shared --enable-static && make -j"$NPROC" && make install)

    echo "### ISL $ISL_VER"
    fetch "https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz" isl.tar.xz
    tar xf isl.tar.xz
    (cd "isl-${ISL_VER}" && ./configure --prefix="$PREFIX" --with-gmp-prefix="$PREFIX" --disable-shared --enable-static && make -j"$NPROC" && make install)

    echo "### zlib $ZLIB_VER"
    fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.xz" zlib.tar.xz
    tar xf zlib.tar.xz
    (cd "zlib-${ZLIB_VER}" && ./configure --static --prefix="$PREFIX" && make -j"$NPROC" && make install)

    echo "### Expat $EXPAT_VER"
    fetch "https://github.com/libexpat/libexpat/releases/download/${EXPAT_TAG}/expat-${EXPAT_VER}.tar.xz" expat.tar.xz
    tar xf expat.tar.xz
    (cd "expat-${EXPAT_VER}" && ./configure --prefix="$PREFIX" --disable-shared --enable-static --without-docbook --without-examples --without-tests && make -j"$NPROC" && make install)

    if [ "$(uname -s)" = "Darwin" ]; then
        echo "### ncurses: using macOS system curses"
    else
        echo "### ncurses $NCURSES_VER"
        fetch "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz" ncurses.tar.gz
        tar xf ncurses.tar.gz

        (
            cd "ncurses-${NCURSES_VER}"
            ./configure --prefix="$PREFIX" --without-shared --with-normal \
                --without-debug --without-ada --without-cxx-binding \
                --without-progs --without-manpages --disable-db-install \
                --enable-widec --enable-overwrite
            make -j"$NPROC"
            make install.libs install.includes
        )

        if [ -f "$PREFIX/lib/libncursesw.a" ]; then
            cp -f "$PREFIX/lib/libncursesw.a" "$PREFIX/lib/libncurses.a"
            cp -f "$PREFIX/lib/libncursesw.a" "$PREFIX/lib/libcurses.a"
        fi
    fi
} >&2

touch "$PREFIX/.complete"
echo "$PREFIX"
