# NIIET RISC-V baremetal toolchain — build notes

Target: **baremetal (newlib)**, `rv32imafdc_zicsr_zifencei`, GCC **and** clang, as small as
possible, for hosts **Linux x86_64/arm64 · macOS arm64/x86_64 · Windows x86_64** (5 symmetric
artifacts, each gcc + clang/lld + gdb). Windows arm64 is dropped — no stable
`aarch64-w64-mingw32` GCC exists to cross-build with.

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

## Multilib (reduced rv32 subset chain, bare canonical naming)

Passed as `--with-multilib-generator=` together with `--with-isa-spec=20191213`
(implies `--enable-multilib`, bare-metal only):

```
rv32i-ilp32--;rv32im-ilp32--;rv32imc-ilp32--;rv32imac-ilp32--;rv32imafc-ilp32f--;rv32imafdc-ilp32d--;rv32imcp-ilp32--;rv32imafdcp-ilp32d--
```

8 libs. Arch strings are **bare** (no `_zicsr_zifencei` suffix) so GCC's multilib
directory names equal clang's normalized `-march` keys — both compilers select the
same `.a`. The last two add the **P** (DSP/packed-SIMD) extension: `rv32imcp/ilp32`
(integer DSP, no FPU) and `rv32imafdcp/ilp32d` (full float + DSP); on GCC `p`
expands to `zmmul,zbpbo,zpn,zpsfoperand` (v0.9.11) via the CloudBEAR patch, and
snippy clang accepts the same march. newlib-nano is built per variant. The Linux
CI job runs `build/verify-multilib.sh` to hard-fail if clang and gcc ever disagree
on the selected multilib, if clang can't parse an `-march`, or if a variant won't
link. NOTE: installed dir names changed from `rv32imc_zicsr_zifencei/` to
`rv32imc/` — update anything that hardcoded the old paths.

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

- **Linux x86_64 + arm64**: `build/Dockerfile.linux` (manylinux2014 / CentOS 7 / glibc 2.17
  + devtoolset-10), base parameterized via `ARG BASE` (CI passes the `_x86_64` or `_aarch64`
  image; arm64 runs natively on an arm runner) → runs on RHEL/CentOS 7 and newer. C++ runtime
  statically linked (-static-libstdc++ -static-libgcc in build-baremetal.sh) so no
  GLIBCXX/CXXABI deps either.
- **Windows x86_64**: canadian cross on the Ubuntu runner (Linux-hosted mingw GCC 13),
  `--with-host=x86_64-w64-mingw32` for gcc+gdb, **plus a cross-built clang/lld** —
  `stage_clang_cross` does a native `*-tblgen` pre-pass then a mingw cross configure
  (`CMAKE_SYSTEM_NAME=Windows`, `LLVM_NATIVE_TOOL_DIR`, fully static host link
  `-static -static-libgcc -static-libstdc++`, optional host deps ZLIB/ZSTD/LIBXML2/TERMINFO
  OFF). All `.exe`s install into the same `$PREFIX`.
- **macOS arm64 + x86_64**: native on the Mac runners (`macos-14` / `macos-13`); homebrew
  bison/gawk/gsed/gmake + gmp/mpfr/mpc, prefix auto-detected via `$(brew --prefix)`
  (`/opt/homebrew` on arm64, `/usr/local` on Intel). Source trees may need a case-sensitive
  volume.

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
- **linux** (matrix ×2: `x86_64` on `ubuntu-24.04`, `arm64` on `ubuntu-24.04-arm`) —
  manylinux2014 (glibc 2.17) container, native per arch. x86_64 is the validated portable
  anchor (runs on CentOS/RHEL 7+); arm64 is `continue-on-error`. Sources cached per arch.
- **macos** (matrix ×2: `arm64` on `macos-14`, `x86_64` on `macos-13`) — native.
  Experimental (`continue-on-error`): PATH for GNU tools; possible case-sensitive-FS need.
- **windows-x86_64** — mingw canadian-cross on the Ubuntu runner: **gcc + gdb + clang/lld**.
  A canadian cross needs a runnable build->target gcc to compile target libgcc/libstdc++ +
  dump specs (the host cc1 is a Windows .exe), so `stage_gcc` does a **native pre-pass** into
  `$WORK/native-toolchain` first on PATH before the canadian pass. clang is cross-built by
  `stage_clang_cross` (native tblgen pre-pass + mingw cross configure). Experimental.

### Remaining work
- Validate/iterate the new arm64 Linux, Intel macOS, and Windows-clang jobs on actual runners.

## Caveat

snippy's clang only understands the custom `xbp`/`xgost`/`p-ext` extensions if Syntacore's
fork implements them (independent of the GNU patch set). Confirm what is compiled with
clang vs gcc.
