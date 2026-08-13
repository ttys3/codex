#!/usr/bin/env python3

import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import unittest


UPDATE_SCRIPT = Path(__file__).with_name("downstream-update.sh")
OFFICIAL_API = "https://api.github.com/repos/openai/codex/releases/latest"
DOWNSTREAM_API = "https://api.github.com/repos/ttys3/codex/releases/latest"
RELEASES_BASE = "https://github.com/ttys3/codex/releases/download"


def update_platform() -> str | None:
    system = platform.system()
    machine = platform.machine()
    if system == "Linux" and machine in {"x86_64", "amd64"}:
        return "linux-amd64"
    if system == "Linux" and machine in {"aarch64", "arm64"}:
        return "linux-arm64"
    if system == "Darwin" and machine in {"arm64", "aarch64"}:
        return "macos-arm64"
    return None


PLATFORM = update_platform()


def write_executable(path: Path, version: str, installed_version: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if installed_version is None:
        body = f"#!/bin/sh\nprintf 'codex-cli {version}\\n'\n"
    else:
        body = f"""#!/bin/sh
case "$0" in
  */extract/codex) printf 'codex-cli {version}\\n' ;;
  *) printf 'codex-cli {installed_version}\\n' ;;
esac
"""
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def write_release(
    root: Path,
    tag: str,
    version: str,
    *,
    installed_version: str | None = None,
) -> None:
    assert PLATFORM is not None
    package = root / "package"
    write_executable(package / "codex", version, installed_version)
    if PLATFORM.startswith("linux-"):
        bwrap = package / "codex-resources" / "bwrap"
        bwrap.parent.mkdir(parents=True, exist_ok=True)
        bwrap.write_bytes(b"new downstream bwrap\n")
        bwrap.chmod(0o755)

    asset = f"codex-{tag}-{PLATFORM}.tar.gz"
    release_dir = root / "releases" / tag
    release_dir.mkdir(parents=True, exist_ok=True)
    archive = release_dir / asset
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(package / "codex", arcname="codex")
        if PLATFORM.startswith("linux-"):
            tar.add(package / "codex-resources", arcname="codex-resources")

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (release_dir / f"{asset}.sha256").write_text(
        f"{digest}  {asset}\n", encoding="utf-8"
    )
    (root / "downstream.json").write_text(
        json.dumps({"tag_name": tag}), encoding="utf-8"
    )


def write_official_release(root: Path, version: str) -> None:
    (root / "official.json").write_text(
        json.dumps({"tag_name": f"rust-v{version}"}), encoding="utf-8"
    )


def write_fake_curl(root: Path) -> Path:
    fake_bin = root / "fake-bin"
    fake_bin.mkdir(exist_ok=True)
    curl = fake_bin / "curl"
    curl.write_text(
        f"""#!/usr/bin/env python3
import os
from pathlib import Path
import sys

root = Path(os.environ["CODEX_TEST_FIXTURE_ROOT"])
output = None
url = None
args = sys.argv[1:]
i = 0
while i < len(args):
    arg = args[i]
    if arg == "-o":
        i += 1
        output = args[i]
    elif not arg.startswith("-"):
        url = arg
    i += 1

if url is None:
    print("fake curl did not receive a URL", file=sys.stderr)
    sys.exit(2)
with (root / "requests.log").open("a", encoding="utf-8") as log:
    log.write(url + "\\n")

if url == "{OFFICIAL_API}":
    source = root / "official.json"
elif url == "{DOWNSTREAM_API}":
    source = root / "downstream.json"
elif url.startswith("{RELEASES_BASE}/"):
    source = root / "releases" / url.removeprefix("{RELEASES_BASE}/")
else:
    print("unexpected URL: " + url, file=sys.stderr)
    sys.exit(22)

try:
    data = source.read_bytes()
except OSError as error:
    print(error, file=sys.stderr)
    sys.exit(22)
if output is None:
    sys.stdout.buffer.write(data)
else:
    Path(output).write_bytes(data)
""",
        encoding="utf-8",
    )
    curl.chmod(0o755)
    return fake_bin


def requests_made(root: Path) -> list[str]:
    log = root / "requests.log"
    return log.read_text(encoding="utf-8").splitlines() if log.exists() else []


def run_updater(
    root: Path,
    current_exe: Path,
    current_version: str,
    current_tag: str | None,
) -> subprocess.CompletedProcess[str]:
    temp_dir = root / "tmp"
    temp_dir.mkdir(exist_ok=True)
    fake_bin = write_fake_curl(root)
    env = os.environ.copy()
    env.update(
        {
            "CODEX_CURRENT_EXE": str(current_exe),
            "CODEX_CURRENT_VERSION": current_version,
            "CODEX_OFFICIAL_LATEST_API": "https://invalid.example/official",
            "CODEX_DOWNSTREAM_LATEST_API": "https://invalid.example/downstream",
            "CODEX_DOWNSTREAM_RELEASES_BASE": "https://invalid.example/releases",
            "CODEX_TEST_FIXTURE_ROOT": str(root),
            "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
            "TMPDIR": str(temp_dir),
        }
    )
    if current_tag is not None:
        env["CODEX_CURRENT_DOWNSTREAM_TAG"] = current_tag
    else:
        env.pop("CODEX_CURRENT_DOWNSTREAM_TAG", None)
    return subprocess.run(
        ["/bin/sh", str(UPDATE_SCRIPT)],
        check=False,
        capture_output=True,
        env=env,
        text=True,
    )


@unittest.skipIf(PLATFORM is None, "downstream updater does not support this platform")
class DownstreamUpdateShTest(unittest.TestCase):
    def test_official_upgrade_downloads_matching_downstream_release(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.146.0")
            write_official_release(root, "0.147.0")
            write_release(root, "statusline-v0.147.0-r1", "0.147.0")

            result = run_updater(
                root, current, "0.146.0", "statusline-v0.146.0-r4"
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                subprocess.check_output([current, "--version"], text=True),
                "codex-cli 0.147.0\n",
            )
            asset = f"codex-statusline-v0.147.0-r1-{PLATFORM}.tar.gz"
            self.assertEqual(
                requests_made(root),
                [
                    OFFICIAL_API,
                    DOWNSTREAM_API,
                    f"{RELEASES_BASE}/statusline-v0.147.0-r1/{asset}",
                    f"{RELEASES_BASE}/statusline-v0.147.0-r1/{asset}.sha256",
                ],
            )
            if PLATFORM and PLATFORM.startswith("linux-"):
                self.assertEqual(
                    (root / "install" / "codex-resources" / "bwrap").read_bytes(),
                    b"new downstream bwrap\n",
                )

    def test_newer_downstream_revision_updates_same_official_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.147.0")
            write_official_release(root, "0.147.0")
            write_release(root, "statusline-v0.147.0-r2", "0.147.0")

            result = run_updater(
                root, current, "0.147.0", "statusline-v0.147.0-r1"
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("statusline-v0.147.0-r2", result.stdout)

    def test_current_revision_returns_up_to_date_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.147.0")
            original = current.read_bytes()
            write_official_release(root, "0.147.0")
            write_release(root, "statusline-v0.147.0-r2", "0.147.0")

            result = run_updater(
                root, current, "0.147.0", "statusline-v0.147.0-r2"
            )

            self.assertEqual(result.returncode, 10, result.stderr)
            self.assertEqual(current.read_bytes(), original)
            self.assertIn("already up to date", result.stdout)

    def test_newer_local_version_does_not_query_downstream(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.148.0")
            write_official_release(root, "0.147.0")

            result = run_updater(root, current, "0.148.0", None)

            self.assertEqual(result.returncode, 10, result.stderr)
            self.assertIn("newer than the official latest", result.stdout)
            self.assertEqual(requests_made(root), [OFFICIAL_API])

    def test_missing_downstream_build_keeps_current_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.146.0")
            original = current.read_bytes()
            write_official_release(root, "0.147.0")
            write_release(root, "statusline-v0.146.0-r9", "0.146.0")

            result = run_updater(
                root, current, "0.146.0", "statusline-v0.146.0-r4"
            )

            self.assertEqual(result.returncode, 1)
            self.assertEqual(current.read_bytes(), original)
            self.assertIn("is not available yet", result.stderr)

    def test_failed_post_install_validation_rolls_back_binary_and_bwrap(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.146.0")
            original = current.read_bytes()
            old_bwrap = root / "install" / "codex-resources" / "bwrap"
            old_bwrap.parent.mkdir(parents=True)
            old_bwrap.write_bytes(b"old bwrap\n")
            old_bwrap.chmod(0o755)
            write_official_release(root, "0.147.0")
            write_release(
                root,
                "statusline-v0.147.0-r1",
                "0.147.0",
                installed_version="9.9.9",
            )

            result = run_updater(
                root, current, "0.146.0", "statusline-v0.146.0-r4"
            )

            self.assertEqual(result.returncode, 1)
            self.assertEqual(current.read_bytes(), original)
            if PLATFORM and PLATFORM.startswith("linux-"):
                self.assertEqual(old_bwrap.read_bytes(), b"old bwrap\n")
            self.assertIn("installed binary validation failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
