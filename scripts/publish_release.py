#!/usr/bin/env python3
"""Publish versioned CI artifacts with GitHub CLI transactional asset uploads."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.error
import urllib.request

from release import ROOT, package_versions


def api(repo, endpoint):
    request = urllib.request.Request(f"https://api.github.com/repos/{repo}/{endpoint}", headers={
        "Authorization": "Bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        return None


def find_release(repo, tag):
    published = api(repo, "releases/tags/" + tag)
    if published is not None:
        return published
    # The by-tag endpoint documents published releases only. Authorized release
    # listings also contain drafts, which must be found for interrupted uploads.
    page = 1
    while True:
        releases = api(repo, f"releases?per_page=100&page={page}")
        if releases is None:
            raise ValueError("Release listing is unavailable")
        matching = [release for release in releases if release["tag_name"] == tag]
        if len(matching) > 1:
            raise ValueError("Version has multiple release drafts")
        if matching:
            return matching[0]
        if len(releases) < 100:
            return None
        page += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Report whether this commit needs a release")
    args = parser.parse_args()
    version, zig = package_versions()
    tag = "v" + version
    repo, commit = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    existing = find_release(repo, tag)
    if args.check:
        needed = existing is None or existing["draft"]
        if existing and existing["draft"]:
            raise ValueError("Version has an unpublished draft; inspect it before retrying")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f"version={version}\nneeded={str(needed).lower()}\n")
        print(json.dumps({"version": version, "needed": needed}))
        return
    if existing:
        raise ValueError("Version already has a release or draft; refusing to replace it")
    reference = api(repo, "git/ref/tags/" + tag)
    if reference:
        raise ValueError("Version tag already exists; refusing to retarget it")
    names = [name for system in ("linux", "macos") for arch in ("x86_64", "arm64")
             for name in (f"omagma-{system}-{arch}", f"omagma-{version}-{system}-{arch}.tar.gz")]
    names.extend(("LICENSES.txt", "SHA256SUMS"))
    files = {name: ROOT / "dist" / name for name in names}
    sums = (ROOT / "dist/SHA256SUMS").read_text().splitlines()
    expected_sums = {hashlib.sha256(files[name].read_bytes()).hexdigest() + "  " + name for name in names[:-1]}
    if len(sums) != len(expected_sums) or set(sums) != expected_sums:
        raise ValueError("Combined release checksums are incomplete or incorrect")
    with tempfile.TemporaryDirectory(prefix="omagma-release-notes-") as temporary:
        notes = Path(temporary) / "notes.md"
        notes.write_text(f"Linux x86_64/arm64 static musl backends and complete Omarchy plugin bundles, plus native macOS Apple Silicon/Intel CLI and TUI bundles. The Omarchy bar is Linux-only; macOS binaries use system libraries and frameworks.\n\n"
                         f"Includes the account-separated bar and **experimental** Vim-oriented terminal mail client (`omagma tui`) and bounded JSONL agent CLI (`omagma cli`). Compose/reply, contacts, attachments and invitation replies are fixture-qualified. Users authorize their own requested terminal permissions; sends and mailbox/contact changes require an explicit action. Dedicated test mailboxes belong to developer live-write qualification, not ordinary setup. No tmux is required.\n\n"
                         f"HTML-only mail has a native theme-colored text view with headings, emphasis, lists, quotes and readable tables. Plain-text alternatives take precedence; remote resources never load. Click accounts, mailboxes, messages and contacts, use the wheel, or disable tracking with --no-mouse.\n\n"
                         f"This version includes forwarding and multiple files, cached correspondent completion, sender identities/signatures, draft recovery, bulk actions with undo, existing-label views, folded threads, link/file pickers, continuous cached-mail scrolling, local timezone display and saved working context. New compose shows its own draft preview; replies preserve their original context.\n\n"
                         f"Built with exact Zig {zig} in assertion-enabled safe mode.\n\n"
                         f"Download the matching `omagma-{version}-OS-ARCH.tar.gz` bundle and `SHA256SUMS`; Zig is not needed for installation. Native platform checks gate publication. Linux resource gates and macOS resource measurements have separate accounting; ARM Omarchy desktop integration requires local verification.\n\n"
                         f"[Terminal guide](https://github.com/{repo}/blob/{tag}/docs/TERMINAL.md) · [Agent CLI contract](https://github.com/{repo}/blob/{tag}/docs/AGENT-CLI.md)\n\n"
                         f"[Linux installation](https://github.com/{repo}/blob/{tag}/docs/INSTALL.md) · [macOS installation](https://github.com/{repo}/blob/{tag}/docs/MACOS.md) · [Agent setup workflow](https://github.com/{repo}/blob/{tag}/skills/omagma-setup/SKILL.md)\n")
        # With asset arguments, gh creates an internal draft, uploads all assets,
        # then publishes it. Ordinary upload/publish failures clean up that draft.
        command = ["gh", "release", "create", tag, "--repo", repo, "--target", commit, "--title",
                   "omagma " + version, "--notes-file", str(notes), *[str(files[name]) for name in names]]
        if "-" in version:
            command.append("--prerelease")
        subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
