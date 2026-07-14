"""Console entrypoint for `hts` / `python -m hctl_tui`."""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def share_dir() -> Path:
    return Path(__file__).resolve().parent / "share"


def main(argv: list[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    share = share_dir()
    script = share / "bin" / "hts"
    if not script.is_file():
        print(f"hctl-tui: missing shell entry at {script}", file=sys.stderr)
        raise SystemExit(1)

    zsh = shutil.which("zsh")
    if not zsh:
        print(
            "hctl-tui: zsh is required but was not found on PATH",
            file=sys.stderr,
        )
        raise SystemExit(1)

    env = os.environ.copy()
    env["HTS_ROOT"] = str(share)
    env["HTS_LIB"] = str(share / "lib")
    # uv tool / GUI launches often ship a sparse PATH; keep system + user bins discoverable.
    home = Path.home()
    extras = [
        str(home / ".local" / "bin"),  # uv tool install → hctl
        str(home / ".cargo" / "bin"),  # uv installer fallback
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    path = env.get("PATH") or ""
    for part in extras:
        if part and part not in path.split(":"):
            path = f"{path}:{part}" if path else part
    env["PATH"] = path
    # Replace this process with the zsh TUI/CLI (same argv semantics as bin/hts).
    os.execve(zsh, [zsh, str(script), *args], env)


if __name__ == "__main__":
    main()
