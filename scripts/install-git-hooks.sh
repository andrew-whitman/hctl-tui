#!/usr/bin/env bash
# Install tracked hooks from scripts/git-hooks/ into .git/hooks/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/git-hooks"
DST="$ROOT/.git/hooks"

if [[ ! -d "$ROOT/.git" ]]; then
  echo "error: not a git repository: $ROOT" >&2
  exit 1
fi

if [[ ! -d "$SRC" ]]; then
  echo "error: missing $SRC" >&2
  exit 1
fi

mkdir -p "$DST"
installed=0
for hook in "$SRC"/*; do
  [[ -f "$hook" ]] || continue
  name="$(basename "$hook")"
  target="$DST/$name"
  cp "$hook" "$target"
  chmod +x "$target" "$hook"
  echo "installed $target"
  installed=$((installed + 1))
done

if (( installed == 0 )); then
  echo "error: no hooks found in $SRC" >&2
  exit 1
fi
