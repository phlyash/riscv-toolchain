# NIIET RISC-V baremetal toolchain — build notes

Target: **baremetal (newlib)**, `rv32imafdc_zicsr_zifencei`, GCC **and** clang, as small as
possible, for hosts **Linux x86_64 / Windows x86_64 / macOS arm64**.

## Source bases (pinned CloudBEAR commits, NOT the gcc-16 submodule)

| component | upstream | pinned base | patch |
|-----------|----------|-------------|-------|
| binutils  | sourceware binutils-gdb | `675b9d6` | `patch/riscv-binutils.patch` |
| gcc       | gcc-mirror/gcc          | `cd0059a` | `patch/riscv-gcc.patch` |
| newlib    | newlib-cygwin           | `26f7004` | `patch/riscv-newlib.patch` |
| gdb (opt) | sourceware binutils-gdb | `6bda1c1` | `patch/riscv-gdb.patch` |

`patch/verify-patches.sh` clones these and `git am -3`'s the patches (smoke test).
The real build reuses the same patched trees via `--with-<x>-src=`.

clang comes from **Syntacore's LLVM fork** `https://github.com/syntacore/snippy`
(full llvm-project monorepo). We build `llvm;clang;lld` + baremetal runtimes from it;
we do NOT build the `llvm-snippy` tool / `snippy_basic` preset.

## Multilib (reduced rv32 imafdc subset chain)

Passed as `--with-multilib-generator=` (implies `--enable-multilib`, bare-metal only):

```
rv32i_zicsr_zifencei-ilp32--;rv32im_zicsr_zifencei-ilp32--;rv32imc_zicsr_zifencei-ilp32--;rv32imac_zicsr_zifencei-ilp32--;rv32imafc_zicsr_zifencei-ilp32f--;rv32imafdc_zicsr_zifencei-ilp32d--
```

(6 libs: i, im, imc, imac → ilp32; imafc → ilp32f; imafdc → ilp32d. newlib-nano built
automatically alongside full newlib.)

## Two-pass constraint

`--enable-multilib` and `--enable-llvm` cannot be combined (Makefile.in:248 hard error).
And a single-arch LLVM pass's GCC would clobber the multilib GCC in a shared prefix.
Strategy (to be validated empirically, in order):
1. **Pass 1 — GCC + multilib newlib** (no llvm): the primary toolchain.
2. **Pass 2 — clang/lld from snippy**: build directly with cmake against the Pass-1
   sysroot and install only the LLVM/clang bits into the same prefix (avoids both the
   Makefile guard and the gcc-clobber). Mirror `LLVM_*_CMAKE_FLAGS` from Makefile.in but
   target baremetal `riscv32-unknown-elf`.

## Smallness levers (apply all)

- `--with-languages=c,c++` (drop fortran/go/…)
- newlib-nano (automatic) — link user code with `--specs=nano.specs`
- `--enable-strip` (strips host binaries)
- LLVM: `-DLLVM_TARGETS_TO_BUILD=RISCV -DLLVM_INSTALL_TOOLCHAIN_ONLY=On`,
  `Release`, `-DLLVM_ENABLE_SPHINX=OFF`, strip
- `.github/dedup-dir.sh $PREFIX` (hardlink-dedups identical files)
- final: `XZ_OPT="-e -T0" tar cJf`

## Per-host

- **Linux**: `build/Dockerfile.linux` (manylinux2014 / CentOS 7 / glibc 2.17 + devtoolset-10)
  → runs on RHEL/CentOS 7 and newer. C++ runtime statically linked (-static-libstdc++
  -static-libgcc in build-baremetal.sh) so no GLIBCXX/CXXABI deps either.
- **Windows**: canadian cross on the Ubuntu runner (Linux-hosted mingw GCC 13),
  `--with-host=x86_64-w64-mingw32` (GNU side). clang-for-Windows needs extra cmake
  (`-DLLVM_HOST_TRIPLE`, mingw C++ rt).
- **macOS arm64**: native on the Mac; `source macos.zsh` first (homebrew bison/gawk/gsed/
  gmake, gmp/mpfr/mpc), build on a case-sensitive volume.

## Scripts (in build/)

- `setup-manylinux2014.sh` — install build deps on the manylinux2014 (CentOS 7) base.
- `Dockerfile.linux` — the portable build image. Build with **context = build/**:
  `docker build -t niiet-rv-linux -f build/Dockerfile.linux build/`
- `prepare-sources.sh` — clone pinned bases + apply patches + clone snippy into `$SOURCES`.
- `build-baremetal.sh {gcc|clang|package|all}` — env-driven (SRC, SOURCES, WORK, PREFIX,
  OUT, WITH_HOST); same script local + CI.

Local run (Apple Silicon → produces an **arm64**-hosted toolchain, validation only):
```
SOURCES=/tmp/rv-patch-verify bash build/prepare-sources.sh   # (sandbox off for network)
docker run --rm -v "$PWD":/src -v /tmp/rv-patch-verify:/sources \
  -v rv-work:/work -v rv-prefix:/opt/riscv -v /tmp/rv-out:/out \
  niiet-rv-linux bash -c '/src/build/build-baremetal.sh all'
```

## CI: `.github/workflows/niiet-toolchain.yaml`

Manual (`workflow_dispatch`) + version tags. Jobs:
- **linux-x86_64** — manylinux2014 (glibc 2.17) container on an x86_64 runner. The real
  portable x86_64 deliverable (runs on CentOS/RHEL 7+). Sources cached by patch-file hash.
- **macos-arm64** — native on `macos-14`. Experimental (`continue-on-error`): needs a real
  CI run to shake out (PATH for GNU tools; possible case-sensitive-FS requirement).
- **windows-x86_64** — mingw canadian-cross from the container, **GCC only** for now
  (`build-baremetal.sh` skips clang when `WITH_HOST` is set). Experimental.

### Remaining work
- clang-for-Windows cross (mingw toolchain file + native `llvm-tblgen`, `LLVM_NATIVE_TOOL_DIR`).
- Validate/iterate macOS and Windows jobs on actual runners.

## Caveat

snippy's clang only understands the custom `xbp`/`xgost`/`p-ext` extensions if Syntacore's
fork implements them (independent of the GNU patch set). Confirm what is compiled with
clang vs gcc.
