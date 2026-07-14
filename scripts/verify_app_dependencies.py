#!/usr/bin/env python3
"""Fail when a macOS app executable references an unbundled dynamic library."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


SYSTEM_PREFIXES = (
    "/System/Library/",
    "/usr/lib/",
    "/Library/Apple/System/Library/",
)


def _run_otool(otool: str, flag: str, executable: Path) -> str:
    return subprocess.run(
        [otool, flag, str(executable)],
        check=True,
        text=True,
        capture_output=True,
    ).stdout


def _dependencies(output: str) -> list[str]:
    dependencies: list[str] = []
    for line in output.splitlines()[1:]:
        stripped = line.strip()
        if stripped:
            dependencies.append(stripped.split(" (", 1)[0])
    return dependencies


def _rpaths(output: str) -> list[str]:
    lines = output.splitlines()
    paths: list[str] = []
    for index, line in enumerate(lines):
        if "cmd LC_RPATH" not in line:
            continue
        for candidate in lines[index + 1 : index + 5]:
            stripped = candidate.strip()
            if stripped.startswith("path "):
                paths.append(stripped.removeprefix("path ").split(" (offset", 1)[0])
                break
    return paths


def _expand(path: str, executable: Path) -> Path:
    executable_dir = executable.parent
    return Path(
        path.replace("@executable_path", str(executable_dir)).replace(
            "@loader_path", str(executable_dir)
        )
    ).resolve()


def _dependency_exists(
    dependency: str, executable: Path, contents: Path, rpaths: list[str]
) -> bool:
    if dependency.startswith(SYSTEM_PREFIXES):
        return True
    if dependency.startswith("@executable_path/") or dependency.startswith(
        "@loader_path/"
    ):
        return _expand(dependency, executable).is_file()
    if dependency.startswith("@rpath/"):
        suffix = dependency.removeprefix("@rpath/")
        candidates = [
            _expand(rpath, executable) / suffix for rpath in rpaths
        ] + [
            contents / "Frameworks" / suffix,
            contents / "MacOS" / suffix,
        ]
        return any(candidate.is_file() for candidate in candidates)
    return False


def verify(contents: Path, executable: Path, otool: str) -> list[str]:
    dependencies = _dependencies(_run_otool(otool, "-L", executable))
    rpaths = _rpaths(_run_otool(otool, "-l", executable))
    return [
        dependency
        for dependency in dependencies
        if not _dependency_exists(dependency, executable, contents, rpaths)
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contents", required=True, type=Path)
    parser.add_argument("--executable", required=True, type=Path)
    args = parser.parse_args()

    missing = verify(
        args.contents.resolve(),
        args.executable.resolve(),
        os.environ.get("OTOOL", "otool"),
    )
    if missing:
        for dependency in missing:
            print(
                f"error: dynamic dependency not bundled: {dependency}",
                file=sys.stderr,
            )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
