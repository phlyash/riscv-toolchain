# Multi-arch host matrix + Windows clang — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the rv32imafdc baremetal toolchain (gcc + clang/lld + gdb) for 5 symmetric host targets — Linux x86_64/arm64, macOS x86_64/arm64, Windows x86_64 — by adding 2 native targets and cross-building clang for the Windows host.

**Architecture:** Linux arm64 and macOS x86_64 are native builds on new runners reusing the existing recipes (parameterize the Dockerfile base; derive the Homebrew prefix). Windows clang is an LLVM mingw cross-compile: a native `*-tblgen` pre-pass on the Ubuntu runner, then a cross configure pinned to the mingw compilers with a fully static host link, installing `clang.exe`/`lld.exe` into the same `$PREFIX` as the GCC canadian cross. The CI workflow is refactored to two matrix jobs (linux ×2, macos ×2) plus the windows job.

**Tech Stack:** GitHub Actions matrices, Docker (manylinux2014 x86_64/aarch64), CMake/Ninja cross-compile to mingw-w64, bash.

**Validation reality:** This dev box is an arm64 Mac. None of the x86_64/Windows targets can be built or run locally — the authoritative test is the CI run the user triggers in Task 6. Each earlier task's verification is the strongest *static* local check available (shell `bash -n`, YAML parse, `grep` invariants).

---

### Task 1: Parameterize the Linux Docker base image

**Files:**
- Modify: `build/Dockerfile.linux` (the `FROM` line + header note)

- [ ] **Step 1: Add an `ARG BASE` before `FROM` and use it**

Replace:
```dockerfile
FROM quay.io/pypa/manylinux2014_x86_64
```
with:
```dockerfile
# Base is parameterized so the same Dockerfile builds the x86_64 and the aarch64
# manylinux2014 images (CI passes --build-arg BASE=...manylinux2014_aarch64 for arm64).
ARG BASE=quay.io/pypa/manylinux2014_x86_64
FROM ${BASE}
```

- [ ] **Step 2: Verify the build context still resolves the setup script**

Run: `grep -n 'COPY setup-manylinux2014.sh' build/Dockerfile.linux`
Expected: the existing `COPY setup-manylinux2014.sh /tmp/setup-manylinux2014.sh` line is unchanged (context = `build/`).

- [ ] **Step 3: Commit**

```bash
git add build/Dockerfile.linux
git commit -m "Linux: parameterize Docker base (ARG BASE) for x86_64+aarch64 images"
```

---

### Task 2: Add the Windows clang cross-build to build-baremetal.sh

**Files:**
- Modify: `build/build-baremetal.sh` (replace the `stage_clang` early-return-on-WITH_HOST; add a `stage_clang_cross` helper)

- [ ] **Step 1: Add the `stage_clang_cross` helper above `stage_clang`**

Insert this function immediately before `stage_clang(){`:

```bash
# Cross-build clang/lld for a mingw Windows host (canadian cross). LLVM needs
# RUNNABLE *-tblgen during its build; the host ones are .exe, so build native
# tblgens first and point the cross build at them (LLVM_NATIVE_TOOL_DIR). Host
# link is fully static (-static + static libgcc/libstdc++/winpthread) and all
# optional host deps are disabled so clang.exe/lld.exe carry no extra mingw DLLs.
#   $1 = python   $2 = distribution component list
stage_clang_cross(){
  local PY="$1" LLVM_DIST="$2"
  local NAT="$WORK/llvm-native-tblgen"
  if [ ! -x "$NAT/bin/llvm-tblgen" ] || [ ! -x "$NAT/bin/clang-tblgen" ]; then
    log "native tblgen pre-pass for the clang cross -> $NAT"
    rm -rf "$NAT" && mkdir -p "$NAT" && cd "$NAT"
    cmake -G Ninja "$SOURCES/llvm-snippy/llvm" \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_ENABLE_PROJECTS="clang" \
      -DLLVM_TARGETS_TO_BUILD="RISCV" \
      -DPython3_EXECUTABLE="$PY"
    ninja -j"$NPROC" llvm-tblgen llvm-min-tblgen clang-tblgen
  fi

  log "cross-build clang/lld -> $WITH_HOST (host=$PREFIX)"
  rm -rf "$LB" && mkdir -p "$LB" && cd "$LB"
  cmake -G Ninja "$SOURCES/llvm-snippy/llvm" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER="${WITH_HOST}-gcc" \
    -DCMAKE_CXX_COMPILER="${WITH_HOST}-g++" \
    -DCMAKE_RC_COMPILER="${WITH_HOST}-windres" \
    -DCMAKE_STRIP="${WITH_HOST}-strip" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_EXE_LINKER_FLAGS="-static -static-libgcc -static-libstdc++" \
    -DCMAKE_SHARED_LINKER_FLAGS="-static -static-libgcc -static-libstdc++" \
    -DLLVM_HOST_TRIPLE="${WITH_HOST/-w64-mingw32/-w64-windows-gnu}" \
    -DLLVM_NATIVE_TOOL_DIR="$NAT/bin" \
    -DPython3_EXECUTABLE="$PY" \
    -DLLVM_TARGETS_TO_BUILD="RISCV" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$TUPLE" \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=On \
    -DLLVM_ENABLE_SPHINX=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_PARALLEL_LINK_JOBS=2 \
    -DLLVM_BINUTILS_INCDIR="$SOURCES/binutils/include" \
    -DLLVM_DISTRIBUTION_COMPONENTS="$LLVM_DIST"
  ninja -j"$NPROC" distribution
  ninja install-distribution-stripped
  log "cross clang done; installed clang.exe/lld.exe into $PREFIX/bin"
}
```

- [ ] **Step 2: Wire it into `stage_clang` (replace the early return)**

In `stage_clang`, replace this block:
```bash
  if [ -n "$WITH_HOST" ]; then
    log "SKIP clang: cross-building clang to '$WITH_HOST' is not wired yet (TODO: mingw toolchain file + native tablegen). GNU toolchain only for this host."
    return 0
  fi
  log "configure + build clang/lld from snippy LLVM (minimal distribution)"
  rm -rf "$LB" && mkdir -p "$LB" && cd "$LB"
  local PY; PY="$(command -v python3.11 || command -v python3)"
  local LLVM_DIST="clang;clang-resource-headers;lld"
```
with:
```bash
  local PY; PY="$(command -v python3.11 || command -v python3)"
  local LLVM_DIST="clang;clang-resource-headers;lld"
  if [ -n "$WITH_HOST" ]; then
    stage_clang_cross "$PY" "$LLVM_DIST"
    log "clang cross sanity: file"
    file "$PREFIX/bin/clang.exe" || true
    return 0
  fi
  log "configure + build clang/lld from snippy LLVM (minimal distribution)"
  rm -rf "$LB" && mkdir -p "$LB" && cd "$LB"
```

- [ ] **Step 3: Verify shell syntax**

Run: `bash -n build/build-baremetal.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify the early-return TODO is gone and the cross helper exists**

Run: `grep -n 'stage_clang_cross\|SKIP clang' build/build-baremetal.sh`
Expected: two `stage_clang_cross` references (definition + call), and NO `SKIP clang` line.

- [ ] **Step 5: Commit**

```bash
git add build/build-baremetal.sh
git commit -m "Windows: cross-build clang/lld to mingw (native tblgen + static host link)"
```

---

### Task 3: Refactor CI — matrix the Linux job (x86_64 + arm64)

**Files:**
- Modify: `.github/workflows/niiet-toolchain.yaml` (replace the `linux-x86_64` job with a matrixed `linux` job)

- [ ] **Step 1: Replace the `linux-x86_64:` job**

Replace the entire `linux-x86_64:` job (from `  linux-x86_64:` through its `upload-artifact` block) with:

```yaml
  linux:
    strategy:
      fail-fast: false
      matrix:
        include:
          - runner: ubuntu-24.04
            base: quay.io/pypa/manylinux2014_x86_64
            arch: x86_64
          - runner: ubuntu-24.04-arm
            base: quay.io/pypa/manylinux2014_aarch64
            arch: arm64
    runs-on: ${{ matrix.runner }}
    # x86_64 is the validated anchor; arm64 is experimental until shaken out.
    continue-on-error: ${{ matrix.arch == 'arm64' }}
    steps:
      - uses: actions/checkout@v6
      - name: Free disk space
        run: sudo ./.github/cleanup-rootfs.sh
      - name: Disk before
        run: df -h / /mnt
      - name: Build image
        run: docker build -t niiet-rv-linux --build-arg BASE=${{ matrix.base }} -f build/Dockerfile.linux build/
      - name: Cache patched sources
        id: src
        uses: actions/cache@v5
        with:
          path: /mnt/sources
          key: niiet-src-linux-${{ matrix.arch }}-${{ hashFiles('patch/riscv-*.patch') }}-v1
      - name: Prepare sources
        if: steps.src.outputs.cache-hit != 'true'
        run: |
          sudo mkdir -p /mnt/sources && sudo chown "$USER" /mnt/sources
          SOURCES=/mnt/sources bash build/prepare-sources.sh
      - name: Build (gcc + clang + package)
        run: |
          sudo mkdir -p /mnt/work /mnt/prefix /mnt/out
          sudo chown "$USER" /mnt/work /mnt/prefix /mnt/out
          docker run --rm \
            -v "$PWD":/src -v /mnt/sources:/sources \
            -v /mnt/work:/work -v /mnt/prefix:/opt/riscv -v /mnt/out:/out \
            niiet-rv-linux \
            bash -c '/src/build/build-baremetal.sh all'
      - name: Disk after
        if: always()
        run: df -h / /mnt
      - uses: actions/upload-artifact@v7
        with:
          name: riscv32-imafdc-elf-${{ matrix.arch }}-linux-gcc-clang
          path: /mnt/out/*.tar.xz
          compression-level: 0
```

- [ ] **Step 2: Verify the workflow still parses as YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/niiet-toolchain.yaml')); print('YAML OK')"`
Expected: `YAML OK`

- [ ] **Step 3: Verify both Linux arches are present and arm64 is non-blocking**

Run: `grep -n 'manylinux2014_aarch64\|ubuntu-24.04-arm\|arch == .arm64' .github/workflows/niiet-toolchain.yaml`
Expected: lines for the aarch64 base, the arm runner, and the `continue-on-error` expression.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/niiet-toolchain.yaml
git commit -m "CI: matrix the Linux job over x86_64 + arm64 (native arm runner)"
```

---

### Task 4: Refactor CI — matrix the macOS job (arm64 + x86_64)

**Files:**
- Modify: `.github/workflows/niiet-toolchain.yaml` (replace the `macos-arm64` job with a matrixed `macos` job)

- [ ] **Step 1: Replace the `macos-arm64:` job**

Replace the entire `macos-arm64:` job with:

```yaml
  macos:
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: macos-14
            arch: arm64
          - os: macos-13
            arch: x86_64
    runs-on: ${{ matrix.os }}
    continue-on-error: true        # experimental until shaken out on the runner
    steps:
      - uses: actions/checkout@v6
      - name: Install build deps
        # 'flock' is required by the toolchain Makefile (sysroot install lock) and is
        # absent on macOS; GNU bison/sed/make/gawk must also precede the system ones.
        run: |
          brew install flock bison gawk gnu-sed make gmp mpfr libmpc isl expat \
                       ninja cmake autoconf automake libtool texinfo python@3.11
      - name: Cache patched sources
        id: src
        uses: actions/cache@v5
        with:
          path: ${{ github.workspace }}/sources
          key: niiet-src-${{ matrix.arch }}-macos-${{ hashFiles('patch/riscv-*.patch') }}-v1
      - name: Prepare sources
        if: steps.src.outputs.cache-hit != 'true'
        run: SOURCES="$GITHUB_WORKSPACE/sources" bash build/prepare-sources.sh
      - name: Build (gcc + clang + package)
        # NOTE: macOS source trees may need a case-sensitive volume (see macos-build.md).
        # brew --prefix is /opt/homebrew on arm64 and /usr/local on Intel.
        run: |
          B="$(brew --prefix)/opt"
          export PATH="$B/flock/bin:$B/bison/bin:$B/gnu-sed/libexec/gnubin:$B/gawk/libexec/gnubin:$B/make/libexec/gnubin:$PATH"
          # Homebrew installs gmp/mpfr/mpc/isl under $(brew --prefix)/opt; configure
          # (gdb/gcc) doesn't search there by default.
          export LDFLAGS="-L$B/gmp/lib -L$B/mpfr/lib -L$B/libmpc/lib -L$B/isl/lib"
          export CPPFLAGS="-I$B/gmp/include -I$B/mpfr/include -I$B/libmpc/include -I$B/isl/include"
          SRC="$GITHUB_WORKSPACE" SOURCES="$GITHUB_WORKSPACE/sources" \
          WORK="$GITHUB_WORKSPACE/work" PREFIX="$GITHUB_WORKSPACE/install/riscv" \
          OUT="$GITHUB_WORKSPACE/out" \
            bash build/build-baremetal.sh all
      - uses: actions/upload-artifact@v7
        with:
          name: riscv32-imafdc-elf-${{ matrix.arch }}-macos-gcc-clang
          path: out/*.tar.xz
          compression-level: 0
```

- [ ] **Step 2: Verify the workflow still parses as YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/niiet-toolchain.yaml')); print('YAML OK')"`
Expected: `YAML OK`

- [ ] **Step 3: Verify both macOS runners and the dynamic Homebrew prefix are present**

Run: `grep -n 'macos-13\|macos-14\|brew --prefix' .github/workflows/niiet-toolchain.yaml`
Expected: both runner labels and the `B="$(brew --prefix)/opt"` line.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/niiet-toolchain.yaml
git commit -m "CI: matrix the macOS job over arm64 + x86_64 (dynamic Homebrew prefix)"
```

---

### Task 5: Add clang to the Windows job + rename its artifact

**Files:**
- Modify: `.github/workflows/niiet-toolchain.yaml` (the `windows-x86_64` job: apt deps, build steps, artifact name + header comment)

- [ ] **Step 1: Add cmake + ninja to the Windows apt install**

In the `windows-x86_64` job's "Install build deps" step, replace:
```yaml
            build-essential autoconf automake libtool texinfo bison flex gawk gettext \
            libgmp-dev libmpfr-dev libmpc-dev zlib1g-dev \
            python3 curl xz-utils file
```
with:
```yaml
            build-essential autoconf automake libtool texinfo bison flex gawk gettext \
            libgmp-dev libmpfr-dev libmpc-dev zlib1g-dev \
            cmake ninja-build python3 python3-distutils curl xz-utils file
```

- [ ] **Step 2: Insert a clang cross step between the gcc build and the package step**

Replace the "Build (gcc canadian-cross to mingw + gdb)" step's `run:` body:
```yaml
        run: |
          sudo mkdir -p /mnt/work /mnt/prefix-win /mnt/out
          sudo chown "$USER" /mnt/work /mnt/prefix-win /mnt/out
          SRC="$PWD" SOURCES=/mnt/sources WORK=/mnt/work \
          PREFIX=/mnt/prefix-win OUT=/mnt/out WITH_HOST=x86_64-w64-mingw32 \
            bash build/build-baremetal.sh gcc
          SRC="$PWD" PREFIX=/mnt/prefix-win OUT=/mnt/out WITH_HOST=x86_64-w64-mingw32 \
            bash build/build-baremetal.sh package
```
with:
```yaml
        run: |
          sudo mkdir -p /mnt/work /mnt/prefix-win /mnt/out
          sudo chown "$USER" /mnt/work /mnt/prefix-win /mnt/out
          SRC="$PWD" SOURCES=/mnt/sources WORK=/mnt/work \
          PREFIX=/mnt/prefix-win OUT=/mnt/out WITH_HOST=x86_64-w64-mingw32 \
            bash build/build-baremetal.sh gcc
          SRC="$PWD" SOURCES=/mnt/sources WORK=/mnt/work \
          PREFIX=/mnt/prefix-win OUT=/mnt/out WITH_HOST=x86_64-w64-mingw32 \
            bash build/build-baremetal.sh clang
          SRC="$PWD" PREFIX=/mnt/prefix-win OUT=/mnt/out WITH_HOST=x86_64-w64-mingw32 \
            bash build/build-baremetal.sh package
```
Also rename that step: change `name: Build (gcc canadian-cross to mingw + gdb)` to `name: Build (gcc + gdb canadian-cross + clang cross to mingw)`.

- [ ] **Step 3: Rename the Windows artifact to the symmetric name**

In the `windows-x86_64` job's `upload-artifact`, change:
```yaml
          name: riscv32-imafdc-elf-x86_64-windows-gcc
```
to:
```yaml
          name: riscv32-imafdc-elf-x86_64-windows-gcc-clang
```
And update the workflow header comment line:
```
#   - Windows x86_64 (mingw canadian-cross, GNU only)          [experimental: clang TODO]
```
to:
```
#   - Windows x86_64 (mingw canadian-cross: gcc+gdb + cross clang)  [experimental]
```

- [ ] **Step 4: Verify the workflow parses and the Windows clang wiring is present**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/niiet-toolchain.yaml')); print('YAML OK')"
grep -n 'build-baremetal.sh clang\|windows-gcc-clang\|cmake ninja-build' .github/workflows/niiet-toolchain.yaml
```
Expected: `YAML OK`; a `build-baremetal.sh clang` line, the `windows-gcc-clang` artifact name, and the cmake/ninja apt line.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/niiet-toolchain.yaml
git commit -m "Windows CI: build cross clang stage + rename artifact to gcc-clang"
```

---

### Task 6: Update docs/memory and trigger CI

**Files:**
- Modify: `build/BUILD-NOTES.md` (per-host + CI sections)
- Modify: `/Users/phlyash/.claude/projects/-Users-phlyash-study-NIIET-riscv-toolchain-riscv-gnu-toolchain/memory/build-execution-plan.md` (append status item)

- [ ] **Step 1: Update BUILD-NOTES.md per-host + CI sections**

In `build/BUILD-NOTES.md`, update the per-host bullets so Linux notes "x86_64 + arm64 (native arm runner)", macOS notes "arm64 + x86_64 (native, brew prefix auto-detected)", and Windows notes "gcc+gdb canadian cross **plus cross-built clang/lld** (native tblgen + static host link)". In the CI section, list the final jobs: `linux` (matrix ×2), `macos` (matrix ×2), `windows-x86_64`. Remove the "clang-for-Windows cross" item from "Remaining work" (now done) and the "GNU only" Windows wording.

- [ ] **Step 2: Append a status item to the memory build-execution-plan**

Append item 13 to `build-execution-plan.md` recording: matrix expanded to 5 symmetric targets (linux x86_64/arm64, macos x86_64/arm64, windows x86_64), Windows arm64 dropped (no stable aarch64 mingw GCC), Windows clang cross-built (native tblgen + LLVM_NATIVE_TOOL_DIR + static mingw host link, optional deps OFF), Dockerfile base parameterized via ARG BASE, macOS uses `$(brew --prefix)`. Note all new targets are continue-on-error / CI-validated only.

- [ ] **Step 3: Commit the docs**

```bash
git add build/BUILD-NOTES.md
git commit -m "docs: 5-target matrix + Windows clang in build notes"
```

- [ ] **Step 4: Push the branch**

```bash
git push gh niiet-baremetal-toolchain
```
Expected: branch updated on `phlyash/riscv-toolchain` (network op — may need sandbox disabled).

- [ ] **Step 5: Trigger CI and collect results**

The user runs the **NIIET baremetal toolchain** workflow from the GitHub Actions UI (`workflow_dispatch`) on branch `niiet-baremetal-toolchain`. Authoritative validation happens here — this is the first real build of the two new native targets and the Windows clang cross. Expected artifacts:
- `riscv32-imafdc-elf-x86_64-linux-gcc-clang` (anchor, must pass)
- `riscv32-imafdc-elf-arm64-linux-gcc-clang`
- `riscv32-imafdc-elf-arm64-macos-gcc-clang`
- `riscv32-imafdc-elf-x86_64-macos-gcc-clang`
- `riscv32-imafdc-elf-x86_64-windows-gcc-clang`

The user pastes any failing job logs; iterate per failure (Windows clang cross is the most likely to need adjustment — watch for tblgen-not-found, mingw winpthread/static-link errors, or a disabled-dep that LLVM actually requires).

---

## Self-Review

**Spec coverage:**
- Linux arm64 → Task 1 (Dockerfile ARG) + Task 3 (matrix job). ✅
- macOS x86_64 → Task 4 (matrix + brew prefix). ✅
- Windows clang cross (native tblgen, mingw compilers, static link, deps OFF, same PREFIX) → Task 2 (script) + Task 5 (CI wiring). ✅
- Packaging/naming (windows → gcc-clang; native names auto) → Task 5 + existing scheme. ✅
- CI workflow shape (linux ×2, macos ×2, windows) → Tasks 3/4/5. ✅
- Windows arm64 dropped → not implemented, recorded in docs (Task 6). ✅

**Placeholder scan:** No TBD/TODO left in code/config; the only "TODO" removed is the obsolete one in build-baremetal.sh (Task 2) and BUILD-NOTES (Task 6). Doc edits in Task 6 describe concrete content. ✅

**Type/name consistency:** `stage_clang_cross` defined (Task 2 Step 1) and called (Task 2 Step 2) with matching `$PY`, `$LLVM_DIST` args. Artifact names use the `riscv32-imafdc-elf-<arch>-<os>-gcc-clang` scheme consistently. Cache keys are arch-suffixed per job. `WITH_HOST=x86_64-w64-mingw32` consistent across gcc/clang/package Windows steps. ✅
