"""Install the exact official Linux/macOS compiler from checked archive metadata."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from release import package_versions


def read_verified_archive(stream, item):
    """Bound every read and accept only the checked-in size and SHA256."""
    size = int(item["size"])
    if size <= 0:
        raise ValueError("Invalid Zig archive size")
    data = stream.read(size + 1)
    if len(data) != size or hashlib.sha256(data).hexdigest() != item["shasum"]:
        raise ValueError("Zig archive size/checksum mismatch")
    return data


def download_archive(archive, item):
    """Replace an archive only after its complete download has been verified."""
    with urllib.request.urlopen(item["tarball"], timeout=180) as response:
        data = read_verified_archive(response, item)
    archive.write_bytes(data)


def ensure_archive(archive, item):
    # Cache only the official archive, never trust a cached compiler executable.
    # Recheck its checked-in size and SHA256 before extraction on every runner.
    if archive.is_file() and archive.stat().st_size == int(item["size"]):
        with archive.open("rb") as cached:
            try:
                read_verified_archive(cached, item)
            except ValueError:
                pass
            else:
                return
    download_archive(archive, item)


def main():
    version = package_versions()[1]
    metadata = json.loads((ROOT / ".github/zig-release.json").read_text())
    if version != "0.17.0" or metadata["version"] != version:
        raise SystemExit("Expected exact Zig 0.17.0 and matching archive metadata")
    system = {"Linux": "linux", "Darwin": "macos"}.get(platform.system())
    if system is None:
        raise SystemExit("Compiler CI supports native Linux/macOS hosts")
    arch = {"x86_64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}[platform.machine()]
    item = metadata["artifacts"][arch + "-" + system]
    expected_url = f"https://ziglang.org/download/{version}/zig-{arch}-{system}-{version}.tar.xz"
    if item["tarball"] != expected_url:
        raise SystemExit("Expected official exact-release archive URL")
    directory = Path(os.environ["RUNNER_TEMP"]) / "omagma-zig"
    directory.mkdir(exist_ok=True)
    archive = Path(os.environ["RUNNER_TOOL_CACHE"]) / "omagma-zig" / (arch + "-" + system + "-" + version + ".tar.xz")
    archive.parent.mkdir(parents=True, exist_ok=True)
    try:
        ensure_archive(archive, item)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    with tarfile.open(archive) as package:
        package.extractall(directory, filter="data")
    compiler, = directory.glob("*/zig")
    if subprocess.check_output([str(compiler), "version"], text=True, timeout=10).strip() != version:
        raise SystemExit("Compiler executable version mismatch")
    with open(os.environ["GITHUB_PATH"], "a") as output:
        output.write(str(compiler.parent) + "\n")


if __name__ == "__main__":
    main()
