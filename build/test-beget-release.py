#!/usr/bin/env python3
"""Integration tests for the compiler Beget incoming-bundle builder."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
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

EXPECTED_DEPLOY_BEGET_JOB = """  deploy-beget:
    name: Publish release to Beget
    if: github.event_name == 'workflow_dispatch'
    needs: release
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6

      - name: Download release artifacts
        uses: actions/download-artifact@v8
        with:
          pattern: niiet-riscv-toolchain-*
          path: release-assets
          merge-multiple: true

      - name: Prepare Beget bundle
        env:
          RELEASE_TAG: ${{ inputs.release_tag }}
        run: >-
          python3 build/prepare-beget-release.py
          --type compiler
          --tag "$RELEASE_TAG"
          --repository "$GITHUB_REPOSITORY"
          --run-id "$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
          --input release-assets
          --output beget-upload

      - name: Upload and publish on Beget
        env:
          BEGET_HOST: ${{ secrets.BEGET_HOST }}
          BEGET_PORT: ${{ secrets.BEGET_PORT }}
          BEGET_USER: ${{ secrets.BEGET_USER }}
          BEGET_SSH_PRIVATE_KEY: ${{ secrets.BEGET_SSH_PRIVATE_KEY }}
          BEGET_KNOWN_HOSTS: ${{ secrets.BEGET_KNOWN_HOSTS }}
        run: bash build/deploy-beget-release.sh beget-upload
"""


def assert_deploy_beget_contract(test_case, workflow):
    """Assert the deploy job carries the compiler release publishing contract."""
    job_match = re.search(
        r"(?ms)^  deploy-beget:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)", workflow
    )
    test_case.assertIsNotNone(job_match, "deploy-beget job is missing")
    test_case.assertEqual(job_match.group(0), EXPECTED_DEPLOY_BEGET_JOB)


def replace_in_deploy_beget_job(workflow, old, new):
    """Return a workflow fixture with one deploy-beget job fragment replaced."""
    marker = "\n  deploy-beget:\n"
    before_job, job = workflow.split(marker, 1)
    return before_job + marker + job.replace(old, new, 1)


def expected_summary(manifest):
    """Return the sanitized manifest-derived log lines required on success."""
    return [
        "Prepared bundle: type=%s version=%s" % (manifest["type"], manifest["version"]),
        *[
            "profile=%s/%s/%s sha256=%s"
            % (entry["os"], entry["arch"], entry["archiv"], entry["sha256"])
            for entry in manifest["files"]
        ],
    ]


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
            self.assertEqual(result.stdout.splitlines(), expected_summary(manifest))

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

    def test_manifest_replaces_its_own_temporary_file_only_after_serialization(self):
        """A manifest must atomically replace release.json from an output-local temp file."""
        specification = importlib.util.spec_from_file_location(
            "prepare_beget_release", BUILDER
        )
        builder = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(builder)

        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = Path(temporary) / "output"
            real_replace = builder.os.replace
            replacements = []

            def observe_replace(source_path, destination_path):
                replacements.append((Path(source_path), Path(destination_path)))
                return real_replace(source_path, destination_path)

            arguments = [
                str(BUILDER), "--type", "compiler", "--tag", "v1.2.3",
                "--repository", "phlyash/riscv-toolchain", "--run-id", "123456-1",
                "--input", str(source), "--output", str(output),
            ]
            with mock.patch.object(sys, "argv", arguments):
                with mock.patch.object(builder.os, "replace", side_effect=observe_replace):
                    builder.main()

            self.assertEqual(len(replacements), 1)
            temporary_path, destination_path = replacements[0]
            self.assertEqual(temporary_path.parent, output)
            self.assertTrue(temporary_path.name.startswith(".release-"))
            self.assertEqual(destination_path, output / "release.json")
            self.assertFalse(temporary_path.exists())

    def test_serialization_failure_leaves_no_manifest_or_temporary_file(self):
        """A partially written manifest temp file must be removed when JSON output fails."""
        specification = importlib.util.spec_from_file_location(
            "prepare_beget_release", BUILDER
        )
        builder = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(builder)

        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = Path(temporary) / "output"

            def write_partial_json_then_fail(_manifest, stream, **_kwargs):
                stream.write("{")
                raise OSError("simulated JSON serialization failure")

            arguments = [
                str(BUILDER), "--type", "compiler", "--tag", "v1.2.3",
                "--repository", "phlyash/riscv-toolchain", "--run-id", "123456-1",
                "--input", str(source), "--output", str(output),
            ]
            with mock.patch.object(sys, "argv", arguments):
                with mock.patch.object(builder.json, "dump", side_effect=write_partial_json_then_fail):
                    with self.assertRaisesRegex(OSError, "simulated JSON serialization failure"):
                        builder.main()

            self.assertFalse((output / "release.json").exists())
            self.assertEqual(list(output.glob(".release-*")), [])

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
        assert_deploy_beget_contract(self, NIIET_WORKFLOW.read_text())

    def test_deploy_contract_rejects_direct_release_tag_shell_interpolation(self):
        """A manual tag must enter the shell only through the exact step environment."""
        workflow = replace_in_deploy_beget_job(
            NIIET_WORKFLOW.read_text(),
            '        env:\n          RELEASE_TAG: ${{ inputs.release_tag }}\n',
            '',
        )
        workflow = replace_in_deploy_beget_job(
            workflow,
            '--tag "$RELEASE_TAG"',
            '--tag "${{ inputs.release_tag }}"',
        )
        with self.assertRaises(AssertionError):
            assert_deploy_beget_contract(self, workflow)

    def test_deploy_contract_rejects_unquoted_release_tag_shell_variable(self):
        """An unquoted tag variable would allow shell word splitting before validation."""
        workflow = replace_in_deploy_beget_job(
            NIIET_WORKFLOW.read_text(),
            '--tag "$RELEASE_TAG"',
            '--tag $RELEASE_TAG',
        )
        with self.assertRaises(AssertionError):
            assert_deploy_beget_contract(self, workflow)

    def test_safe_workflow_shell_shape_rejects_malicious_tag_without_marker(self):
        """A quote/$() tag is one rejected builder argument and cannot execute shell code."""
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_input(temporary)
            output = Path(temporary) / "output"
            marker = Path(temporary) / "shell-marker"
            executable_directory = Path(temporary) / "bin"
            executable_directory.mkdir()
            argument_capture = Path(temporary) / "python-arguments"
            python_wrapper = executable_directory / "python3"
            python_wrapper.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$@\" >\"$ARGUMENT_CAPTURE\"\n"
                "exec \"$REAL_PYTHON\" \"$@\"\n"
            )
            python_wrapper.chmod(0o700)
            malicious_tag = 'v1.2.3"; touch "$MARKER"; $(touch "$MARKER"); #'
            environment = {
                **os.environ,
                "RELEASE_TAG": malicious_tag,
                "MARKER": str(marker),
                "INPUT": str(source),
                "OUTPUT": str(output),
                "ARGUMENT_CAPTURE": str(argument_capture),
                "REAL_PYTHON": sys.executable,
                "PATH": str(executable_directory) + os.pathsep + os.environ["PATH"],
            }
            command = '''python3 build/prepare-beget-release.py \\
  --type compiler \\
  --tag "$RELEASE_TAG" \\
  --repository "$GITHUB_REPOSITORY" \\
  --run-id "$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" \\
  --input "$INPUT" \\
  --output "$OUTPUT"'''
            result = subprocess.run(
                ["bash", "-c", command],
                cwd=ROOT,
                env={
                    **environment,
                    "GITHUB_REPOSITORY": "phlyash/riscv-toolchain",
                    "GITHUB_RUN_ID": "123456",
                    "GITHUB_RUN_ATTEMPT": "1",
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(argument_capture.exists(), result.stdout + result.stderr)
            arguments = argument_capture.read_text().splitlines()
            self.assertEqual(arguments[arguments.index("--tag") + 1], malicious_tag)
            self.assertEqual(arguments.count(malicious_tag), 1)
            self.assertFalse(marker.exists())
            self.assertFalse((output / "release.json").exists())
            self.assertNotIn(malicious_tag, result.stdout + result.stderr)

    def test_deploy_contract_rejects_commented_job_if(self):
        """Commenting manual-only gating must not be accepted as an active job field."""
        workflow = replace_in_deploy_beget_job(
            NIIET_WORKFLOW.read_text(),
            "    if: github.event_name == 'workflow_dispatch'\n",
            "    # if: github.event_name == 'workflow_dispatch'\n",
        )
        with self.assertRaises(AssertionError):
            assert_deploy_beget_contract(self, workflow)

    def test_deploy_contract_rejects_commented_job_needs(self):
        """Commenting the release dependency must not be accepted as an active field."""
        workflow = replace_in_deploy_beget_job(
            NIIET_WORKFLOW.read_text(),
            "    needs: release\n",
            "    # needs: release\n",
        )
        with self.assertRaises(AssertionError):
            assert_deploy_beget_contract(self, workflow)

    def test_deploy_contract_rejects_action_only_mentioned_in_shell_text(self):
        """An action name in a shell command must not substitute for an action step."""
        workflow = replace_in_deploy_beget_job(
            NIIET_WORKFLOW.read_text(),
            "        uses: actions/download-artifact@v8\n",
            "        run: echo 'uses: actions/download-artifact@v8'\n",
        )
        with self.assertRaises(AssertionError):
            assert_deploy_beget_contract(self, workflow)


if __name__ == "__main__":
    unittest.main()
