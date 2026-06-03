# Multilib alignment + P extension — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make clang and GCC resolve the same multilib `.a` for every shipped `-march`/`-mabi`, and add the P extension as `rv32imcp/ilp32` + `rv32imafdcp/ilp32d`.

**Architecture:** Switch the GCC multilib-generator to bare canonical arch strings (what clang emits) and pin `--with-isa-spec=20191213` so GCC's directory names match clang's lookup keys; add two P variants. A new `verify-multilib.sh` runs in the Linux CI job after install and hard-fails if clang and gcc disagree on the selected multilib dir, if clang rejects any `-march`, or if the lib set won't link.

**Tech Stack:** bash, riscv-gnu-toolchain Makefile multilib-generator, GCC 14.1.0 (CloudBEAR patch base), snippy clang/lld, GitHub Actions.

**Validation reality:** This dev box is an arm64 Mac and cannot run the x86_64 toolchain or validate GCC/clang multilib canonicalization. Each task's local verification is the strongest static check available (`bash -n`, `grep`); the authoritative test is the Linux CI job's `verify-multilib.sh` step (Task 4) and the user-triggered run (Task 5).

---

### Task 1: New multilib set + ISA spec pin in build-baremetal.sh

**Files:**
- Modify: `build/build-baremetal.sh` (the `MULTILIB=` assignment near line 37; the configure call in `gcc_build_into` near lines 58-68)

- [ ] **Step 1: Replace the MULTILIB string with bare canonical arches + 2 P variants**

Replace the existing block:
```bash
# Reduced rv32 imafdc subset chain. newlib-nano built automatically.
# Last entry: bare rv32imafdc/ilp32d (double-float) so '-march=rv32imafdc -mabi=ilp32d'
# without the explicit zicsr/zifencei suffix resolves to a real multilib.
MULTILIB="rv32i_zicsr_zifencei-ilp32--;rv32im_zicsr_zifencei-ilp32--;rv32imc_zicsr_zifencei-ilp32--;rv32imac_zicsr_zifencei-ilp32--;rv32imafc_zicsr_zifencei-ilp32f--;rv32imafdc_zicsr_zifencei-ilp32d--;rv32imafdc-ilp32d--"
```
with:
```bash
# Reduced rv32 subset chain, BARE canonical arch strings (no explicit
# _zicsr_zifencei): these match what clang emits when it normalizes -march, so
# GCC's multilib dir names and clang's multilib lookup keys are identical and both
# compilers select the same .a. Combined with --with-isa-spec=20191213 below.
# Last two add the P (DSP/packed-SIMD) extension: integer DSP (no FPU) + full+DSP.
# newlib-nano is built automatically alongside each variant.
MULTILIB="rv32i-ilp32--;rv32im-ilp32--;rv32imc-ilp32--;rv32imac-ilp32--;rv32imafc-ilp32f--;rv32imafdc-ilp32d--;rv32imcp-ilp32--;rv32imafdcp-ilp32d--"
```

- [ ] **Step 2: Pin the modern ISA spec on the GCC configure**

In `gcc_build_into`, replace:
```bash
    --with-arch="$ARCH" --with-abi="$ABI" \
    --with-multilib-generator="$MULTILIB" \
```
with:
```bash
    --with-arch="$ARCH" --with-abi="$ABI" \
    --with-isa-spec=20191213 \
    --with-multilib-generator="$MULTILIB" \
```

- [ ] **Step 3: Verify shell syntax and the new content**

Run:
```bash
bash -n build/build-baremetal.sh && echo "syntax OK"
grep -n 'rv32imafdcp-ilp32d\|rv32imcp-ilp32\|with-isa-spec=20191213' build/build-baremetal.sh
grep -c '_zicsr_zifencei' build/build-baremetal.sh
```
Expected: `syntax OK`; the two P-variant matches + the isa-spec line; and `0` occurrences of `_zicsr_zifencei` (all multilib entries are now bare). Note `ARCH=rv32i_zicsr_zifencei` does NOT contain the substring `_zicsr_zifencei`? It does — so expect the count to be `1` (the `ARCH=` default line), not 0.

Corrected expectation: `grep -c '_zicsr_zifencei'` returns `1` (only the `ARCH=rv32i_zicsr_zifencei` default-selection line remains; the MULTILIB entries are bare).

- [ ] **Step 4: Commit**

```bash
git add build/build-baremetal.sh
git commit -m "multilib: bare canonical arch strings + isa-spec pin + P variants (rv32imcp, rv32imafdcp)"
```

---

### Task 2: Create build/verify-multilib.sh

**Files:**
- Create: `build/verify-multilib.sh`

- [ ] **Step 1: Write the verification script**

Create `build/verify-multilib.sh` with exactly:
```bash
#!/usr/bin/env bash
#
# Verify the GCC multilib set and the clang<->gcc agreement for the NIIET RISC-V
# baremetal toolchain. For each shipped arch/abi pair this checks:
#   (1) clang accepts -march (compile to object) — catches a clang that can't parse
#       the P extension or a normalized-arch surprise;
#   (2) gcc and clang select the SAME multilib directory (-print-multi-directory)
#       — the core "matching sets" guarantee;
#   (3) gcc links a trivial program with --specs=nosys.specs — proves the multilib
#       .a set (libc/libgcc/libnosys) for that variant is actually present.
# Exits non-zero (failing CI) on any mismatch, parse error, or link failure.
#
# Needs a RUNNABLE native gcc + clang, so run on the Linux host only.
#   PREFIX=/opt/riscv bash build/verify-multilib.sh
#
set -uo pipefail

PREFIX="${PREFIX:-/opt/riscv}"
TUPLE=riscv32-unknown-elf
GCC="$PREFIX/bin/${TUPLE}-gcc"
CLANG="$PREFIX/bin/clang"
SYSROOT="$PREFIX/${TUPLE}"

# The 8 built multilibs (must match MULTILIB in build-baremetal.sh).
PAIRS="
rv32i:ilp32
rv32im:ilp32
rv32imc:ilp32
rv32imac:ilp32
rv32imafc:ilp32f
rv32imafdc:ilp32d
rv32imcp:ilp32
rv32imafdcp:ilp32d
"

echo "=== gcc -print-multi-lib ==="
"$GCC" -print-multi-lib || true
echo

fail=0
tmp="$(mktemp -d)"
echo 'int main(void){return 0;}' > "$tmp/t.c"
CFLAGS_COMMON=(--target="$TUPLE" --gcc-toolchain="$PREFIX" --sysroot="$SYSROOT")

for p in $PAIRS; do
  arch="${p%%:*}"; abi="${p##*:}"

  # (1) clang accepts -march (compile only)
  if ! "$CLANG" "${CFLAGS_COMMON[@]}" -march="$arch" -mabi="$abi" -c "$tmp/t.c" -o "$tmp/t.o" 2>"$tmp/err"; then
    echo "CLANG-MARCH FAIL $arch/$abi:"; cat "$tmp/err"; fail=1; continue
  fi

  # (2) gcc and clang must pick the same multilib dir
  gdir="$("$GCC" -march="$arch" -mabi="$abi" -print-multi-directory 2>/dev/null)"
  cdir="$("$CLANG" "${CFLAGS_COMMON[@]}" -march="$arch" -mabi="$abi" -print-multi-directory 2>/dev/null)"
  if [ "$gdir" != "$cdir" ]; then
    echo "DIR-MISMATCH $arch/$abi: gcc=[$gdir] clang=[$cdir]"; fail=1
  fi

  # (3) the multilib .a set links (via gcc + nosys specs)
  if ! "$GCC" -march="$arch" -mabi="$abi" --specs=nosys.specs "$tmp/t.c" -o "$tmp/t.elf" 2>"$tmp/err"; then
    echo "GCC-LINK FAIL $arch/$abi:"; cat "$tmp/err"; fail=1; continue
  fi

  [ "$fail" = 0 ] && echo "ok  $arch/$abi -> ${gdir:-.}"
done
rm -rf "$tmp"

if [ "$fail" = 0 ]; then
  echo "=== ALL MULTILIBS VERIFIED (clang==gcc, links ok) ==="
else
  echo "=== MULTILIB VERIFICATION FAILED ==="
fi
exit "$fail"
```

- [ ] **Step 2: Make it executable and check syntax**

Run:
```bash
chmod +x build/verify-multilib.sh
bash -n build/verify-multilib.sh && echo "syntax OK"
```
Expected: `syntax OK`

- [ ] **Step 3: Commit**

```bash
git add build/verify-multilib.sh
git commit -m "Add verify-multilib.sh: assert clang==gcc multilib selection + P-ext parse + link"
```

---

### Task 3: Run verify-multilib in the Linux CI job

**Files:**
- Modify: `.github/workflows/niiet-toolchain.yaml` (the `linux` job — add a step after the build `docker run`)

- [ ] **Step 1: Add a verification step inside the Linux build**

In the `linux` job, the "Build (gcc + clang + package)" step ends with a `docker run … bash -c '/src/build/build-baremetal.sh all'`. Change that `bash -c` command to also run the verifier in the same container (it has the runnable gcc+clang):

Replace:
```yaml
            niiet-rv-linux \
            bash -c '/src/build/build-baremetal.sh all'
```
with:
```yaml
            niiet-rv-linux \
            bash -c '/src/build/build-baremetal.sh all && PREFIX=/opt/riscv bash /src/build/verify-multilib.sh'
```

- [ ] **Step 2: Verify the workflow parses and the verifier is wired**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/niiet-toolchain.yaml')); print('YAML OK')"
grep -n 'verify-multilib.sh' .github/workflows/niiet-toolchain.yaml
```
Expected: `YAML OK` and one `verify-multilib.sh` reference in the linux job's run block.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/niiet-toolchain.yaml
git commit -m "Linux CI: run verify-multilib after build (hard-fail on clang/gcc multilib mismatch)"
```

---

### Task 4: Docs + memory, push, trigger CI

**Files:**
- Modify: `build/BUILD-NOTES.md` (the Multilib section)
- Modify: `/Users/phlyash/.claude/projects/-Users-phlyash-study-NIIET-riscv-toolchain-riscv-gnu-toolchain/memory/build-execution-plan.md` (append status item)

- [ ] **Step 1: Update the Multilib section of BUILD-NOTES.md**

Replace the current multilib block (the `## Multilib (reduced rv32 imafdc subset chain)` section's code fence + the "(6 libs…)" line) with the 8-variant bare set and a note on naming + P + isa-spec:
```markdown
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
```

- [ ] **Step 2: Append a status item to the memory build-execution-plan**

Append item 14 to `build-execution-plan.md` recording: multilib switched to 8 bare-canonical variants + `--with-isa-spec=20191213` (clang/gcc dir-name alignment); added P-ext multilibs `rv32imcp/ilp32` and `rv32imafdcp/ilp32d` (GCC `p`→zmmul,zbpbo,zpn,zpsfoperand v0.9.11 via CloudBEAR patch; snippy clang confirmed to accept same march); new `build/verify-multilib.sh` run in Linux CI hard-fails on clang!=gcc multilib selection / clang -march reject / link failure; installed multilib dir names changed (drop `_zicsr_zifencei`). Spec+plan in docs/superpowers/{specs,plans}/2026-06-03-multilib-*.

- [ ] **Step 3: Commit the docs**

```bash
git add build/BUILD-NOTES.md
git commit -m "docs: 8-variant bare multilib set + P extension + verify step"
```

- [ ] **Step 4: Push the branch**

```bash
git push gh niiet-baremetal-toolchain
```
Expected: branch updated on `phlyash/riscv-toolchain` (network op — may need sandbox disabled).

- [ ] **Step 5: Trigger CI and collect results**

The user runs the **NIIET baremetal toolchain** workflow (`workflow_dispatch`) on branch `niiet-baremetal-toolchain`. The Linux x86_64 job is authoritative for this change: it must finish `build-baremetal.sh all` AND pass `verify-multilib.sh` (look for `=== ALL MULTILIBS VERIFIED ===`). Watch for:
- `gcc -print-multi-lib` listing 8 bare dirs (`rv32i/ilp32`, …, `rv32imafdcp/ilp32d`).
- `DIR-MISMATCH` lines → bare-string/isa-spec pin didn't fully align clang and gcc; fallback is a `multilib.yaml` for clang (spec Section 3).
- `CLANG-MARCH FAIL rv32imcp/...` or `rv32imafdcp/...` → snippy clang's P march spelling differs from GCC's; adjust the arch string.
- `GCC-LINK FAIL` → a P variant's newlib/libgcc didn't build (P-ext libgcc pattern issue).

The user pastes any failing output; iterate per failure.

---

## Self-Review

**Spec coverage:**
- Section 1 (bare naming + isa-spec pin + new MULTILIB) → Task 1. ✅
- Section 2 (P variants rv32imcp + rv32imafdcp) → Task 1 (MULTILIB) + verified in Task 2. ✅
- Section 3 (CI verification script, hard-fail, run in Linux job) → Task 2 (script) + Task 3 (wire-in). ✅
- Section 4 (packaging/docs: dir-name break, BUILD-NOTES, memory) → Task 4. ✅
- Fallback multilib.yaml is documented as conditional (Task 5 watch-list), not implemented up front — matches spec. ✅

**Placeholder scan:** No TBD/TODO. The verify script and all edits show complete content. Task 5 is a hand-off, not a code placeholder. ✅

**Type/name consistency:** The 8 arch/abi pairs are identical in `MULTILIB` (Task 1) and `PAIRS` (Task 2 script). `PREFIX=/opt/riscv`, `TUPLE=riscv32-unknown-elf`, `SYSROOT=$PREFIX/$TUPLE` consistent between script and CI invocation (Task 3). `verify-multilib.sh` path consistent across Tasks 2/3/4. ✅
