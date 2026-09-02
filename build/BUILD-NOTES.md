# NIIET RISC-V baremetal toolchain — build notes

Target: **baremetal (newlib)** RV32 multilib, GCC **and** Clang, as small as
possible, for hosts **Linux x86_64 · macOS arm64 · Windows x86_64** (3 symmetric
artifacts, each GCC + Clang/LLD + GDB).

## Source bases (pinned CloudBEAR commits, NOT the gcc-16 submodule)

| component | upstream | pinned base | patch |
|-----------|----------|-------------|-------|
| binutils  | sourceware binutils-gdb | `675b9d6` | `patch/riscv-binutils.patch` |
| gcc       | gcc-mirror/gcc          | `cd0059a` | `patch/riscv-gcc.patch` |
| newlib    | newlib-cygwin           | `26f7004` | `patch/riscv-newlib.patch` |
| gdb (opt) | sourceware binutils-gdb | `6bda1c1` | `patch/riscv-gdb.patch` |

`patch/verify-patches.sh` clones these and `git am -3`'s the patches (smoke test).
The real build reuses the same patched trees via `--with-<x>-src=`.

Clang comes from the upstream `llvm-project` submodule pinned to LLVM 22.1.8,
commit `ca7933e47d3a3451d81e72ac174dcb5aa28b59d1`. We build the RISC-V backend,
Clang, selected Clang tools, and LLD. We do **not** build LLVM target runtimes:
Clang consumes the GCC-built newlib, libgcc, libstdc++, headers, and multilibs
already installed in the shared prefix.

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
expands to `zmmul,zbpbo,zpn,zpsfoperand` (v0.9.11) via the CloudBEAR patch.
These last two variants are GCC-only; upstream Clang validates and shares the
first six standard RISC-V variants. newlib-nano is built per variant. The Linux
CI job runs `build/verify-multilib.sh` to hard-fail if Clang and GCC disagree
on a shared selected multilib, if Clang can't parse a shared `-march`, or if a
variant won't link. NOTE: installed dir names changed from `rv32imc_zicsr_zifencei/` to
`rv32imc/` — update anything that hardcoded the old paths.

## Two-pass constraint

`--enable-multilib` and `--enable-llvm` cannot be combined (Makefile.in:248 hard error).
And a single-arch LLVM pass's GCC would clobber the multilib GCC in a shared prefix.
Strategy (to be validated empirically, in order):
1. **Pass 1 — GCC + multilib newlib** (no llvm): the primary toolchain.
2. **Pass 2 — upstream clang/lld**: build directly with CMake against the Pass-1
   sysroot and install only the LLVM/clang bits into the same prefix (avoids both the
   Makefile guard and the gcc-clobber). Mirror `LLVM_*_CMAKE_FLAGS` from Makefile.in but
   target baremetal `riscv32-unknown-elf`.

## Smallness levers (apply all)

- `--with-languages=c,c++` (drop fortran/go/…)
- `--disable-libcc1` (drop the always-shared, optional GDB `compile` bridge)
- newlib-nano (automatic) — link user code with `--specs=nano.specs`
- `--enable-strip` (strips host binaries)
- LLVM: `-DLLVM_TARGETS_TO_BUILD=RISCV -DLLVM_INSTALL_TOOLCHAIN_ONLY=On`,
  `Release`, `-DLLVM_ENABLE_SPHINX=OFF`, strip
- `.github/dedup-dir.sh $PREFIX` (hardlink-dedups identical files)
- final: `XZ_OPT="-e -T0" tar cJf`

## Per-host

- **Linux x86_64**: `build/Dockerfile.linux` (manylinux2014 / CentOS 7 / glibc 2.17
  + devtoolset-10) → runs on RHEL/CentOS 7 and newer. C++ runtime
  statically linked (`-static-libstdc++ -static-libgcc` in `build-baremetal.sh`) so no
  GLIBCXX/CXXABI deps either.
- **Windows x86_64**: Canadian cross on the Ubuntu runner. GNU MinGW remains responsible
  for GCC, binutils, and GDB. LLVM/Clang/LLD alone are built with the official pinned
  `llvm-mingw-20260616-msvcrt-ubuntu-22.04-x86_64.tar.xz`, authenticated by SHA-256
  `a1f7968b48ba8d949194d6dee6c76f3cd0f61cba91658599af2c2c834a55ab87`.
  `stage_clang_cross` requires `LLVM_MINGW_ROOT`, does a native `*-tblgen` pre-pass,
  and uses llvm-mingw's Clang, windres, ar, ranlib, and strip with static host linkage.
  All `.exe` files install into the same GCC-populated `$PREFIX`; llvm-mingw's target
  runtimes are not copied into the package.
- **macOS arm64**: native on `macos-14`; Homebrew
  bison/gawk/gsed/gmake + gmp/mpfr/mpc, prefix auto-detected via `$(brew --prefix)`
  (`/opt/homebrew`). Source trees may need a case-sensitive volume.

## GDB features and host runtime closure

Every GDB build requires TUI, curses, and XML target descriptions. GDB configure receives
`--with-expat=yes --with-libexpat-prefix=<deps> --with-libexpat-type=auto`. The dependency
prefix is built without shared Expat, so GDB selects `libexpat.a`; `auto` deliberately leaves
Expat's system `libm` dependency dynamic. GDB's `static` dependency mode would also require
`libm.a`, which is unavailable in the manylinux2014 image. A missing or unusable static Expat
still fails configuration rather than silently producing `--without-expat`.

`build/check-host-runtime.sh` then checks the completed package. Linux `DT_NEEDED` entries
must belong to the explicit glibc ABI allowlist; Windows PE imports must belong to the
system-DLL allowlist; macOS binaries must not reference Homebrew paths. Native GDB builds
also execute an invalid target-description XML probe. The dependent Windows runner performs
the equivalent executable GDB probe after extracting the final ZIP. Thus `libexpat.so`,
`libexpat.dll`, `libwinpthread-1.dll`, and any other undeclared host library fail CI.

## Scripts (in build/)

- `setup-manylinux2014.sh` — install build deps on the manylinux2014 (CentOS 7) base.
- `Dockerfile.linux` — the portable build image. Build with **context = build/**:
  `docker build -t niiet-rv-linux -f build/Dockerfile.linux build/`
- `prepare-sources.sh` — clone the pinned GNU bases and apply the NIIET patches into
  `$SOURCES`; LLVM comes from the separately pinned repository submodule.
- `build-baremetal.sh {gcc|clang|package|all}` — env-driven (SRC, SOURCES, WORK, PREFIX,
  OUT, WITH_HOST); same script local + CI.
- `test-build-config.sh [case|all]` — fast regression tests for host static-link flags;
  slow build tools are replaced with local argument recorders.
- `test-fetch-source.sh` — verifies that dependency downloads fall back to the next
  mirror and never leave a partial archive at the final path.
- `prepare-llvm-mingw.sh` / `test-prepare-llvm-mingw.sh` — download, checksum, atomically
  install, validate, and regression-test the pinned Windows LLVM host compiler.
- `test-host-runtime.sh` — hermetic fail-closed Linux dependency and GDB XML tests.
- `test-windows-clang.ps1` — runs the packaged Windows Clang optimizer reproducer,
  links an RV32 program through the packaged GCC sysroot/libgcc, validates the ELF, and
  executes the packaged GDB XML parser on a native Windows runner.
- `test-niiet-toolchain-workflow.py` — enforces the llvm-mingw data flow and native
  Windows release gate in GitHub Actions.

Local run (Apple Silicon → produces an **arm64**-hosted toolchain, validation only):
```
SOURCES=/tmp/rv-patch-verify bash build/prepare-sources.sh   # (sandbox off for network)
docker run --rm -v "$PWD":/src -v /tmp/rv-patch-verify:/sources \
  -v rv-work:/work -v rv-prefix:/opt/riscv -v /tmp/rv-out:/out \
  niiet-rv-linux bash -c '/src/build/build-baremetal.sh all'
```

## CI: `.github/workflows/niiet-toolchain.yaml`

Manual (`workflow_dispatch`) + version tags. Jobs:
- **linux-x86_64** — manylinux2014 (glibc 2.17) container on `ubuntu-24.04`.
- **macos-aarch64** — native on `macos-14`.
- **windows-x86_64** — mingw canadian-cross on the Ubuntu runner: **gcc + gdb + clang/lld**.
  A canadian cross needs a runnable build->target gcc to compile target libgcc/libstdc++ +
  dump specs (the host cc1 is a Windows .exe), so `stage_gcc` does a **native pre-pass** into
  `$WORK/native-toolchain` first on PATH before the Canadian pass. Clang is cross-built by
  `stage_clang_cross` with the pinned llvm-mingw root.
- **windows-clang-smoke** — native `windows-2022` validation of the uploaded ZIP. The
  release job depends on this job, so a host crash, missing GCC runtime, wrong ELF, or
  disabled GDB XML parser blocks publication.

## Caveat

The CloudBEAR/NIIET `p` extension remains GCC-only. Select GCC for the two P-extension
multilibs; use either GCC or Clang for the six shared standard RISC-V multilibs.
