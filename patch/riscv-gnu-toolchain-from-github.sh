#!/usr/bin/env bash
#
##############################################################################
#
# @brief Release script for riscv-gnu-toolchain
#
# @author evgeny.linsky@cloudbear.ru
#
# Copyright (c) 2019-2023 CloudBEAR LLC, all rights reserved.
#
# This file contains confidential, proprietary information and trade
# secrets of CloudBEAR LLC. The information contained in this file
# may only be used by a person authorised under and to the extent
# permitted by a subsisting license agreement or design service
# agreement from CloudBEAR LLC.
#
# This entire notice must be reproduced on all copies of this file
# and copies of this file may only be made by a person if such person
# is permitted to do so under the terms of a subsisting license
# agreement or design service agreement from CloudBEAR LLC.
#
##############################################################################

# riscv-newlib

set -e
CWD=$(pwd)

function help {
    echo "Usage:"
    echo "    $0 [-c] [-a]"
    echo ""
    echo "Arguments:"
    echo "    -c|--create           create patches"
    echo "    -a|--clone-apply      clone upsteram and apply patches"
    echo "    -h|--help             this message"
    echo ""
}

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -c|--create)
            _CREATE="yes"
            shift
            ;;
        -a|--clone-apply)
            _APPLY="yes"
            shift
            ;;
        -h|--help)
            help
            exit 0
            ;;
        --variant)
            shift
            _VARIANT=$1
            shift
            ;;
        *)
            echo "Error: unknown argument: $1"
            exit 1
            ;;
    esac
done


START_TOOLCHAIN=f1f1895
START_BINUTILS=675b9d6
START_DEJAGNU=6d3636e
START_GCC=cd0059a
START_GDB=6bda1c1
START_GLIBC=df3dd20
START_NEWLIB=26f7004

if [[ "$_CREATE" == "yes" ]]; then
    cd $BEAR/riscv-gnu-toolchain && make -f Makefile.bear checkout-latest
    cd $BEAR/riscv-gnu-toolchain && git format-patch -k --stdout ${START_TOOLCHAIN}..HEAD > $CWD/riscv-gnu-toolchain.patch
    cd $BEAR/riscv-gnu-toolchain/riscv-binutils && git format-patch -k --stdout ${START_BINUTILS}..HEAD > $CWD/riscv-binutils.patch
    cd $BEAR/riscv-gnu-toolchain/riscv-dejagnu && git format-patch -k --stdout ${START_DEJAGNU}..HEAD > $CWD/riscv-dejagnu.patch
    cd $BEAR/riscv-gnu-toolchain/riscv-gcc && git format-patch -k --stdout ${START_GCC}..HEAD > $CWD/riscv-gcc.patch
    cd $BEAR/riscv-gnu-toolchain/riscv-gdb && git format-patch -k --stdout ${START_GDB}..HEAD > $CWD/riscv-gdb.patch
    cd $BEAR/riscv-gnu-toolchain/riscv-glibc && git format-patch -k --stdout ${START_GLIBC}..HEAD > $CWD/riscv-glibc.patch
    cd $BEAR/riscv-gnu-toolchain/riscv-newlib && git format-patch -k --stdout ${START_NEWLIB}..HEAD > $CWD/riscv-newlib.patch
    cd $CWD
fi

if [[ "$_APPLY" == "yes" ]]; then
    # clone everything
    git clone https://github.com/riscv/riscv-gnu-toolchain
    git clone https://sourceware.org/git/binutils-gdb.git
    git clone https://git.savannah.gnu.org/git/dejagnu.git
    git clone https://gcc.gnu.org/git/gcc.git
    git clone https://sourceware.org/git/glibc.git
    git clone https://sourceware.org/git/newlib-cygwin.git

    # copy (binutils is copied twice), rename, apply patches
    cd $CWD/riscv-gnu-toolchain && git checkout ${START_TOOLCHAIN} && \
        git am -3 $CWD/riscv-gnu-toolchain.patch && \
        rm -rf riscv-*

    cd $CWD/riscv-gnu-toolchain && \
        cp -r ../binutils-gdb riscv-binutils && cd riscv-binutils && \
        git checkout ${START_BINUTILS} && git am -3 $CWD/riscv-binutils.patch

    cd $CWD/riscv-gnu-toolchain && \
        cp -r ../dejagnu riscv-dejagnu && cd riscv-dejagnu && \
        git checkout ${START_DEJAGNU} && git am -3 $CWD/riscv-dejagnu.patch

    cd $CWD/riscv-gnu-toolchain && \
        cp -r ../gcc riscv-gcc && cd riscv-gcc && \
        git checkout ${START_GCC} && git am -3 $CWD/riscv-gcc.patch

    cd $CWD/riscv-gnu-toolchain && \
        cp -r ../binutils-gdb riscv-gdb && cd riscv-gdb && \
        git checkout ${START_GDB} && git am -3 $CWD/riscv-gdb.patch

    cd $CWD/riscv-gnu-toolchain && \
        cp -r ../glibc riscv-glibc && cd riscv-glibc && \
        git checkout ${START_GLIBC} && git am -3 $CWD/riscv-glibc.patch

    cd $CWD/riscv-gnu-toolchain && \
        cp -r ../newlib-cygwin riscv-newlib && cd riscv-newlib && \
        git checkout ${START_NEWLIB} && git am -3 $CWD/riscv-newlib.patch

    cd $CWD
fi
