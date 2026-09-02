# Windows LLVM via llvm-mingw and GDB Runtime Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Windows LLVM tools with pinned llvm-mingw, prove the packaged Clang works on native Windows, and reject every undeclared GDB/toolchain host dependency.

**Architecture:** Keep the GNU MinGW Canadian-cross responsible for GCC, binutils, GDB, newlib, libgcc, and libstdc++. Add a verified llvm-mingw bootstrap used exclusively by the Windows LLVM cross stage, then gate release publication on a native Windows optimization and GCC-sysroot link smoke test. Replace Linux's dependency denylist with a fail-closed glibc allowlist while retaining GDB's statically linked expat and TUI support.

**Tech Stack:** Bash, CMake/Ninja, llvm-mingw 20260616 msvcrt, GNU MinGW, PowerShell, GitHub Actions, Python `unittest`, `readelf`, `objdump`, actionlint.

**Spec:** `docs/superpowers/specs/2026-09-02-llvm-mingw-and-gdb-runtime-design.md`

## Global Constraints

- Use only `llvm-mingw-20260616-msvcrt-ubuntu-22.04-x86_64.tar.xz` with SHA-256 `a1f7968b48ba8d949194d6dee6c76f3cd0f61cba91658599af2c2c834a55ab87`.
- llvm-mingw compiles only Windows host LLVM/Clang/LLD; GNU MinGW continues to build GCC, binutils, and GDB.
- Do not build compiler-rt, libc++, or another RISC-V runtime; packaged Clang must use the existing GCC-built newlib, libgcc, libstdc++, headers, and multilibs.
- Keep GDB XML target descriptions, TUI, and curses enabled; expat and curses remain statically linked.
- Linux packages may depend only on the explicit glibc ABI allowlist; Windows packages may depend only on the existing system-DLL allowlist; macOS packages may not depend on Homebrew paths.
- Release publication must not run until the packaged Windows `clang.exe` succeeds on a native Windows runner at `-Og` and links through the packaged GCC sysroot.
- Preserve the unrelated untracked `.tmp-task4-report.md` file.

## File Structure

- Create `build/prepare-llvm-mingw.sh`: atomically download, authenticate, extract, validate, and print the llvm-mingw root.
- Create `build/test-prepare-llvm-mingw.sh`: exercise checksum failure, atomic cleanup, idempotent reuse, and required-tool validation with small local fixtures.
- Modify `build/build-baremetal.sh`: consume `LLVM_MINGW_ROOT` only inside `stage_clang_cross` and configure CMake with llvm-mingw tools.
- Modify `build/test-build-config.sh`: add Windows-Clang fixtures and assertions proving llvm-mingw selection, GNU-stage isolation, static host linkage, and shared target-runtime configuration.
- Modify `build/check-host-runtime.sh`: inspect Linux `DT_NEEDED` entries with `readelf` and reject everything outside the glibc allowlist.
- Create `build/test-host-runtime.sh`: hermetic regression cases for allowed glibc entries, expat, unknown libraries, and executable GDB XML feature checks.
- Create `build/test-windows-clang.ps1`: execute the packaged compiler on Windows, reproduce the optimizer case, and link against the packaged GCC sysroot.
- Create `build/test-niiet-toolchain-workflow.py`: enforce the pinned bootstrap, Windows smoke-job boundary, artifact flow, and release gate in the workflow.
- Modify `.github/workflows/niiet-toolchain.yaml`: prepare llvm-mingw, pass its root to the LLVM stage, add the Windows smoke job, and gate release on it.
- Modify `.github/workflows/build.yaml`: run every new fast regression test.
- Modify `build/BUILD-NOTES.md`: document the new Windows host compiler, native smoke boundary, and runtime allowlist.

---

### Task 1: Embed expat in GDB and make host validation fail closed

**Files:**
- Create: `build/test-host-runtime.sh`
- Modify: `build/build-baremetal.sh:160-215`
- Modify: `build/check-host-runtime.sh:4-93`
- Modify: `build/test-build-config.sh:183-321`
- Modify: `.github/workflows/build.yaml:17-23`

**Interfaces:**
- Consumes: the static expat archives prepared under `$DEPS`, `PREFIX`,
  `WITH_HOST`, and GDB's configuration/XML command output.
- Produces: GDB configure flags `--with-expat=yes
  --with-libexpat-prefix=$DEPS --with-libexpat-type=auto`; `READELF`
  override for hermetic tests; `is_linux_system_library(name) -> status`; a
  zero/non-zero checker exit status with the offending feature, file, and
  dependency printed on failure.

- [ ] **Step 1: Write failing runtime-policy tests**

Create a fake prefix with executable `bin/riscv32-unknown-elf-gdb`. For
`--configuration`, it prints:

```bash
#!/usr/bin/env bash
printf '%s\n' '  --enable-tui' '  --with-curses' '  --with-expat'
```

For the batch command `set tdesc filename`, it prints `warning: while parsing
target description: no element found`, proving that execution reached an XML
parser. Add a negative fixture whose configuration prints `--without-expat`
and whose XML command prints `XML support was disabled at compile time`; assert
that either signal makes the checker exit 1.

Create a fake `readelf` selected through `READELF="$TMP/readelf"`. It must return success for `-h` and emit the text from `FAKE_NEEDED` for `-d`. Add these cases:

```bash
run_allowed 'libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-x86-64.so.2'
run_allowed 'libc.so.6 libm.so.6 ld-linux-aarch64.so.1'
run_forbidden 'libc.so.6 libexpat.so.1' 'libexpat.so.1'
run_forbidden 'libc.so.6 libcurl.so.4' 'libcurl.so.4'
```

Each `run_forbidden` invocation must assert exit status 1 and match both `FORBIDDEN Linux runtime dependency` and the exact rejected SONAME. Each allowed case must assert `Host runtime dependency check passed.`.

Extend both `test_linux_gcc_disables_libcc1` and
`test_windows_gdb_statically_links_winpthread` to require these exact captured
GDB configure arguments:

```text
--with-expat=yes
--with-libexpat-prefix=<fake dependency prefix>
--with-libexpat-type=auto
--enable-tui
--with-curses
```

Assert that the obsolete `--with-expat=<fake dependency prefix>` form is
absent.

- [ ] **Step 2: Run the new tests and confirm RED**

Run:

```bash
bash build/test-host-runtime.sh
bash build/test-build-config.sh linux-gcc-no-libcc1
bash build/test-build-config.sh windows-gdb-static-winpthread
```

Expected: `test-host-runtime.sh` fails because the current checker accepts both
unknown `libcurl.so.4` and GDB without XML. Both build-configuration tests fail
because the build still passes the dependency directory as the boolean
`--with-expat` value.

- [ ] **Step 3: Make static expat mandatory in every GDB build**

In both native and Windows `GDB_EXTRA`, replace:

```text
--with-expat=$DEPS --with-libexpat-type=static
```

with:

```text
--with-expat=yes --with-libexpat-prefix=$DEPS --with-libexpat-type=auto
```

`yes` makes a failed expat link probe fatal; the dedicated prefix option makes
GDB find `$DEPS/include/expat.h` and `$DEPS/lib/libexpat.a`. Because the prefix
contains no shared Expat, `auto` selects that archive but does not recursively
force its system `libm` dependency to use an unavailable `libm.a`. Do not enable
an expat shared build or copy an expat shared library into the package.

- [ ] **Step 4: Implement the Linux `DT_NEEDED` allowlist and XML probe**

Replace the Linux `file`/`ldd` denylist with `readelf` inspection. The accepted SONAME function must have this exact policy:

```bash
is_linux_system_library() {
    case "$1" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|\
        ld-linux-x86-64.so.2|ld-linux-aarch64.so.1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
```

Use `${READELF:-readelf}` for both ELF detection and dynamic-section parsing. For every `Shared library: [name]`, reject a name outside the function above, print the file, the rejected SONAME, and the complete dependency list, then set the aggregate failure status without stopping the scan.

For native Linux and macOS, extend the GDB feature checker to require
`--with-expat` and reject `--without-expat`. Create a temporary invalid XML file
containing `<?xml version="1.0"?><target>`, invoke GDB with `-nx -batch -ex "set
tdesc filename $xml_file"`, and fail if its combined output contains `XML
support was disabled at compile time`. Always remove the temporary file.

- [ ] **Step 5: Run focused and complete fast tests**

Run:

```bash
bash build/test-host-runtime.sh
bash build/test-build-config.sh all
bash -n build/check-host-runtime.sh build/test-host-runtime.sh build/test-build-config.sh
```

Expected: all tests print `PASS`; syntax checks are silent. The captured native
and Windows configure arguments both make expat mandatory and static.

- [ ] **Step 6: Wire the regression into ordinary CI**

Add this command to `test-host-link-config` in `.github/workflows/build.yaml` immediately after `test-build-config.sh`:

```bash
bash build/test-host-runtime.sh
```

- [ ] **Step 7: Commit static XML support and the fail-closed dependency policy**

```bash
git add build/build-baremetal.sh build/check-host-runtime.sh build/test-host-runtime.sh build/test-build-config.sh .github/workflows/build.yaml
git commit -m "fix: embed expat in GDB"
```

---

### Task 2: Add the pinned llvm-mingw bootstrap

**Files:**
- Create: `build/prepare-llvm-mingw.sh`
- Create: `build/test-prepare-llvm-mingw.sh`
- Modify: `.github/workflows/build.yaml:17-24`

**Interfaces:**
- Consumes: optional `WORK` directory and the existing variadic
  `fetch_source(destination, mirror_urls)` helper.
- Produces: one absolute llvm-mingw root on stdout; diagnostics on stderr; an atomic `$WORK/llvm-mingw-20260616-msvcrt` installation with `.complete` marker.

- [ ] **Step 1: Write failing bootstrap tests**

Structure `prepare-llvm-mingw.sh` so its functions can be sourced without running `main`: `sha256_file(path)`, `verify_archive(path, expected)`, `validate_root(path)`, and `main`. In `test-prepare-llvm-mingw.sh`, source the script and test:

```bash
good="$TMP/good.tar.xz"
printf 'fixture archive\n' > "$good"
digest="$(sha256sum "$good" | awk '{print $1}')"
verify_archive "$good" "$digest"
if verify_archive "$good" "$(printf '0%.0s' {1..64})"; then
    fail "a checksum mismatch was accepted"
fi
```

Create a fake extracted root containing executable files with these exact names and assert `validate_root` succeeds. Remove each file in turn and assert it fails:

```text
bin/x86_64-w64-mingw32-clang
bin/x86_64-w64-mingw32-clang++
bin/x86_64-w64-mingw32-windres
bin/llvm-ar
bin/llvm-ranlib
bin/llvm-strip
```

Use a fake `FETCH_CURL` plus a tiny generated tar.xz to invoke `main` in a subprocess. Assert a valid archive creates `.complete`, prints the final root, and a second invocation does not call the downloader. Run a mismatched archive case and assert neither the final root nor an extraction temporary directory remains.

- [ ] **Step 2: Run the bootstrap test and confirm RED**

Run:

```bash
bash build/test-prepare-llvm-mingw.sh
```

Expected: FAIL because `build/prepare-llvm-mingw.sh` does not exist.

- [ ] **Step 3: Implement the authenticated atomic bootstrap**

Use these immutable constants in `prepare-llvm-mingw.sh`:

```bash
LLVM_MINGW_VERSION=20260616
LLVM_MINGW_VARIANT=msvcrt
LLVM_MINGW_ASSET="llvm-mingw-20260616-msvcrt-ubuntu-22.04-x86_64.tar.xz"
LLVM_MINGW_SHA256=a1f7968b48ba8d949194d6dee6c76f3cd0f61cba91658599af2c2c834a55ab87
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20260616/$LLVM_MINGW_ASSET"
```

`main` must:

1. use `$WORK/downloads/$LLVM_MINGW_ASSET` and `$WORK/llvm-mingw-20260616-msvcrt`;
2. reuse a final root only when `.complete` exists and `validate_root` passes;
3. download with `fetch_source` when the archive is missing or fails its pinned checksum;
4. verify the checksum again before extraction;
5. extract with `tar -xJf "$archive" -C "$temporary_root" --strip-components=1` into a same-filesystem temporary directory;
6. validate all six tools, create `.complete`, then atomically rename the temporary root;
7. remove temporary content through an EXIT trap on every failure;
8. print only the absolute final root to stdout.

Permit test-only fixture values through positional arguments to `main` rather than environment overrides; direct script execution must always call `main` with the immutable production constants.

- [ ] **Step 4: Run bootstrap, fetch-source, and syntax tests**

Run:

```bash
bash build/test-prepare-llvm-mingw.sh
bash build/test-fetch-source.sh
bash -n build/prepare-llvm-mingw.sh build/test-prepare-llvm-mingw.sh
```

Expected: both suites print `PASS`; syntax checks are silent.

- [ ] **Step 5: Wire the bootstrap regression into ordinary CI**

Add this command beside the other fast shell tests in `.github/workflows/build.yaml`:

```bash
bash build/test-prepare-llvm-mingw.sh
```

- [ ] **Step 6: Commit the bootstrap**

```bash
git add build/prepare-llvm-mingw.sh build/test-prepare-llvm-mingw.sh .github/workflows/build.yaml
git commit -m "build: add pinned llvm-mingw bootstrap"
```

---

### Task 3: Compile Windows LLVM with llvm-mingw only

**Files:**
- Modify: `build/build-baremetal.sh:244-318`
- Modify: `build/test-build-config.sh:14-181,293-321`

**Interfaces:**
- Consumes: required `LLVM_MINGW_ROOT` for `WITH_HOST=x86_64-w64-mingw32` during `build-baremetal.sh clang`.
- Produces: Windows `clang.exe`, Clang tools, and LLD built by llvm-mingw and statically linked to its host runtimes; no change to RISC-V target-runtime contents.

- [ ] **Step 1: Add failing Windows-Clang configuration tests**

Extend the fixture setup with `$FAKE_LLVM_MINGW/bin` and executable fakes for the six tools listed in Task 2. Add `run_windows_clang` which pre-creates native tblgen fakes and invokes:

```bash
PATH="$FAKE_BIN:$PATH" \
SRC="$FAKE_SRC" \
SOURCES="$TMP/sources" \
WORK="$work" \
PREFIX="$prefix" \
OUT="$TMP/out" \
WITH_HOST=x86_64-w64-mingw32 \
LLVM_MINGW_ROOT="$FAKE_LLVM_MINGW" \
    bash "$ROOT/build/build-baremetal.sh" clang
```

Assert `cmake.args` contains these exact tool selections:

```text
-DCMAKE_C_COMPILER=<fake-root>/bin/x86_64-w64-mingw32-clang
-DCMAKE_CXX_COMPILER=<fake-root>/bin/x86_64-w64-mingw32-clang++
-DCMAKE_RC_COMPILER=<fake-root>/bin/x86_64-w64-mingw32-windres
-DCMAKE_AR=<fake-root>/bin/llvm-ar
-DCMAKE_RANLIB=<fake-root>/bin/llvm-ranlib
-DCMAKE_STRIP=<fake-root>/bin/llvm-strip
-DLLVM_HOST_TRIPLE=x86_64-w64-windows-gnu
-DCMAKE_EXE_LINKER_FLAGS=-static
-DCMAKE_SHARED_LINKER_FLAGS=-static
-DCMAKE_MODULE_LINKER_FLAGS=-static
```

Assert none of the CMake compiler selections contains `x86_64-w64-mingw32-gcc` or `x86_64-w64-mingw32-g++`. Invoke the same command without `LLVM_MINGW_ROOT` and assert it fails before CMake with `LLVM_MINGW_ROOT is required`.

Finally, rerun `run_windows_gcc` with an invalid `LLVM_MINGW_ROOT` and assert the GNU GCC/GDB configuration remains successful. This proves stage isolation.

- [ ] **Step 2: Run the Windows-Clang case and confirm RED**

Run:

```bash
bash build/test-build-config.sh windows-clang-llvm-mingw
```

Expected: FAIL because the cross stage still selects GNU MinGW GCC/G++.

- [ ] **Step 3: Select llvm-mingw explicitly in `stage_clang_cross`**

At the start of the function, require an absolute `LLVM_MINGW_ROOT`, define `LLVM_MINGW_BIN="$LLVM_MINGW_ROOT/bin"`, and validate the same six executables as the bootstrap script. Configure CMake with the exact tool paths from Step 1.

Replace GNU-specific host linker flags `-static -static-libgcc -static-libstdc++` with `-static` for executable, shared, and module link flags. Keep all existing LLVM project selection, native tblgen, disabled optional dependencies, RISCV target, default target triple, and distribution components unchanged.

Do not prepend llvm-mingw to global `PATH`; pass absolute CMake tool paths so the prior GCC/GDB Canadian-cross continues to resolve GNU MinGW.

- [ ] **Step 4: Run all build-configuration tests**

Run:

```bash
bash build/test-build-config.sh windows-clang-llvm-mingw
bash build/test-build-config.sh windows-gdb-static-winpthread
bash build/test-build-config.sh all
bash -n build/build-baremetal.sh build/test-build-config.sh
```

Expected: all named tests print `PASS`; syntax checks are silent.

- [ ] **Step 5: Commit the compiler switch**

```bash
git add build/build-baremetal.sh build/test-build-config.sh
git commit -m "fix: build Windows LLVM with llvm-mingw"
```

---

### Task 4: Gate releases on execution of packaged Clang on Windows

**Files:**
- Create: `build/test-windows-clang.ps1`
- Create: `build/test-niiet-toolchain-workflow.py`
- Modify: `.github/workflows/niiet-toolchain.yaml:17-18,287-491`
- Modify: `.github/workflows/build.yaml:17-25`

**Interfaces:**
- Consumes: the `niiet-riscv-toolchain-windows-x86_64.zip` artifact produced by `windows-x86_64`.
- Produces: a `windows-clang-smoke` job on `windows-2022`; release job may start only after this job succeeds.

- [ ] **Step 1: Write failing workflow-contract tests**

In `build/test-niiet-toolchain-workflow.py`, load `.github/workflows/niiet-toolchain.yaml`, isolate jobs by two-space YAML job headings, and assert:

```python
self.assertIn("id: llvm_mingw", windows_build)
self.assertIn("bash build/prepare-llvm-mingw.sh", windows_build)
self.assertIn("LLVM_MINGW_ROOT:", windows_build)
self.assertIn("needs: windows-x86_64", windows_smoke)
self.assertIn("runs-on: windows-2022", windows_smoke)
self.assertIn("name: niiet-riscv-toolchain-windows-x86_64.zip", windows_smoke)
self.assertIn("pwsh -File build/test-windows-clang.ps1", windows_smoke)
self.assertRegex(release, r"(?s)needs:.*- windows-x86_64.*- windows-clang-smoke")
```

Add mutation tests that remove each of the following individually and prove the contract assertion fails: checksum bootstrap call, `LLVM_MINGW_ROOT` environment mapping, smoke job `needs`, ZIP artifact name, PowerShell invocation, and release dependency.

- [ ] **Step 2: Write the native PowerShell smoke script**

The script accepts mandatory `-Archive` and optional `-WorkDir`. It must:

1. resolve both paths and recreate only its dedicated work directory;
2. `Expand-Archive` the ZIP whose payload has `bin/` at its root;
3. assert `bin/clang.exe`, `bin/riscv32-unknown-elf-gcc.exe`,
   `bin/riscv32-unknown-elf-gdb.exe`, and
   `bin/riscv32-unknown-elf-readelf.exe` exist;
4. run `clang.exe --version` and check every native command through `$LASTEXITCODE`;
5. write ASCII test sources inside the work directory;
6. compile the optimizer reproducer at `-Og`;
7. compile and link the GCC-runtime program through the packaged sysroot;
8. use packaged `readelf.exe -h` and assert `Machine:` contains `RISC-V`;
9. run packaged GDB with an invalid XML target description and assert its
   output reports an XML syntax error but never `XML support was disabled at
   compile time`.

Use this exact optimizer reproducer:

```c
void spin(void) {
    for (;;) {
        __asm__ volatile("ebreak");
    }
}
```

Compile it with:

```powershell
& $clang --target=riscv32-unknown-elf "--gcc-toolchain=$root" `
    "--sysroot=$root/riscv32-unknown-elf" `
    -march=rv32imafc_zicsr_zifencei -mabi=ilp32f -Og -c `
    $loopSource -o $loopObject
```

Use a second source containing `<stdint.h>`, a volatile 64-bit dividend, and `main`. Link it with the same target/toolchain/sysroot options plus `--rtlib=libgcc`. This must use the normal Clang driver link, not an explicit absolute `libgcc.a`, so the test proves Clang discovers the packaged GCC installation and multilib.

For the Windows GDB probe, write `<?xml version="1.0"?><target>` to an ASCII
file, invoke `riscv32-unknown-elf-gdb.exe -nx -batch -ex "set tdesc filename
$xmlFile"`, allow the expected non-zero parser result, and inspect combined
stdout/stderr. Require text matching `parsing target description|Could not load
XML target description` and reject the compile-time-disabled warning.

- [ ] **Step 3: Run workflow tests and confirm RED**

Run:

```bash
python3 build/test-niiet-toolchain-workflow.py
```

Expected: FAIL because the workflow has neither the llvm-mingw bootstrap nor `windows-clang-smoke`.

- [ ] **Step 4: Add llvm-mingw preparation to the Windows build job**

After build-directory initialization, add an `id: llvm_mingw` step that runs:

```bash
root="$(WORK=/mnt/work bash build/prepare-llvm-mingw.sh)"
echo "root=$root" >> "$GITHUB_OUTPUT"
```

Map the step output through the LLVM build step's environment rather than interpolating it into shell source:

```yaml
env:
  LLVM_MINGW_ROOT: ${{ steps.llvm_mingw.outputs.root }}
```

Keep `WITH_HOST=x86_64-w64-mingw32`; it still names the final Windows host and the GNU Canadian-cross tuple.

- [ ] **Step 5: Add the native Windows smoke job and release gate**

Add `windows-clang-smoke` after the build job:

```yaml
  windows-clang-smoke:
    needs: windows-x86_64
    runs-on: windows-2022
    steps:
      - uses: actions/checkout@v6
      - name: Download packaged Windows toolchain
        uses: actions/download-artifact@v8
        with:
          name: niiet-riscv-toolchain-windows-x86_64.zip
          path: smoke-artifact
      - name: Execute packaged Clang optimizer and link smoke tests
        shell: pwsh
        run: >-
          pwsh -File build/test-windows-clang.ps1
          -Archive smoke-artifact/niiet-riscv-toolchain-windows-x86_64.zip
          -WorkDir clang-smoke
```

Add `windows-clang-smoke` to `release.needs` after `windows-x86_64`. Do not add it to `deploy-beget.needs`; deployment is already transitively gated through `release`.

- [ ] **Step 6: Run fast workflow and script validation**

Run:

```bash
python3 build/test-niiet-toolchain-workflow.py
python3 -m py_compile build/test-niiet-toolchain-workflow.py
bash build/test-prepare-llvm-mingw.sh
bash build/test-build-config.sh all
```

On a machine with PowerShell, also run:

```bash
pwsh -NoProfile -Command "[void][scriptblock]::Create((Get-Content -Raw build/test-windows-clang.ps1))"
```

Expected: Python tests pass, compilation is silent, shell suites pass, and PowerShell parsing exits zero. If PowerShell is unavailable locally, the native GitHub job is the required execution proof.

- [ ] **Step 7: Wire the workflow regression into ordinary CI**

Add this command to `test-host-link-config` in `.github/workflows/build.yaml`:

```bash
python3 build/test-niiet-toolchain-workflow.py
```

- [ ] **Step 8: Commit the release gate**

```bash
git add build/test-windows-clang.ps1 build/test-niiet-toolchain-workflow.py .github/workflows/niiet-toolchain.yaml .github/workflows/build.yaml
git commit -m "ci: execute packaged Clang on Windows"
```

---

### Task 5: Document, verify, and run the real Windows pipeline

**Files:**
- Modify: `build/BUILD-NOTES.md:70-116`

**Interfaces:**
- Consumes: completed Tasks 1-4 and GitHub Actions access.
- Produces: operator-facing build documentation and evidence from the real Linux-hosted build plus native Windows execution.

- [ ] **Step 1: Update build documentation**

Replace the Windows LLVM description so it explicitly states:

- GNU MinGW builds GCC/binutils/GDB;
- pinned llvm-mingw `20260616` msvcrt builds only LLVM/Clang/LLD;
- both compilers share the GCC-built RISC-V sysroot and multilib libraries;
- Linux runtime dependencies are a fail-closed glibc allowlist;
- the native `windows-2022` smoke job executes `clang.exe` at `-Og` and links through `--rtlib=libgcc` before release publication.

- [ ] **Step 2: Run the complete local verification suite**

Run:

```bash
bash build/test-build-config.sh all
bash build/test-host-runtime.sh
bash build/test-prepare-llvm-mingw.sh
bash build/test-fetch-source.sh
bash build/test-release-files.sh
python3 build/test-niiet-toolchain-workflow.py
python3 build/test-beget-release.py
bash build/test-deploy-beget.sh
bash -n build/build-baremetal.sh build/check-host-runtime.sh build/prepare-llvm-mingw.sh build/test-build-config.sh build/test-host-runtime.sh build/test-prepare-llvm-mingw.sh
python3 -m py_compile build/test-niiet-toolchain-workflow.py build/test-beget-release.py
git diff --check
```

Expected: every test reports success; syntax, byte-compilation, and diff checks are silent.

- [ ] **Step 3: Lint both changed workflows**

Run the repository's pinned or otherwise available actionlint against:

```bash
actionlint .github/workflows/build.yaml .github/workflows/niiet-toolchain.yaml
```

Expected: no new diagnostics. The only acceptable existing baselines are
`.github/workflows/niiet-toolchain.yaml` SC2129 for repeated macOS
`GITHUB_PATH` appends and `.github/workflows/build.yaml`'s constant-false
multilib job; verify exact suppressions separately if line numbers move.

- [ ] **Step 4: Commit documentation**

```bash
git add build/BUILD-NOTES.md
git commit -m "docs: describe llvm-mingw Windows validation"
```

- [ ] **Step 5: Trigger a non-publishing real CI run**

Push the implementation branch, then create and push a temporary `vllvm-mingw-smoke-<short-commit>` tag. Tag events execute the three platform builds and the native Windows smoke, while both `release` and `deploy-beget` remain disabled because they require `workflow_dispatch`:

```bash
short_commit="$(git rev-parse --short=12 HEAD)"
smoke_tag="vllvm-mingw-smoke-$short_commit"
git push origin HEAD
git tag "$smoke_tag"
git push origin "$smoke_tag"
```

Do not remove the tag without explicit approval. Record the Actions run URL and confirm `windows-x86_64` and `windows-clang-smoke` both finish successfully.

- [ ] **Step 6: Inspect the real Windows artifact boundary**

From the completed run, confirm its log contains:

```text
Host runtime dependency check passed.
clang version 22.1.8
Machine:                           RISC-V
--with-expat
```

Confirm the Windows import scan contains no `libc++.dll`, `libunwind.dll`, `libwinpthread-1.dll`, `libgcc_s_*.dll`, or other non-system DLL. Confirm the native smoke generated both `loop.o` and the linked RISC-V ELF without an access violation.
Also confirm the Windows GDB XML probe reached the parser and that no platform
log contains `XML support was disabled at compile time` or a dynamic expat
dependency.

- [ ] **Step 7: Final repository integrity check**

Run:

```bash
git status --short
git log --oneline --decorate -8
git diff --check HEAD~4..HEAD
```

Expected: the implementation worktree is clean and contains the four focused
commits above the design/plan commits; the main workspace's pre-existing
`.tmp-task4-report.md` remains unchanged; the range diff check is silent.
