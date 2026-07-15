#!/usr/bin/env python3
"""Fail if package versions in pyproject.toml and __init__.py disagree."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYPROJECT = ROOT / "pyproject.toml"
INIT = ROOT / "src" / "hctl_tui" / "__init__.py"


def main() -> int:
    py_text = PYPROJECT.read_text(encoding="utf-8")
    init_text = INIT.read_text(encoding="utf-8")
    py_m = re.search(r'(?m)^version\s*=\s*"([^"]+)"', py_text)
    init_m = re.search(r'(?m)^__version__\s*=\s*"([^"]+)"', init_text)
    if not py_m:
        print(f"error: no version in {PYPROJECT}", file=sys.stderr)
        return 1
    if not init_m:
        print(f"error: no __version__ in {INIT}", file=sys.stderr)
        return 1
    if py_m.group(1) != init_m.group(1):
        print(
            "error: package versions are out of sync\n"
            f"  pyproject.toml:           {py_m.group(1)}\n"
            f"  src/hctl_tui/__init__.py: {init_m.group(1)}",
            file=sys.stderr,
        )
        return 1
    print(f"ok: version {py_m.group(1)} is in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
