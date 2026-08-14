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


def update_platform() -> tuple[str, str] | None:
    system = platform.system()
    machine = platform.machine()
    if system == "Linux" and machine in {"x86_64", "amd64"}:
        return "linux-amd64", "x86_64-unknown-linux-musl"
    if system == "Linux" and machine in {"aarch64", "arm64"}:
        return "linux-arm64", "aarch64-unknown-linux-musl"
    if system == "Darwin" and machine in {"arm64", "aarch64"}:
        return "macos-arm64", "aarch64-apple-darwin"
    return None


PLATFORM_AND_TARGET = update_platform()
PLATFORM = PLATFORM_AND_TARGET[0] if PLATFORM_AND_TARGET else None
TARGET = PLATFORM_AND_TARGET[1] if PLATFORM_AND_TARGET else None


def write_executable(
    path: Path, version: str, installed_version: str | None = None
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if installed_version is None:
        body = f"#!/bin/sh\nprintf 'codex-cli {version}\\n'\n"
    else:
        body = f"""#!/bin/sh
case "$0" in
  */install/codex) printf 'codex-cli {installed_version}\\n' ;;
  *) printf 'codex-cli {version}\\n' ;;
esac
"""
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def write_helper(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    path.chmod(0o755)


def write_package(
    package: Path,
    version: str,
    *,
    installed_version: str | None = None,
    include_host: bool = True,
) -> None:
    assert TARGET is not None
    write_executable(package / "bin" / "codex", version, installed_version)
    if include_host:
        write_helper(
            package / "bin" / "codex-code-mode-host",
            b"#!/bin/sh\nexit 0\n",
        )
    write_helper(package / "codex-path" / "rg", b"#!/bin/sh\nexit 0\n")
    write_helper(
        package / "codex-resources" / "zsh" / "bin" / "zsh",
        b"#!/bin/sh\nexit 0\n",
    )
    if TARGET.endswith("linux-musl"):
        write_helper(
            package / "codex-resources" / "bwrap",
            b"new downstream bwrap\n",
        )

    (package / "codex-package.json").write_text(
        json.dumps(
            {
                "layoutVersion": 1,
                "version": version,
                "target": TARGET,
                "variant": "codex",
                "entrypoint": "bin/codex",
                "resourcesDir": "codex-resources",
                "pathDir": "codex-path",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (package / "codex").symlink_to("bin/codex")
    (package / "codex-code-mode-host").symlink_to("bin/codex-code-mode-host")


def write_release(
    root: Path,
    tag: str,
    version: str,
    *,
    installed_version: str | None = None,
    include_host: bool = True,
) -> None:
    assert PLATFORM is not None
    package = root / "package"
    write_package(
        package,
        version,
        installed_version=installed_version,
        include_host=include_host,
    )

    asset = f"codex-{tag}-{PLATFORM}.tar.gz"
    release_dir = root / "releases" / tag
    release_dir.mkdir(parents=True, exist_ok=True)
    archive = release_dir / asset
    with tarfile.open(archive, "w:gz") as tar:
        for child in package.iterdir():
            tar.add(child, arcname=child.name)

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
    install_dir = root / "install"
    install_dir.mkdir(exist_ok=True)
    fake_bin = write_fake_curl(root)
    env = os.environ.copy()
    env.update(
        {
            "CODEX_CURRENT_EXE": str(current_exe),
            "CODEX_CURRENT_VERSION": current_version,
            "CODEX_HOME": str(root / "codex-home"),
            "CODEX_INSTALL_DIR": str(install_dir),
            "CODEX_OFFICIAL_LATEST_API": "https://invalid.example/official",
            "CODEX_DOWNSTREAM_LATEST_API": "https://invalid.example/downstream",
            "CODEX_DOWNSTREAM_RELEASES_BASE": "https://invalid.example/releases",
            "CODEX_TEST_FIXTURE_ROOT": str(root),
            "HOME": str(root / "home"),
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


def assert_complete_install(
    testcase: unittest.TestCase,
    root: Path,
    current: Path,
    version: str,
) -> Path:
    assert TARGET is not None
    testcase.assertTrue(current.is_symlink())
    package = current.resolve().parent.parent
    testcase.assertEqual(
        package.parent,
        root / "codex-home" / "packages" / "standalone" / "releases",
    )
    testcase.assertEqual(
        subprocess.check_output([current, "--version"], text=True),
        f"codex-cli {version}\n",
    )
    testcase.assertTrue((package / "bin" / "codex-code-mode-host").is_file())
    testcase.assertTrue((package / "codex-path" / "rg").is_file())
    testcase.assertTrue((package / "codex-resources" / "zsh" / "bin" / "zsh").is_file())
    if TARGET.endswith("linux-musl"):
        testcase.assertEqual(
            (package / "codex-resources" / "bwrap").read_bytes(),
            b"new downstream bwrap\n",
        )
    visible_host = current.parent / "codex-code-mode-host"
    testcase.assertTrue(visible_host.is_symlink())
    testcase.assertEqual(
        visible_host.resolve(), package / "bin" / "codex-code-mode-host"
    )
    return package


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
            assert_complete_install(self, root, current, "0.147.0")
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
            assert_complete_install(self, root, current, "0.147.0")

    def test_same_revision_repairs_incomplete_flat_install(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.147.0")
            write_official_release(root, "0.147.0")
            write_release(root, "statusline-v0.147.0-r2", "0.147.0")

            result = run_updater(
                root, current, "0.147.0", "statusline-v0.147.0-r2"
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Repaired downstream Codex package", result.stdout)
            assert_complete_install(self, root, current, "0.147.0")

    def test_complete_current_revision_returns_up_to_date_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.147.0")
            write_official_release(root, "0.147.0")
            write_release(root, "statusline-v0.147.0-r2", "0.147.0")
            first_result = run_updater(
                root, current, "0.147.0", "statusline-v0.147.0-r2"
            )
            self.assertEqual(first_result.returncode, 0, first_result.stderr)
            package = assert_complete_install(self, root, current, "0.147.0")
            (root / "requests.log").unlink()
            original = (package / "bin" / "codex").read_bytes()

            result = run_updater(
                root, current.resolve(), "0.147.0", "statusline-v0.147.0-r2"
            )

            self.assertEqual(result.returncode, 10, result.stderr)
            self.assertEqual((package / "bin" / "codex").read_bytes(), original)
            self.assertIn("already up to date", result.stdout)
            self.assertEqual(requests_made(root), [OFFICIAL_API, DOWNSTREAM_API])

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

    def test_missing_code_mode_host_keeps_current_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            write_executable(current, "0.146.0")
            original = current.read_bytes()
            write_official_release(root, "0.147.0")
            write_release(
                root,
                "statusline-v0.147.0-r1",
                "0.147.0",
                include_host=False,
            )

            result = run_updater(
                root, current, "0.146.0", "statusline-v0.146.0-r4"
            )

            self.assertEqual(result.returncode, 1)
            self.assertEqual(current.read_bytes(), original)
            self.assertIn("not a complete Codex package", result.stderr)

    def test_failed_post_install_validation_rolls_back_visible_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            current = root / "install" / "codex"
            visible_host = root / "install" / "codex-code-mode-host"
            write_executable(current, "0.146.0")
            write_helper(visible_host, b"old host\n")
            original = current.read_bytes()
            original_host = visible_host.read_bytes()
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
            self.assertFalse(current.is_symlink())
            self.assertEqual(current.read_bytes(), original)
            self.assertFalse(visible_host.is_symlink())
            self.assertEqual(visible_host.read_bytes(), original_host)
            self.assertFalse(
                (root / "codex-home" / "packages" / "standalone" / "current").exists()
            )
            self.assertIn("installed binary validation failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
