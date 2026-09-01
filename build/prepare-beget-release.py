#!/usr/bin/env python3
"""Build the compiler incoming bundle consumed by the restricted publisher."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


REPOSITORY = "phlyash/riscv-toolchain"
VERSION_PATTERN = re.compile(r"^[0-9][A-Za-z0-9._+~-]*$")
FILES = {
    "niiet-riscv-toolchain-linux-x86_64.tar.gz": ("linux", "x86_64", "tar.gz"),
    "niiet-riscv-toolchain-linux-x86_64.zip": ("linux", "x86_64", "zip"),
    "niiet-riscv-toolchain-macos-aarch64.tar.gz": ("darwin", "aarch64", "tar.gz"),
    "niiet-riscv-toolchain-macos-aarch64.zip": ("darwin", "aarch64", "zip"),
    "niiet-riscv-toolchain-windows-x86_64.tar.gz": ("windows", "x86_64", "tar.gz"),
    "niiet-riscv-toolchain-windows-x86_64.zip": ("windows", "x86_64", "zip"),
}
CHUNK_SIZE = 1024 * 1024


def parse_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--type", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def normalize_version(tag):
    version = tag[1:] if tag.startswith("v") else tag
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("invalid release version")
    return version


def paths_overlap(first, second):
    try:
        return os.path.commonpath((first, second)) in (first, second)
    except ValueError:
        return False


def validate_input(source):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("input must be a directory")
    entries = {path.name: path for path in source.iterdir()}
    if set(entries) != set(FILES):
        raise ValueError("input must contain exactly the six compiler archives")
    for name in FILES:
        path = entries[name]
        if path.is_symlink() or not path.is_file():
            raise ValueError("input archive must be a regular non-symlink file: " + name)


def prepare_output(output):
    if output.exists():
        if output.is_symlink() or not output.is_dir():
            raise ValueError("output must be a directory")
        if any(output.iterdir()):
            raise ValueError("output directory must be empty")
    else:
        output.mkdir(parents=True)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as archive:
        while chunk := archive.read(CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def write_manifest(output, manifest):
    descriptor, temporary_name = tempfile.mkstemp(prefix=".release-", dir=output)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary:
            json.dump(manifest, temporary, indent=2)
            temporary.write("\n")
        os.replace(temporary_name, output / "release.json")
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main():
    arguments = parse_arguments()
    if arguments.type != "compiler":
        raise ValueError("type must be compiler")
    if arguments.repository != REPOSITORY:
        raise ValueError("repository must be phlyash/riscv-toolchain")

    version = normalize_version(arguments.tag)
    source = Path(arguments.input).resolve()
    output = Path(arguments.output).resolve()
    if paths_overlap(str(source), str(output)):
        raise ValueError("input and output directories must not overlap")
    validate_input(source)
    prepare_output(output)

    files = []
    for name, (operating_system, architecture, archive_type) in FILES.items():
        source_file = source / name
        destination = output / name
        shutil.copyfile(source_file, destination)
        files.append(
            {
                "name": name,
                "os": operating_system,
                "arch": architecture,
                "archiv": archive_type,
                "sha256": sha256(source_file),
            }
        )
    write_manifest(
        output,
        {
            "schema": 1,
            "type": "compiler",
            "version": version,
            "repository": arguments.repository,
            "run_id": arguments.run_id,
            "files": files,
        },
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
