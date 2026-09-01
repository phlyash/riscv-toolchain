#!/usr/bin/env python3
"""Integration tests for the compiler Beget incoming-bundle builder."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
BUILDER = ROOT / "build" / "prepare-beget-release.py"
NIIET_WORKFLOW = ROOT / ".github" / "workflows" / "niiet-toolchain.yaml"
FILES = {
    "niiet-riscv-toolchain-linux-x86_64.tar.gz": ("linux", "x86_64", "tar.gz"),
    "niiet-riscv-toolchain-linux-x86_64.zip": ("linux", "x86_64", "zip"),
    "niiet-riscv-toolchain-macos-aarch64.tar.gz": ("darwin", "aarch64", "tar.gz"),
    "niiet-riscv-toolchain-macos-aarch64.zip": ("darwin", "aarch64", "zip"),
    "niiet-riscv-toolchain-windows-x86_64.tar.gz": ("windows", "x86_64", "tar.gz"),
    "niiet-riscv-toolchain-windows-x86_64.zip": ("windows", "x86_64", "zip"),
}


class PrepareBegetReleaseTests(unittest.TestCase):
    """Tests for contract-visible bundle output and input rejection."""

    def make_input(self, directory):
        source = Path(directory) / "input"
        source.mkdir()
        for index, name in enumerate(FILES):
            (source / name).write_bytes(("archive-%d\n" % index).encode() * 100)
        return source

    def run_builder(self, source, output, **overrides):
        options = {
            "type": "compiler",
            "tag": "v1.2.3",
            "repository": "phlyash/riscv-toolchain",
            "run_id": "123456-1",
        }
        options.update(overrides)
        return subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--type", options["type"],
                "--tag", options["tag"],
                "--repository", options["repository"],
                "--run-id", options["run_id"],
                "--input", str(source),
                "--output", str(output),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_failure_without_manifest(self, result, output):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((output / "release.json").exists())

    def test_builds_ordered_manifest_and_byte_identical_archives(self):
        """A wrong mapping, hash, key order, or copy breaks the public bundle contract."""
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = Path(temporary) / "output"
            result = self.run_builder(source, output)

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "release.json").read_text())
            self.assertEqual(
                list(manifest),
                ["schema", "type", "version", "repository", "run_id", "files"],
            )
            self.assertEqual(manifest["schema"], 1)
            self.assertEqual(manifest["type"], "compiler")
            self.assertEqual(manifest["version"], "1.2.3")
            self.assertEqual(manifest["repository"], "phlyash/riscv-toolchain")
            self.assertEqual(manifest["run_id"], "123456-1")
            self.assertEqual([entry["name"] for entry in manifest["files"]], list(FILES))
            self.assertEqual(
                [(entry["os"], entry["arch"], entry["archiv"]) for entry in manifest["files"]],
                list(FILES.values()),
            )
            for entry in manifest["files"]:
                self.assertEqual(
                    list(entry), ["name", "os", "arch", "archiv", "sha256"]
                )
                source_bytes = (source / entry["name"]).read_bytes()
                output_bytes = (output / entry["name"]).read_bytes()
                self.assertEqual(output_bytes, source_bytes)
                self.assertEqual(entry["sha256"], hashlib.sha256(output_bytes).hexdigest())
            self.assertEqual(
                sorted(path.name for path in output.iterdir()),
                sorted([*FILES, "release.json"]),
            )

    def test_manifest_hash_describes_archive_copied_before_source_mutation(self):
        """A post-copy source change must not alter the completed bundle checksum."""
        specification = importlib.util.spec_from_file_location(
            "prepare_beget_release", BUILDER
        )
        builder = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(builder)

        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = Path(temporary) / "output"
            name = "niiet-riscv-toolchain-linux-x86_64.tar.gz"
            mutated_contents = b"mutated after archive copy\n"
            real_copyfile = builder.shutil.copyfile

            def copy_then_mutate(copy_source, destination):
                result = real_copyfile(copy_source, destination)
                if Path(copy_source).name == name:
                    Path(copy_source).write_bytes(mutated_contents)
                return result

            arguments = [
                str(BUILDER),
                "--type", "compiler",
                "--tag", "v1.2.3",
                "--repository", "phlyash/riscv-toolchain",
                "--run-id", "123456-1",
                "--input", str(source),
                "--output", str(output),
            ]
            with mock.patch.object(sys, "argv", arguments):
                with mock.patch.object(
                    builder.shutil, "copyfile", side_effect=copy_then_mutate
                ):
                    builder.main()

            manifest = json.loads((output / "release.json").read_text())
            entry = next(entry for entry in manifest["files"] if entry["name"] == name)
            destination_hash = hashlib.sha256((output / name).read_bytes()).hexdigest()
            source_hash = hashlib.sha256((source / name).read_bytes()).hexdigest()
            self.assertEqual(entry["sha256"], destination_hash)
            self.assertNotEqual(entry["sha256"], source_hash)

    def test_rejects_missing_windows_zip(self):
        """A partial release must not create a manifest declaring completion."""
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            (source / "niiet-riscv-toolchain-windows-x86_64.zip").unlink()
            output = Path(temporary) / "output"
            self.assert_failure_without_manifest(self.run_builder(source, output), output)

    def test_rejects_unexpected_seventh_file(self):
        """An unrecognised artifact must not enter the incoming directory."""
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            (source / "unexpected.txt").write_text("unexpected")
            output = Path(temporary) / "output"
            self.assert_failure_without_manifest(self.run_builder(source, output), output)

    def test_rejects_unsafe_tag(self):
        """A path-like version must not become a published catalog version."""
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = Path(temporary) / "output"
            self.assert_failure_without_manifest(
                self.run_builder(source, output, tag="../1.2.3"), output
            )

    def test_rejects_output_inside_input(self):
        """Source and destination overlap must not alter the validated input set."""
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = source / "output"
            self.assert_failure_without_manifest(self.run_builder(source, output), output)

    def test_rejects_unsupported_type(self):
        """The compiler builder must not be usable for another package profile."""
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = Path(temporary) / "output"
            self.assert_failure_without_manifest(
                self.run_builder(source, output, type="openocd"), output
            )

    def test_rejects_safe_but_wrong_repository(self):
        """The forced compiler publisher identity accepts only this repository."""
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = Path(temporary) / "output"
            self.assert_failure_without_manifest(
                self.run_builder(source, output, repository="phlyash/other-toolchain"), output
            )

    def test_manual_release_deploy_job_builds_and_transports_same_run_artifacts(self):
        """A missing or unsafe post-release job must block the compiler publisher."""
        workflow = NIIET_WORKFLOW.read_text()
        marker = "\n  deploy-beget:\n"
        self.assertIn(marker, workflow)
        job = workflow[workflow.index(marker):]

        for required in (
            "name: Publish release to Beget",
            "if: github.event_name == 'workflow_dispatch'",
            "needs: release",
            "runs-on: ubuntu-24.04",
            "uses: actions/checkout@v6",
            "uses: actions/download-artifact@v8",
            "pattern: niiet-riscv-toolchain-*",
            "path: release-assets",
            "merge-multiple: true",
            "python3 build/prepare-beget-release.py",
            "--type compiler",
            '--tag "${{ inputs.release_tag }}"',
            '--repository "$GITHUB_REPOSITORY"',
            '--run-id "$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"',
            "--input release-assets",
            "--output beget-upload",
            "bash build/deploy-beget-release.sh beget-upload",
            "BEGET_HOST: ${{ secrets.BEGET_HOST }}",
            "BEGET_PORT: ${{ secrets.BEGET_PORT }}",
            "BEGET_USER: ${{ secrets.BEGET_USER }}",
            "BEGET_SSH_PRIVATE_KEY: ${{ secrets.BEGET_SSH_PRIVATE_KEY }}",
            "BEGET_KNOWN_HOSTS: ${{ secrets.BEGET_KNOWN_HOSTS }}",
        ):
            self.assertIn(required, job)
        mapped_secrets = [
            line.strip()
            for line in job.splitlines()
            if line.strip().startswith("BEGET_")
        ]
        self.assertEqual(
            mapped_secrets,
            [
                "BEGET_HOST: ${{ secrets.BEGET_HOST }}",
                "BEGET_PORT: ${{ secrets.BEGET_PORT }}",
                "BEGET_USER: ${{ secrets.BEGET_USER }}",
                "BEGET_SSH_PRIVATE_KEY: ${{ secrets.BEGET_SSH_PRIVATE_KEY }}",
                "BEGET_KNOWN_HOSTS: ${{ secrets.BEGET_KNOWN_HOSTS }}",
            ],
        )
        self.assertNotIn("\n    permissions:", job)
        self.assertNotIn("contents: write", job)


if __name__ == "__main__":
    unittest.main()
