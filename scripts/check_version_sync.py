#!/usr/bin/env python3
"""Fail if package versions in pyproject.toml and __init__.py disagree."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYPROJECT = ROOT / "pyproject.toml"
INIT = ROOT / "src" / "hctl_tui" / "__init__.py"


def _version_from_pyproject(text: str) -> str:
    match = re.search(r'(?m)^version\s*=\s*"([^"]+)"', text)
    if not match:
        raise SystemExit(f"error: no [project] version = \"...\" in {PYPROJECT}")
    return match.group(1)


def _version_from_init(text: str) -> str:
    match = re.search(r'(?m)^__version__\s*=\s*"([^"]+)"', text)
    if not match:
        raise SystemExit(f'error: no __version__ = "..." in {INIT}')
    return match.group(1)


def main() -> int:
    py_ver = _version_from_pyproject(PYPROJECT.read_text(encoding="utf-8"))
    init_ver = _version_from_init(INIT.read_text(encoding="utf-8"))
    if py_ver != init_ver:
        print(
            "error: package versions are out of sync\n"
            f"  pyproject.toml:           {py_ver}\n"
            f"  src/hctl_tui/__init__.py: {init_ver}\n"
            "Keep both identical (see .cursor/rules/semver-on-main.mdc).",
            file=sys.stderr,
        )
        return 1
    print(f"ok: version {py_ver} is in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
