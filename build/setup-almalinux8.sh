#!/usr/bin/env bash
#
# Install the build dependencies on AlmaLinux 8 (glibc 2.28 -> portable binaries).
# Shared by build/Dockerfile.linux and the Linux CI job.
#
set -euo pipefail

dnf -y install 'dnf-command(config-manager)' epel-release
dnf config-manager --set-enabled powertools

# gcc-toolset-12 = modern C++17 host compiler, still linked against glibc 2.28.
dnf -y install \
    gcc-toolset-12 gcc-toolset-12-libstdc++-devel \
    git make cmake ninja-build python3 python3-pip \
    autoconf automake libtool texinfo gawk bison flex patchutils patch \
    gmp-devel mpfr-devel libmpc-devel zlib-devel expat-devel \
    glibc-static libstdc++-static \
    wget xz bzip2 file which diffutils findutils

# Snippy's LLVM requires Python >= 3.8; AlmaLinux 8 defaults to 3.6.
dnf -y install python3.11 python3.11-pip
alternatives --set python3 /usr/bin/python3.11 2>/dev/null || ln -sf /usr/bin/python3.11 /usr/local/bin/python3

# MinGW-w64 cross toolchain for the Windows (canadian-cross) GNU build.
dnf -y install \
    mingw64-gcc mingw64-gcc-c++ mingw64-winpthreads-static \
    mingw64-zlib-static mingw64-expat \
  || echo "NOTE: mingw64 packages unavailable in base repos; install separately for the Windows pass"

dnf clean all
