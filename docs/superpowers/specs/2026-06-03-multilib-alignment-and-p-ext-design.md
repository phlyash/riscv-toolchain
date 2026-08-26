# Multilib alignment (clang↔gcc) + P extension — design

Date: 2026-06-03
Branch: `niiet-baremetal-toolchain`

## Goal

Make clang and GCC select the **same multilib `.a` set** for a given `-march`/`-mabi`
(today their arch-string canonicalization differs, so clang can silently fall back
to a less-specific GCC multilib), and **add the P (DSP/packed-SIMD) extension** to
the multilib set so both compilers can target `rv32imafdcp` / `rv32imcp`.

This builds on the existing GCC 14.1.0 (CloudBEAR base `cd0059a`) + snippy clang
toolchain; no compiler version change. The CloudBEAR GCC patch already implements
`p` → `{zmmul, zbpbo, zpn, zpsfoperand}` at ISA spec v0.9.11 (plus custom
`xbp`/`xgost`); snippy clang is confirmed (by the user) to accept the same march.

## Background: why they mismatch today

GCC's multilib directory names carry the `_zicsr_zifencei` suffix
(`rv32imc_zicsr_zifencei/`), while clang normalizes `-march=rv32imc` to the bare
form (no suffix) under ISA spec 20191213. The strings are ABI-compatible but not
textually equal, so clang's multilib selector may not land on the exact GCC dir.
The existing bare 7th entry (`rv32imafdc-ilp32d`) already proves a bare arch string
resolves cleanly from clang.

## Section 1 — Multilib naming alignment

In `build/build-baremetal.sh`:

1. Pin the modern ISA spec on the GCC configure: add `--with-isa-spec=20191213`
   (so GCC's canonical forms match the spec clang assumes; base `i` does not
   implicitly absorb zicsr/zifencei).
2. Rewrite `MULTILIB` with **bare canonical** arch strings (drop the explicit
   `_zicsr_zifencei`), and add the two P variants:

   ```
   rv32i-ilp32--;rv32im-ilp32--;rv32imc-ilp32--;rv32imac-ilp32--;rv32imafc-ilp32f--;rv32imafdc-ilp32d--;rv32imcp-ilp32--;rv32imafdcp-ilp32d--
   ```

   8 variants. The old redundant bare-`rv32imafdc` 7th entry folds into entry 6.

Rationale: bare entries are what clang emits, so GCC dir names and clang lookup
keys become identical. Bare entries are also strictly more flexible for matching —
user code built with `-march=rv32imc_zicsr_zifencei` still selects the `rv32imc`
lib (extra extensions are a compatible superset).

`ARCH`/`ABI` defaults (`rv32i_zicsr_zifencei` / `ilp32`) are left unchanged: the
default selection resolves to the bare `rv32i` multilib by subset matching.

## Section 2 — P-extension variants

Two new multilibs:
- `rv32imcp` / `ilp32` — integer DSP, no FPU (common DSP-without-float case).
- `rv32imafdcp` / `ilp32d` — full hardware float + DSP.

`p` sits in canonical single-letter order after `c`, so `rv32imafdcp` and
`rv32imcp` are correctly ordered. On GCC, `p` expands via the CloudBEAR implication
table; on clang the same march is accepted, so both target these variants and
share the one built `.a` set (newlib + newlib-nano + libgcc + libstdc++).

## Section 3 — CI verification (mismatch becomes a hard failure)

This machine (arm64 Mac) cannot validate GCC's directory canonicalization or
clang's multilib selection — and correctness *is* "the two produce identical
keys". So add a post-build verification step to the Linux job that:

1. Prints `riscv32-unknown-elf-gcc -print-multi-lib` (the actual built dirs).
2. For each of the 8 arch/abi pairs, runs the installed clang with
   `--target=riscv32-unknown-elf --gcc-toolchain=$PREFIX
   --sysroot=$PREFIX/riscv32-unknown-elf -march=<arch> -mabi=<abi>
   -print-multi-directory` (and a tiny `int main(){}` compile+link with
   `-fuse-ld=lld`) and **fails the job** if clang resolves to a directory GCC did
   not build, or the link fails.

This is implemented as a script (`build/verify-multilib.sh`) invoked after
`stage_package` in the Linux CI job only (the host with a runnable native clang +
gcc; Windows/macOS reuse the same multilib set, verified transitively).

Fallback if verification fails despite the bare-string + isa-spec pin: ship a
`multilib.yaml` mapping clang's march strings onto the GCC dirs. Not implemented
up front — only if CI shows a real mismatch.

## Section 4 — Packaging / docs

- Installed multilib directory names change from `rv32imc_zicsr_zifencei/` to
  `rv32imc/` (deliberate, documented break for anyone hardcoding old paths).
- `build/BUILD-NOTES.md`: update the multilib block (8 variants, bare naming, P,
  isa-spec pin, the verify step). Memory `build-execution-plan.md`: append a
  status item.

## Out of scope

- GCC version bump (14→16): requires forward-porting the CloudBEAR patch set onto
  the gcc-16 backend; tracked separately, not part of this change.
- New ABIs: P-ext (v0.9.11) is GPR-based, so `ilp32`/`ilp32d` are unchanged.
- A full P matrix across every base variant (YAGNI — two P variants chosen).

## Validation

CI is authoritative. Success = the Linux job's verify step passes (all 8 arch/abi
pairs: clang's `-print-multi-directory` ∈ GCC's built dirs, and each links a
trivial program), and the tarball lists 8 multilib dirs with bare names.
