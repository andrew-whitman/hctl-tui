# Dependency install helpers for hts init (prefer uv when possible).
# shellcheck shell=zsh

HTS_HCTL_GIT_URLS=(
  "git+https://github.com/ianmatson/harness-cli.git"
  "git+https://github.com/imatson9119/harness-cli.git"
)

hts_user_bin_dir() {
  print -- "${HTS_BIN_DIR:-$HOME/.local/bin}"
}

hts_path_prepend_user_bin() {
  local d
  d="$(hts_user_bin_dir)"
  /bin/mkdir -p "$d"
  case ":$PATH:" in
    *":$d:"*) ;;
    *) export PATH="$d:$PATH" ;;
  esac
  # uv tool installs often land here too
  if [[ -d "$HOME/.cargo/bin" ]]; then
    case ":$PATH:" in
      *":$HOME/.cargo/bin:"*) ;;
      *) export PATH="$HOME/.cargo/bin:$PATH" ;;
    esac
  fi
}

hts_have_uv() {
  hts_have uv
}

hts_install_uv() {
  if hts_have_uv; then
    hts_log "✓ uv: $(uv --version 2>/dev/null | head -1)"
    return 0
  fi
  hts_log "→ installing uv (needed for hctl)…"
  if hts_have brew; then
    brew install uv && return 0
  fi
  if hts_have curl || [[ -x /usr/bin/curl ]]; then
    hts_curl -LsSf https://astral.sh/uv/install.sh | sh
    hts_path_prepend_user_bin
    # official installer may put uv in ~/.local/bin or ~/.cargo/bin
    if [[ -x "$HOME/.local/bin/uv" ]]; then
      export PATH="$HOME/.local/bin:$PATH"
    fi
    if [[ -x "$HOME/.cargo/bin/uv" ]]; then
      export PATH="$HOME/.cargo/bin:$PATH"
    fi
    hts_have_uv && return 0
  fi
  hts_err "could not install uv — install manually: https://docs.astral.sh/uv/"
  return 1
}

hts_install_hctl() {
  if hts_have hctl; then
    hts_log "✓ hctl: $(hctl --version 2>/dev/null | head -1 || print installed)"
    # Older installs lack `hctl config profile` — refresh via uv when possible
    local supports=0
    if hctl config profile list >/dev/null 2>&1; then
      supports=1
    else
      local probe
      probe="$(hctl config profile list 2>&1 || true)"
      if ! print -- "$probe" | grep -qi 'Unknown config action: *profile'; then
        # Subcommand exists; other errors (empty config) are fine
        supports=1
      fi
    fi
    if (( ! supports )); then
      hts_log "→ upgrading hctl (missing config profile support)…"
      if hts_install_uv; then
        local url
        for url in "${HTS_HCTL_GIT_URLS[@]}"; do
          uv tool install --force "$url" && break
        done
        hts_path_prepend_user_bin
      fi
      if hctl config profile list >/dev/null 2>&1 || \
         ! hctl config profile list 2>&1 | grep -qi 'Unknown config action: *profile'; then
        hts_log "✓ hctl upgraded"
      else
        hts_log "warn: hctl still lacks config profile — hts will use config.json directly"
      fi
    fi
    return 0
  fi
  hts_log "→ installing hctl…"

  if hts_install_uv; then
    local url
    for url in "${HTS_HCTL_GIT_URLS[@]}"; do
      hts_log "  uv tool install $url"
      if uv tool install "$url"; then
        hts_path_prepend_user_bin
        if hts_have hctl; then
          hts_log "✓ hctl installed via uv"
          return 0
        fi
      fi
    done
  fi

  if hts_have brew; then
    hts_log "  trying brew…"
    brew tap imatson9119/tap 2>/dev/null || true
    if brew install hctl; then
      hts_have hctl && { hts_log "✓ hctl installed via brew"; return 0; }
    fi
  fi

  hts_err "could not install hctl"
  hts_err "  uv tool install git+https://github.com/ianmatson/harness-cli.git"
  return 1
}

hts_gum_asset_triple() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os=Darwin ;;
    Linux)  os=Linux ;;
    *)
      hts_err "unsupported OS for gum binary download: $os"
      return 1
      ;;
  esac
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *)
      hts_err "unsupported arch for gum binary download: $arch"
      return 1
      ;;
  esac
  print -- "${os}_${arch}"
}

hts_install_gum_from_github() {
  { hts_have curl || [[ -x /usr/bin/curl ]]; } || { hts_err "curl required to download gum"; return 1; }
  { hts_have tar || [[ -x /usr/bin/tar ]]; } || { hts_err "tar required to extract gum"; return 1; }

  local triple dest tmp tag asset url
  triple="$(hts_gum_asset_triple)" || return 1
  dest="$(hts_user_bin_dir)"
  /bin/mkdir -p "$dest"
  tmp="$(hts_mktemp -d gum-dl)"

  tag="$(
    hts_curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest \
      | hts_python -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null
  )"
  if [[ -z "$tag" ]]; then
    hts_err "could not resolve latest gum release"
    /bin/rm -rf "$tmp"
    return 1
  fi

  # Assets look like: gum_0.14.5_Darwin_arm64.tar.gz (tag may be v0.14.5)
  local ver="${tag#v}"
  asset="gum_${ver}_${triple}.tar.gz"
  url="https://github.com/charmbracelet/gum/releases/download/${tag}/${asset}"
  hts_log "  downloading $url"
  if ! hts_curl -fsSL "$url" -o "$tmp/gum.tgz"; then
    /bin/rm -rf "$tmp"
    return 1
  fi
  tar -xzf "$tmp/gum.tgz" -C "$tmp"
  local bin
  bin="$(/usr/bin/find "$tmp" -type f -name gum 2>/dev/null | head -1)"
  if [[ -z "$bin" || ! -f "$bin" ]]; then
    hts_err "gum binary missing from release archive"
    /bin/rm -rf "$tmp"
    return 1
  fi
  /bin/cp "$bin" "$dest/gum"
  chmod +x "$dest/gum"
  /bin/rm -rf "$tmp"
  hts_path_prepend_user_bin
  hts_have gum
}

hts_install_gum() {
  if hts_have gum; then
    hts_log "✓ gum: $(gum --version 2>/dev/null | head -1 || print installed)"
    return 0
  fi
  hts_log "→ installing gum…"
  if hts_have brew; then
    if brew install gum; then
      hts_have gum && { hts_log "✓ gum installed via brew"; return 0; }
    fi
  fi
  if hts_install_gum_from_github; then
    hts_log "✓ gum installed to $(hts_user_bin_dir)/gum"
    return 0
  fi
  hts_err "could not install gum — https://github.com/charmbracelet/gum"
  return 1
}

hts_deps_status() {
  hts_path_prepend_user_bin
  print -- "zsh:  $(hts_have zsh && print ok || print MISSING)"
  print -- "uv:   $(hts_have uv && uv --version 2>/dev/null | head -1 || print MISSING)"
  print -- "hctl: $(hts_have hctl && (hctl --version 2>/dev/null | head -1 || print ok) || print MISSING)"
  print -- "gum:  $(hts_have gum && (gum --version 2>/dev/null | head -1 || print ok) || print MISSING)"
  print -- "curl: $(hts_have curl && print ok || print MISSING)"
  if hts_python -c 'import yaml' >/dev/null 2>&1; then
    print -- "yaml: PyYAML ok"
  elif hts_have yq; then
    print -- "yaml: yq ok"
  else
    print -- "yaml: MISSING (PyYAML or yq)"
  fi
}

# Install peer tools needed for TUI + triggers. Prefer uv for hctl.
hts_deps_install() {
  local failed=0
  hts_path_prepend_user_bin

  if ! hts_have zsh; then
    hts_err "zsh is required (install via your OS package manager)"
    failed=1
  else
    hts_log "✓ zsh"
  fi

  hts_install_hctl || failed=1
  hts_install_gum || failed=1

  if ! hts_python -c 'import yaml' >/dev/null 2>&1 && ! hts_have yq; then
    hts_log "→ ensuring PyYAML…"
    if hts_have_uv; then
      uv pip install --python "$HTS_PYTHON" pyyaml >/dev/null 2>&1 || \
        hts_python -m pip install --user pyyaml >/dev/null 2>&1 || true
    else
      hts_python -m pip install --user pyyaml >/dev/null 2>&1 || true
    fi
    if ! hts_python -c 'import yaml' >/dev/null 2>&1 && ! hts_have yq; then
      hts_err "PyYAML/yq missing — matrix YAML edits may fail"
      failed=1
    else
      hts_log "✓ YAML support"
    fi
  else
    hts_log "✓ YAML support"
  fi

  print -- ""
  hts_deps_status
  (( failed == 0 ))
}
