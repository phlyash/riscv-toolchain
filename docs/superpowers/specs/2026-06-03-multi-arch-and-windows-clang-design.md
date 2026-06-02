# Multi-arch host matrix + Windows clang — design

Date: 2026-06-03
Branch: `niiet-baremetal-toolchain`

## Goal

Expand the NIIET RISC-V baremetal toolchain (rv32imafdc, GCC + clang/lld from
snippy LLVM + gdb, reduced rv32 multilib) from 3 host targets to **5 symmetric
targets**, and add **clang to the Windows host** (currently GCC+gdb only).

Every shipped artifact carries the same set of tools: **gcc + clang/lld + gdb**.

## Final target matrix

| Target | Runner | Build method | Status |
|---|---|---|---|
| Linux x86_64 | `ubuntu-24.04` | manylinux2014_x86_64 container (validated anchor) | have |
| Linux arm64 | `ubuntu-24.04-arm` | manylinux2014_aarch64 container, native | new |
| macOS arm64 | `macos-14` | native | have |
| macOS x86_64 | `macos-13` (Intel) | native | new |
| Windows x86_64 | `ubuntu-24.04` | mingw canadian-cross (gcc/gdb) + clang cross | gcc/gdb have; clang new |

**Windows arm64 is intentionally dropped.** No stable `aarch64-w64-mingw32` GCC
exists to cross-build with (the mingw-w64 ARM64 GCC target is experimental and
unpackaged). Windows-on-ARM can run the x86_64 build under emulation.

## Section 1 — Linux arm64 (native)

- Parameterize `build/Dockerfile.linux`: add `ARG BASE=quay.io/pypa/manylinux2014_x86_64`
  and `FROM $BASE`.
- New CI job `linux-arm64` on `ubuntu-24.04-arm`, identical to `linux-x86_64`
  except `docker build --build-arg BASE=quay.io/pypa/manylinux2014_aarch64`.
- `setup-manylinux2014.sh`, `build-baremetal.sh`, static-libstdc++ strategy are
  arch-neutral and unchanged. `uname -m` → `aarch64` names the tarball.
- Cache key gets its own arch suffix to avoid cross-arch collisions.

Risk: low (native build, proven recipe on a different arch).

## Section 2 — macOS x86_64 (native)

- Collapse the two macOS jobs into `strategy.matrix.os: [macos-14, macos-13]`.
- Replace hardcoded `B=/opt/homebrew/opt` with `B="$(brew --prefix)/opt"`
  (resolves to `/opt/homebrew` on arm64, `/usr/local` on Intel).
- No other changes. `uname -m` → `x86_64` names the Intel artifact.

Risk: low (native build, same recipe, only the Homebrew prefix differs).

## Section 3 — Windows clang cross-build

The only high-engineering-risk piece. Cannot be validated on the arm64 Mac dev
box — requires CI iterations. Standard LLVM mingw cross-compile:

1. **Native tblgen pre-pass** (build=Linux, on the Ubuntu runner): a minimal LLVM
   configure that builds only `llvm-tblgen` + `clang-tblgen`. Fast (minutes).
2. **Cross configure** clang/lld to the mingw host, reusing the snippy LLVM tree:
   - `CMAKE_SYSTEM_NAME=Windows`
   - `CMAKE_C_COMPILER=x86_64-w64-mingw32-gcc`,
     `CMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++`,
     `CMAKE_RC_COMPILER=x86_64-w64-mingw32-windres`
   - `LLVM_HOST_TRIPLE=x86_64-w64-windows-gnu`
   - `LLVM_NATIVE_TOOL_DIR=<native-tblgen-bin>` (host tblgens are .exe and can't run)
   - target flags identical to the native Linux clang build:
     `LLVM_TARGETS_TO_BUILD=RISCV`, `LLVM_DEFAULT_TARGET_TRIPLE=riscv32-unknown-elf`,
     `LLVM_INSTALL_TOOLCHAIN_ONLY=On`, `LLVM_ENABLE_PROJECTS=clang;lld`,
     distribution = `clang;clang-resource-headers;lld`, `install-distribution-stripped`
   - **fully static host link** so the .exe's carry no extra mingw DLL deps:
     `-static -static-libgcc -static-libstdc++` (+ static winpthread) via
     `CMAKE_EXE_LINKER_FLAGS`, plus disable optional host deps
     `LLVM_ENABLE_ZLIB=OFF`, `LLVM_ENABLE_ZSTD=OFF`, `LLVM_ENABLE_LIBXML2=OFF`,
     `LLVM_ENABLE_TERMINFO=OFF`
   - cross strip via `x86_64-w64-mingw32-strip` (install-distribution-stripped path)
3. The clang.exe / lld.exe install into the **same Windows `$PREFIX`** as the GCC
   canadian cross.

Implementation in `build-baremetal.sh`: replace the current
`stage_clang` early-return-on-`WITH_HOST` with a cross branch implementing the
above. Native (non-WITH_HOST) clang path is unchanged.

Windows job flow becomes: native gcc pre-pass → canadian gcc/gdb → native
tblgens → cross clang → package. Long (~1h+) but fits CI.

Risk: high relative to the rest; will need CI debugging.

## Section 4 — Packaging / naming

- Windows artifact: `riscv32-imafdc-elf-x86_64-windows-gcc` →
  `…-x86_64-windows-gcc-clang` (now symmetric).
- The existing `riscv32-imafdc-elf-${HOSTARCH}-${HOSTOS}-gcc-clang` scheme already
  yields correct names for the two new native targets.

## Section 5 — CI workflow shape

`.github/workflows/niiet-toolchain.yaml` ends with the jobs: `linux-x86_64`,
`linux-arm64`, `macos` (matrix ×2 → 2 artifacts), `windows-x86_64`. New/unproven
targets keep `continue-on-error: true`; `linux-x86_64` stays the validated anchor.

## Out of scope

- Windows arm64 (dropped, see matrix).
- Universal/fat macOS binaries (two native artifacts instead).
- snippy-specific tooling (`llvm-snippy`/presets) — clang/lld only, as before.

## Notes / caveats

- `ubuntu-24.04-arm` runners: free for public repos, billed for private.
- Windows clang cross is the only piece needing real CI validation; everything
  else is native or a proven recipe applied to a new arch.
