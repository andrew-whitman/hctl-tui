#!/usr/bin/env python3
"""Pre-commit: bump package version when needed; keep sources in sync.

Updates:
  - pyproject.toml  → version = "X.Y.Z"
  - src/hctl_tui/__init__.py → __version__ = "X.Y.Z"

Default bump: patch.
Override:  HCTL_TUI_BUMP=patch|minor|major
Skip:      HCTL_TUI_NO_BUMP=1  (or SKIP_VERSION_BUMP=1)
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYPROJECT = ROOT / "pyproject.toml"
INIT = ROOT / "src" / "hctl_tui" / "__init__.py"
PYPROJECT_REL = "pyproject.toml"
INIT_REL = "src/hctl_tui/__init__.py"

VERSION_RE_PYPROJECT = re.compile(r'(?m)^(version\s*=\s*")([^"]+)(")')
VERSION_RE_INIT = re.compile(r'(?m)^(__version__\s*=\s*")([^"]+)(")')

# Staged paths that never require a version bump by themselves.
DOCS_PREFIXES = (
    ".cursor/",
    "docs/",
)
DOCS_NAMES = {
    "LICENSE",
    "README.md",
    "hctl-tui-spec.md",
    ".gitignore",
}
DOCS_SUFFIXES = (".md",)


def _run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=check,
    )


def _staged_files() -> list[str]:
    out = _run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"]
    ).stdout
    return [line for line in out.splitlines() if line]


def _head_file(rel: str) -> str | None:
    proc = _run(["git", "show", f"HEAD:{rel}"], check=False)
    if proc.returncode != 0:
        return None
    return proc.stdout


def _version_from_pyproject(text: str) -> str:
    match = VERSION_RE_PYPROJECT.search(text)
    if not match:
        raise SystemExit(f"error: no version = \"...\" in {PYPROJECT_REL}")
    return match.group(2)


def _version_from_init(text: str) -> str:
    match = VERSION_RE_INIT.search(text)
    if not match:
        raise SystemExit(f'error: no __version__ = "..." in {INIT_REL}')
    return match.group(2)


def _parse_semver(version: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        raise SystemExit(f"error: unsupported version (need X.Y.Z): {version!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def _bump(version: str, kind: str) -> str:
    major, minor, patch = _parse_semver(version)
    if kind == "major":
        return f"{major + 1}.0.0"
    if kind == "minor":
        return f"{major}.{minor + 1}.0"
    if kind == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise SystemExit(f"error: unknown bump kind {kind!r} (use patch|minor|major)")


def _set_versions(py_text: str, init_text: str, version: str) -> tuple[str, str]:
    py_new, n1 = VERSION_RE_PYPROJECT.subn(rf"\g<1>{version}\g<3>", py_text, count=1)
    init_new, n2 = VERSION_RE_INIT.subn(rf"\g<1>{version}\g<3>", init_text, count=1)
    if n1 != 1 or n2 != 1:
        raise SystemExit("error: failed to rewrite version fields")
    return py_new, init_new


def _is_docs_path(path: str) -> bool:
    if path in (PYPROJECT_REL, INIT_REL):
        return True
    if path in DOCS_NAMES:
        return True
    if path.startswith(DOCS_PREFIXES):
        return True
    if path.endswith(DOCS_SUFFIXES):
        return True
    return False


def _is_docs_only(files: list[str]) -> bool:
    return bool(files) and all(_is_docs_path(path) for path in files)


def _truthy(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def _requested_kind() -> str:
    raw = os.environ.get("HCTL_TUI_BUMP", "patch").strip().lower()
    if raw not in {"patch", "minor", "major"}:
        raise SystemExit(
            f"error: HCTL_TUI_BUMP must be patch|minor|major (got {raw!r})"
        )
    return raw


def _ensure_sync(py_ver: str, init_ver: str) -> None:
    if py_ver != init_ver:
        raise SystemExit(
            "error: package versions are out of sync\n"
            f"  {PYPROJECT_REL}:           {py_ver}\n"
            f"  {INIT_REL}: {init_ver}\n"
            "Fix manually, then retry the commit."
        )


def main() -> int:
    py_text = PYPROJECT.read_text(encoding="utf-8")
    init_text = INIT.read_text(encoding="utf-8")
    current = _version_from_pyproject(py_text)
    init_ver = _version_from_init(init_text)
    _ensure_sync(current, init_ver)

    head_py = _head_file(PYPROJECT_REL)
    head_ver = _version_from_pyproject(head_py) if head_py else None
    already_bumped = head_ver is not None and current != head_ver

    staged = _staged_files()
    skip = (
        _truthy("HCTL_TUI_NO_BUMP")
        or _truthy("SKIP_VERSION_BUMP")
        or already_bumped
        or not staged
        or _is_docs_only(staged)
    )

    if skip:
        print(f"ok: version {current} (no bump)")
        return 0

    kind = _requested_kind()
    new_ver = _bump(current, kind)
    py_new, init_new = _set_versions(py_text, init_text, new_ver)
    PYPROJECT.write_text(py_new, encoding="utf-8")
    INIT.write_text(init_new, encoding="utf-8")
    _run(["git", "add", "--", PYPROJECT_REL, INIT_REL])
    print(f"bumped version {current} → {new_ver} ({kind})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
