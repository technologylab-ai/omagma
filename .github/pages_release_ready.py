#!/usr/bin/env python3
"""Gate version-bump docs until their installable assets exist; no waiting loop."""
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # A repository token belongs only to this exact API request.
        return None


def main():
    match = re.search(r'\.version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
                      (ROOT / "build.zig.zon").read_text())
    if not match:
        raise ValueError("Expected a stable project version")
    version = match[1]
    repo = os.environ["GITHUB_REPOSITORY"]
    request = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/tags/v{version}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "omagma-docs",
                 "Authorization": "Bearer " + os.environ["GH_TOKEN"]})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            data = response.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("Release metadata exceeds its bound")
        release = json.loads(data)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        release = None
    systems = ("linux", "macos") if (ROOT / "docs/MACOS.md").exists() else ("linux",)
    expected = {"SHA256SUMS", "LICENSES.txt"} | {
        name for system in systems for arch in ("x86_64", "arm64")
        for name in (f"omagma-{system}-{arch}", f"omagma-{version}-{system}-{arch}.tar.gz")}
    ready = bool(release and release.get("draft") is False and release.get("prerelease") is False
                 and release.get("tag_name") == "v" + version
                 and expected <= {asset["name"] for asset in release.get("assets", [])})
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"ready={str(ready).lower()}\n")
    print("Installable version assets are available." if ready else
          "Site built; deployment resumes after the version's approved release is published.")


if __name__ == "__main__":
    main()
