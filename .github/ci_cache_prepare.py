#!/usr/bin/env python3
"""Keep Zig 0.17's temporary cache directories present across CI handoffs."""
import argparse
from pathlib import Path
import shutil


TEMPORARY_DIRECTORIES = (".zig-cache/tmp", ".ci-zig/global/tmp")


def prepare(root: Path, *, clean: bool = False) -> None:
    for relative in TEMPORARY_DIRECTORIES:
        directory = root / relative
        if clean and directory.exists():
            shutil.rmtree(directory)
        # Maker can reuse its compiled configurer while needing a new config.
        # It opens tmp/<random> directly, without creating the parent directory.
        directory.mkdir(parents=True, exist_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clean", action="store_true",
                        help="remove temporary contents before saving compilation caches")
    args = parser.parse_args()
    prepare(Path.cwd(), clean=args.clean)
