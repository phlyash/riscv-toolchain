# Windows LLVM via llvm-mingw and GDB runtime closure — design

Date: 2026-09-02

## Goal

Replace the GNU MinGW host compiler used to build the Windows LLVM/Clang/LLD
binaries with a pinned llvm-mingw toolchain. Keep the existing RISC-V GCC
toolchain and its target libraries unchanged, and make CI execute the resulting
Clang on Windows so an optimizer crash cannot pass artifact-only checks again.

Preserve GDB's XML support while proving that GDB and the rest of each shipped
host package do not acquire undeclared runtime libraries such as `libexpat.so`.

## Root-cause evidence

The released Windows `clang.exe` from LLVM 22.1.8 crashes reproducibly on a
minimal RISC-V infinite loop at `-Og` and above. Pass bisection reaches the
`loop-deletion` pass; disabling that pass's symbolic execution avoids the
crash. The same pinned LLVM commit works in the native Linux build and the
official Windows MSVC build, which isolates the failure to the Windows binary
built with GNU MinGW GCC rather than to the RISC-V source program or GCC
sysroot.

The current Linux 1.0 artifact was inspected and executed directly. Its
`riscv32-unknown-elf-gdb --configuration` reports `--without-expat`, and a
batch attempt to load an XML target description produces `XML support was
disabled at compile time`. It has no dynamic expat dependency because XML was
silently omitted, not because expat was successfully embedded. The matching
Windows GDB reports `--with-expat`, parses the same XML far enough to report a
syntax error, and imports no expat DLL, proving that static expat works in the
Windows path.

The native build passes `--with-expat=$DEPS`, although GDB treats
`--with-expat` as the boolean `auto/yes/no` switch and uses the separate
`--with-libexpat-prefix=DIR` option for a dependency prefix. Because the
non-boolean path value is not `yes`, a failed probe is only a warning and the
build succeeds without XML. The fix must use `--with-expat=yes`,
`--with-libexpat-prefix=$DEPS`, and `--with-libexpat-type=static`, making a
missing or unusable static archive a configure error.

## Selected approach

Use the official llvm-mingw `20260616` msvcrt Linux-hosted cross-toolchain only
for the Windows LLVM build:

- asset: `llvm-mingw-20260616-msvcrt-ubuntu-22.04-x86_64.tar.xz`
- SHA-256: `a1f7968b48ba8d949194d6dee6c76f3cd0f61cba91658599af2c2c834a55ab87`
- target host: `x86_64-w64-windows-gnu`

The msvcrt variant retains the current Windows runtime baseline. The archive is
version-pinned and hash-verified before extraction; CI never resolves a moving
`latest` release.

Building llvm-mingw from source is rejected because it adds another full LLVM
bootstrap and substantially increases CI duration without improving this
artifact's target runtime. Using an MSVC-hosted LLVM binary as the build
compiler is rejected because the cross-build runs on Linux and must continue to
compile the repository's pinned LLVM source.

## Build architecture

The GNU and LLVM halves remain deliberately separate:

1. The existing native pre-pass and MinGW Canadian-cross build GCC, binutils,
   GDB, newlib, libgcc, and libstdc++ exactly as before.
2. The native Linux tblgen pre-pass builds the LLVM table generators needed
   during a Windows cross-build.
3. The Windows LLVM stage uses clang/clang++ and LLVM binutils from the verified
   llvm-mingw installation to compile the repository's pinned LLVM 22.1.8
   sources.
4. Clang, Clang tools, and LLD install into the same final prefix as GCC/GDB.
   LLVM target runtimes are not built.

Consequently, changing the host compiler does not create a second RISC-V C/C++
runtime. Consumer invocations keep using
`--target=riscv32-unknown-elf`, `--gcc-toolchain=<prefix>`, and
`--sysroot=<prefix>/riscv32-unknown-elf`; Clang therefore reuses the GCC-built
newlib, libgcc, libstdc++, headers, linker scripts, and supported multilibs.

The build script will require an explicit llvm-mingw root for Windows LLVM
cross-builds and fail early if its compiler or required LLVM utilities are
missing. GCC/GDB stages will continue using the GNU MinGW tools and will not
inherit llvm-mingw compiler selection accidentally.

## GDB and host dependency policy

GDB keeps TUI, curses, and XML target-description support. Expat and the other
optional libraries already built by the host-dependency preparation scripts
remain statically linked. Every host build uses `--with-expat=yes`, the exact
static dependency prefix, and `--with-libexpat-type=static`; configure must
stop rather than produce a reduced GDB if the probe fails. Python, Guile,
debuginfod, source-highlight, lzma, zstd, xxhash, and NLS remain disabled.

The Linux runtime check changes from a denylist of familiar problematic
libraries to an allowlist of the small glibc ABI set observed across the shipped
host tools. Any new `DT_NEEDED` entry outside that set fails CI and prints the
offending file and complete dependency list. Architecture-specific glibc loader
names for x86_64 and aarch64 are explicitly permitted.

Windows retains its existing system-DLL allowlist. macOS retains the rule that
rejects Homebrew paths. Each completed GDB must report TUI, curses, and expat
in `--configuration`. A batch invalid-XML probe must reach expat and report an
XML syntax error; the phrase `XML support was disabled at compile time` is a
hard failure. Runtime scans independently prove that no expat shared library
or DLL is required.

## CI flow and regression coverage

The Windows Linux-hosted build job will:

1. download and hash-check llvm-mingw;
2. build GNU GCC/GDB with GNU MinGW as before;
3. build LLVM/Clang/LLD with llvm-mingw;
4. inspect all PE imports and package the result;
5. upload the Windows archives.

A dependent job on a native Windows runner will download and extract the ZIP,
then:

- run `clang.exe --version`;
- compile the minimal infinite-loop reproducer at `-Og`, exercising the pass
  that crashes in the current release;
- compile and link a RISC-V program using the packaged GCC toolchain and
  sysroot;
- check the resulting object/executable architecture.

Release publication must depend on this native smoke job, so a Windows archive
whose Clang cannot run or optimize is never released.

Fast tests will validate llvm-mingw selection and isolation from the GCC/GDB
stage. Runtime-check tests will feed permitted and forbidden dependency sets,
including `libexpat.so`, and prove that unknown libraries fail closed. GDB
feature tests will also reject `--without-expat` and the compile-time-disabled
XML warning. The final verification includes fast suites, shell syntax checks,
workflow linting, host runtime scans, XML probes, and the native Windows CI
smoke test.

## Failure handling

- A missing or hash-mismatched llvm-mingw archive stops the build before CMake.
- Missing llvm-mingw compiler utilities produce an explicit configuration
  error instead of falling back to GNU MinGW.
- A missing or unusable static expat archive stops GDB configure.
- A completed GDB that cannot parse XML fails host-runtime verification.
- Any non-allowlisted host dependency fails before packaging or publication.
- Any native Windows Clang crash or link failure blocks the release job.

## Out of scope

- Rebuilding GCC, newlib, libgcc, or libstdc++ with LLVM.
- Adding compiler-rt or libc++ target runtimes.
- Disabling GDB XML/TUI functionality to reduce size.
- Changing Linux or macOS LLVM host compilers.
- Working around the optimizer crash with permanent Clang optimization flags.
