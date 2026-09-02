#!/usr/bin/env python3
"""Contract tests for the NIIET Windows LLVM build and native smoke gate."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "niiet-toolchain.yaml"
SMOKE_PATH = ROOT / "build" / "test-windows-clang.ps1"


def job(workflow, name):
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        workflow,
    )
    if match is None:
        raise AssertionError(f"workflow job is missing: {name}")
    return match.group(0)


def assert_source_cache_directory_precedes_restore(test_case, workflow, job_name):
    build_job = job(workflow, job_name)
    prepare = "      - name: Prepare source cache directory\n"
    restore = "      - name: Cache patched GNU sources\n"

    test_case.assertIn(prepare, build_job)
    test_case.assertLess(build_job.index(prepare), build_job.index(restore))
    prepare_block = build_job[build_job.index(prepare) : build_job.index(restore)]
    test_case.assertIn("sudo mkdir -p /mnt/sources", prepare_block)
    test_case.assertIn('sudo chown "$USER" /mnt/sources', prepare_block)


def assert_workflow_contract(test_case, workflow):
    assert_source_cache_directory_precedes_restore(
        test_case, workflow, "linux-x86_64"
    )
    assert_source_cache_directory_precedes_restore(
        test_case, workflow, "windows-x86_64"
    )

    windows_build = job(workflow, "windows-x86_64")
    test_case.assertIn("- name: Prepare pinned llvm-mingw", windows_build)
    test_case.assertIn("id: llvm_mingw", windows_build)
    test_case.assertIn(
        'root="$(WORK=/mnt/work bash build/prepare-llvm-mingw.sh)"',
        windows_build,
    )
    test_case.assertIn('echo "root=$root" >> "$GITHUB_OUTPUT"', windows_build)
    test_case.assertRegex(
        windows_build,
        r"(?m)^      - name: Build upstream LLVM \+ Clang Canadian-cross\n"
        r"        env:\n"
        r"          LLVM_MINGW_ROOT: \$\{\{ steps\.llvm_mingw\.outputs\.root \}\}\n"
        r"        run: \|$",
    )

    smoke = job(workflow, "windows-clang-smoke")
    test_case.assertIn("needs: windows-x86_64", smoke)
    test_case.assertIn("runs-on: windows-2022", smoke)
    test_case.assertIn("uses: actions/download-artifact@v8", smoke)
    test_case.assertIn("name: niiet-riscv-toolchain-windows-x86_64.zip", smoke)
    test_case.assertIn("path: smoke-artifact", smoke)
    test_case.assertIn(
        "./build/test-windows-clang.ps1 `", smoke
    )
    test_case.assertIn(
        "-Archive smoke-artifact/niiet-riscv-toolchain-windows-x86_64.zip",
        smoke,
    )

    release = job(workflow, "release")
    needs_match = re.search(r"(?ms)^    needs:\n(?P<needs>(?:      - .+\n)+)", release)
    test_case.assertIsNotNone(needs_match, "release needs list is missing")
    test_case.assertIn("      - windows-clang-smoke\n", needs_match.group("needs"))


class NiietToolchainWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_windows_build_uses_bootstrap_and_release_waits_for_native_smoke(self):
        assert_workflow_contract(self, self.workflow)

    def test_contract_rejects_ungated_release(self):
        mutated = self.workflow.replace("      - windows-clang-smoke\n", "", 1)
        with self.assertRaises(AssertionError):
            assert_workflow_contract(self, mutated)

    def test_contract_rejects_unscoped_llvm_mingw_root(self):
        mutated = self.workflow.replace(
            "          LLVM_MINGW_ROOT: ${{ steps.llvm_mingw.outputs.root }}\n",
            "",
            1,
        )
        with self.assertRaises(AssertionError):
            assert_workflow_contract(self, mutated)

    def test_contract_rejects_cache_restore_before_directory_creation(self):
        mutated = self.workflow.replace(
            "      - name: Prepare source cache directory\n",
            "      - name: Late source cache directory preparation\n",
            1,
        )
        with self.assertRaises(AssertionError):
            assert_workflow_contract(self, mutated)

    def test_native_smoke_exercises_optimizer_gcc_runtime_and_gdb_xml(self):
        smoke = SMOKE_PATH.read_text(encoding="utf-8")
        for required in (
            "-Og",
            "--target=riscv32-unknown-elf",
            "--gcc-toolchain=$toolchainRoot",
            "--sysroot=$sysroot",
            "--rtlib=libgcc",
            "volatile uint64_t",
            "riscv32-unknown-elf-gdb.exe",
            "set tdesc filename",
            "XML support was disabled at compile time",
            "riscv32-unknown-elf-readelf.exe",
            "Machine:\\s+RISC-V",
        ):
            self.assertIn(required, smoke)
        self.assertNotIn('"-O0"', smoke)
        self.assertNotIn('"-mllvm"', smoke)
        self.assertNotIn('"-loop-deletion', smoke)


if __name__ == "__main__":
    unittest.main()
