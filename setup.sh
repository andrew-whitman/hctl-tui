#!/usr/bin/env zsh
# setup.sh — install deps and wire hts onto PATH
set -euo pipefail

ROOT="$(cd -- "${0:A:h}" && pwd)"
BIN_DIR="${HTS_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hctl-tui"

print -- "==> hctl-tui setup"
print -- "    root: $ROOT"

have() { command -v "$1" >/dev/null 2>&1; }

install_gum() {
  if have gum; then
    print -- "✓ gum: $(gum --version 2>/dev/null | head -1)"
    return 0
  fi
  print -- "→ installing gum…"
  if have brew; then
    brew install gum
  else
    print -- "error: install gum manually — https://github.com/charmbracelet/gum"
    return 1
  fi
}

install_yq() {
  if have yq; then
    print -- "✓ yq: $(yq --version 2>/dev/null | head -1)"
    return 0
  fi
  print -- "→ installing yq…"
  if have brew; then
    brew install yq
  else
    print -- "error: install mikefarah/yq — https://github.com/mikefarah/yq"
    return 1
  fi
}

install_pyyaml() {
  python3 -c 'import yaml' 2>/dev/null && { print -- "✓ PyYAML"; return 0; }
  print -- "→ installing PyYAML for matrix YAML I/O…"
  python3 -m pip install --user pyyaml >/dev/null 2>&1 \
    || pip3 install --user pyyaml >/dev/null 2>&1 \
    || print -- "warn: could not install PyYAML; matrix writes may fail"
}

install_hctl() {
  if have hctl; then
    print -- "✓ hctl: $(hctl --version 2>/dev/null | head -1 || print installed)"
    return 0
  fi
  print -- "→ installing hctl…"
  if have uv; then
    uv tool install "git+https://github.com/ianmatson/harness-cli.git" \
      || uv tool install "git+https://github.com/imatson9119/harness-cli.git"
  elif have brew; then
    brew tap imatson9119/tap 2>/dev/null || true
    brew install hctl || {
      print -- "warn: brew install hctl failed; try: uv tool install git+https://github.com/ianmatson/harness-cli.git"
      return 1
    }
  else
    print -- "error: install hctl — https://github.com/ianmatson/harness-cli"
    return 1
  fi
}

# --- run ---
install_gum
install_yq
install_pyyaml
install_hctl || print -- "warn: hctl missing — profile/trigger features need it"

mkdir -p "$CONFIG_DIR/matrices" "$BIN_DIR"
if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
  cp "$ROOT/config.example.yaml" "$CONFIG_DIR/config.yaml"
  print -- "✓ wrote $CONFIG_DIR/config.yaml"
else
  print -- "✓ config exists: $CONFIG_DIR/config.yaml"
fi

# Seed example matrix for default profile if empty
local_example="$CONFIG_DIR/matrices/default/ci.yaml"
if [[ ! -f "$local_example" ]]; then
  mkdir -p "${local_example:h}"
  cp "$ROOT/matrices.example.yaml" "$local_example"
  print -- "✓ seeded $local_example (edit triggers/pipelines before running)"
fi

chmod +x "$ROOT/bin/hts" "$ROOT/src/hctl_tui/share/bin/hts"
ln -sfn "$ROOT/bin/hts" "$BIN_DIR/hts"
print -- "✓ symlink $BIN_DIR/hts → $ROOT/bin/hts"
print -- "  (prefer: uv tool install git+https://github.com/andrew-whitman/hctl-tui.git)"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    print -- ""
    print -- "Add to your shell rc:"
    print -- "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

if ! have hctl; then
  print -- ""
  print -- "Next: install/configure hctl, then:  hctl init"
fi

print -- ""
print -- "Done. Launch:  hts"
