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
directory.mkdir()
archive = directory / "zig.tar.xz"
with urllib.request.urlopen(item["tarball"], timeout=180) as response:
    data = response.read(int(item["size"]) + 1)
if len(data) != int(item["size"]) or hashlib.sha256(data).hexdigest() != item["shasum"]:
    raise SystemExit("Zig archive size/checksum mismatch")
archive.write_bytes(data)
with tarfile.open(archive) as package:
    package.extractall(directory, filter="data")
compiler, = directory.glob("*/zig")
if subprocess.check_output([str(compiler), "version"], text=True, timeout=10).strip() != version:
    raise SystemExit("Compiler executable version mismatch")
with open(os.environ["GITHUB_PATH"], "a") as output:
    output.write(str(compiler.parent) + "\n")
