"""Read compiler and optimization identity from the tested backend, not PATH."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def build_mode(value):
    aliases = {"debug": "debug", "safe": "safe", "releasesafe": "safe"}
    try:
        return aliases[value.lower()]
    except (AttributeError, KeyError):
        raise argparse.ArgumentTypeError("build mode must be debug or safe") from None


def read_build_info(binary, expected_mode=None):
    binary = Path(binary).resolve()
    # This command must work before configuration or desktop services exist.
    env = dict(os.environ)
    env.pop("HOME", None)
    result = subprocess.run([str(binary), "build-info"], capture_output=True,
                            env=env, timeout=5, check=True)
    if result.stderr or len(result.stdout) > 4096:
        raise AssertionError("build-info must return one small JSON object without diagnostics")
    info = json.loads(result.stdout)
    if not isinstance(info, dict) or set(info) != {"version", "zigVersion", "optimizeMode"}:
        raise AssertionError("invalid binary build-info fields")
    pin = re.search(r'\.minimum_zig_version\s*=\s*"([^"\n]+)"',
                    (ROOT / "build.zig.zon").read_text())
    if not pin or info["zigVersion"] != pin[1]:
        raise AssertionError("tested binary compiler differs from the project's exact pin")
    if info["optimizeMode"] not in {"debug", "safe"}:
        raise AssertionError("correctness and memory gates require debug or safe assertions")
    version = re.search(r'\.version\s*=\s*"([^"\n]+)"', (ROOT / "build.zig.zon").read_text())
    if not version or info["version"] != version[1]:
        raise AssertionError("tested binary application version differs from the project")
    if expected_mode is not None and info["optimizeMode"] != build_mode(expected_mode):
        raise AssertionError("tested binary optimization mode differs from the requested gate")
    return {"zigVersion": info["zigVersion"], "buildMode": info["optimizeMode"],
            "appVersion": info["version"]}
