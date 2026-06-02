#!/usr/bin/env bash
#
# Install build dependencies on the manylinux2014 base (CentOS 7, glibc 2.17).
#
# Why CentOS 7 / glibc 2.17: a dynamically linked binary requires the *highest*
# symbol version it references from each shared lib. Building on this old glibc
# makes the toolchain reference only GLIBC_2.17-and-below, so it runs on RHEL/
# CentOS 7 and every newer distro. The C++ runtime deps (GLIBCXX/CXXABI) are
# handled separately by -static-libstdc++ -static-libgcc in build-baremetal.sh.
#
# manylinux2014 already provides on PATH: devtoolset-10 (GCC 10, C++17-capable,
# linked against glibc 2.17) and a recent cmake + ninja (>=3.20, needed by LLVM).
# Python interpreters live under /opt/python/*/bin (not on PATH) — we symlink one.
#
set -euo pipefail

# CentOS 7 host libs satisfy GCC/gdb minimums (gmp>=4.2, mpfr>=3.1.0, mpc>=0.8).
yum -y install \
    make autoconf automake libtool texinfo gawk bison flex patch \
    gmp-devel mpfr-devel libmpc-devel zlib-devel expat-devel \
    bzip2 xz file which diffutils findutils

# Snippy's LLVM needs Python >= 3.8. CentOS 7's system python is 2; expose a
# modern one (manylinux ships relocatable CPythons under /opt/python).
PY="$(ls -d /opt/python/cp311-cp311/bin/python3 /opt/python/cp31*-cp31*/bin/python3 2>/dev/null | head -1)"
ln -sf "$PY" /usr/local/bin/python3
ln -sf "$PY" /usr/local/bin/python3.11

yum clean all
