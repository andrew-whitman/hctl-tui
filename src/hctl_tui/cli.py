"""Console entrypoint for `hts` / `python -m hctl_tui`."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def share_dir() -> Path:
    return Path(__file__).resolve().parent / "share"


def enriched_path(existing: str | None = None) -> str:
    """Build a PATH that always includes system + uv tool bins.

    ``uv tool`` / GUI launches often ship a sparse PATH that omits ``/bin``
    and ``/usr/bin``, which breaks basic utilities (``rm``, ``mktemp``, …).
    """
    home = Path.home()
    required = [
        str(home / ".local" / "bin"),  # uv tool install → hctl, hts
        str(home / ".cargo" / "bin"),  # uv installer fallback
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    parts: list[str] = []
    seen: set[str] = set()

    def add(part: str) -> None:
        if not part or part in seen:
            return
        seen.add(part)
        parts.append(part)

    for part in required:
        add(part)
    for part in (existing or "").split(":"):
        add(part)
    return ":".join(parts)


def find_zsh(path: str) -> str | None:
    for candidate in (
        shutil_which("zsh", path),
        "/bin/zsh",
        "/usr/bin/zsh",
        "/opt/homebrew/bin/zsh",
        "/usr/local/bin/zsh",
    ):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def shutil_which(cmd: str, path: str) -> str | None:
    for directory in path.split(":"):
        if not directory:
            continue
        candidate = os.path.join(directory, cmd)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def main(argv: list[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    share = share_dir()
    script = share / "bin" / "hts"
    if not script.is_file():
        print(f"hctl-tui: missing shell entry at {script}", file=sys.stderr)
        raise SystemExit(1)

    env = os.environ.copy()
    path = enriched_path(env.get("PATH"))
    env["PATH"] = path
    env["HTS_ROOT"] = str(share)
    env["HTS_LIB"] = str(share / "lib")

    zsh = find_zsh(path)
    if not zsh:
        print(
            "hctl-tui: zsh is required but was not found "
            "(tried PATH, /bin/zsh, /usr/bin/zsh)",
            file=sys.stderr,
        )
        raise SystemExit(1)

    # Replace this process with the zsh TUI/CLI (same argv semantics as bin/hts).
    os.execve(zsh, [zsh, str(script), *args], env)


if __name__ == "__main__":
    main()
