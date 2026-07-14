import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
VERIFIER = REPO_ROOT / "scripts" / "verify_app_dependencies.py"
BUILD_SCRIPT = REPO_ROOT / "build-app.sh"


def _fake_otool(tmp_path: Path) -> Path:
    script = tmp_path / "fake-otool"
    script.write_text(
        """#!/bin/sh
if [ "$1" = "-L" ]; then
    printf '%s:\\n' "$2"
    printf '\\t@rpath/libMatrixRustSDK.dylib (compatibility version 0.0.0, current version 0.0.0)\\n'
    printf '\\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)\\n'
    exit 0
fi
if [ "$1" = "-l" ]; then
    cat <<'EOF'
Load command 1
          cmd LC_RPATH
      cmdsize 48
         path @executable_path/../Frameworks (offset 12)
EOF
    exit 0
fi
exit 2
"""
    )
    script.chmod(0o755)
    return script


def test_rejects_unbundled_rpath_dependency(tmp_path: Path) -> None:
    contents = tmp_path / "Example.app" / "Contents"
    executable = contents / "MacOS" / "Example"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"fixture")

    result = subprocess.run(
        [
            sys.executable,
            str(VERIFIER),
            "--contents",
            str(contents),
            "--executable",
            str(executable),
        ],
        env={**os.environ, "OTOOL": str(_fake_otool(tmp_path))},
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 1
    assert "@rpath/libMatrixRustSDK.dylib" in result.stderr
    assert "not bundled" in result.stderr


def test_accepts_rpath_dependency_in_app_frameworks(tmp_path: Path) -> None:
    contents = tmp_path / "Example.app" / "Contents"
    executable = contents / "MacOS" / "Example"
    dependency = contents / "Frameworks" / "libMatrixRustSDK.dylib"
    executable.parent.mkdir(parents=True)
    dependency.parent.mkdir(parents=True)
    executable.write_bytes(b"fixture")
    dependency.write_bytes(b"fixture")

    result = subprocess.run(
        [
            sys.executable,
            str(VERIFIER),
            "--contents",
            str(contents),
            "--executable",
            str(executable),
        ],
        env={**os.environ, "OTOOL": str(_fake_otool(tmp_path))},
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr


def test_build_script_verifies_dependencies_before_signing() -> None:
    script = BUILD_SCRIPT.read_text()
    verification = "scripts/verify_app_dependencies.py"

    assert verification in script
    assert script.index(verification) < script.index('echo "▶ Signing..."')
