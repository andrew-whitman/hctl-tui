# Shared utilities for hctl-tui.
# shellcheck shell=zsh

HTS_CONFIG_DIR="${HTS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/hctl-tui}"
HTS_CONFIG_FILE="${HTS_CONFIG_DIR}/config.yaml"
HTS_MATRICES_DIR="${HTS_CONFIG_DIR}/matrices"
HTS_HCTL_CONFIG="${HARNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/hctl/config.json}"
HTS_PYTHON="${HTS_PYTHON:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || print /usr/bin/python3)}"

hts_log()  { print -u2 -- "[hts] $*"; }
hts_err()  { print -u2 -- "[hts] error: $*"; }
hts_die()  { hts_err "$*"; return 1; }

hts_have() { command -v "$1" >/dev/null 2>&1; }

hts_python() {
  if [[ -x "$HTS_PYTHON" ]] || command -v "$HTS_PYTHON" >/dev/null 2>&1; then
    "$HTS_PYTHON" "$@"
  elif [[ -x /usr/bin/python3 ]]; then
    /usr/bin/python3 "$@"
  else
    hts_die "python3 not found"
    return 1
  fi
}

hts_require_deps() {
  # usage: hts_require_deps [tui|run|any]
  local mode="${1:-any}"
  local missing=()
  hts_have zsh || missing+=(zsh)
  if ! hts_python -c 'import sys' >/dev/null 2>&1; then
    missing+=(python3)
  fi
  case "$mode" in
    tui)
      hts_have gum || missing+=(gum)
      hts_have hctl || missing+=(hctl)
      ;;
    run)
      hts_have hctl || missing+=(hctl)
      hts_have curl || missing+=(curl)
      ;;
    dry-run|matrix|any)
      ;;
  esac
  # yq is optional when PyYAML is present
  if ! hts_have yq; then
    if ! hts_python -c 'import yaml' >/dev/null 2>&1; then
      missing+=(yq-or-PyYAML)
    fi
  fi
  if (( ${#missing[@]} )); then
    hts_err "missing dependencies: ${missing[*]}"
    hts_err "run setup.sh or install: gum, hctl, yq (or pip install pyyaml)"
    return 1
  fi
}

hts_ensure_config() {
  /bin/mkdir -p "$HTS_MATRICES_DIR"
  if [[ ! -f "$HTS_CONFIG_FILE" ]]; then
    cat >"$HTS_CONFIG_FILE" <<'EOF'
active_hctl_profile: default
defaults:
  module: ci
  open_urls: true
EOF
  fi
}

hts_cfg_get() {
  # usage: hts_cfg_get '.active_hctl_profile'
  local expr="$1"
  if hts_have yq && yq --version 2>&1 | grep -qi 'mikefarah\|https://github.com/mikefarah'; then
    yq -r "${expr} // \"\"" "$HTS_CONFIG_FILE" 2>/dev/null && return 0
  fi
  hts_python - "$HTS_CONFIG_FILE" "$expr" <<'PY'
import sys
path, expr = sys.argv[1], sys.argv[2].lstrip(".")
try:
    import yaml
    data = yaml.safe_load(open(path)) or {}
except Exception:
    print("")
    raise SystemExit(0)
cur = data
for part in expr.split("."):
    if not isinstance(cur, dict):
        print("")
        raise SystemExit(0)
    cur = cur.get(part)
if cur is None:
    print("")
else:
    print(cur)
PY
}

hts_cfg_set_str() {
  local path="$1" value="$2"
  if hts_have yq && yq --version 2>&1 | grep -qi 'mikefarah\|https://github.com/mikefarah'; then
    yq -i eval "${path} = \"$value\"" "$HTS_CONFIG_FILE" 2>/dev/null && return 0
  fi
  hts_python - "$HTS_CONFIG_FILE" "$path" "$value" <<'PY'
import sys, re
path_file, dotted, value = sys.argv[1], sys.argv[2].lstrip("."), sys.argv[3]
try:
    import yaml
except ImportError:
    text = open(path_file).read()
    key = dotted.split(".")[-1]
    if key == "active_hctl_profile":
        text = re.sub(r"(?m)^active_hctl_profile:\s*.*$", f"active_hctl_profile: {value}", text)
    elif key == "module":
        text = re.sub(r"(?m)^(\s*)module:\s*.*$", rf"\1module: {value}", text, count=1)
    elif key == "open_urls":
        text = re.sub(r"(?m)^(\s*)open_urls:\s*.*$", rf"\1open_urls: {value}", text, count=1)
    open(path_file, "w").write(text)
    raise SystemExit(0)
with open(path_file) as f:
    data = yaml.safe_load(f) or {}
parts = dotted.split(".")
cur = data
for p in parts[:-1]:
    cur = cur.setdefault(p, {})
if value.lower() in ("true", "false"):
    cur[parts[-1]] = value.lower() == "true"
else:
    cur[parts[-1]] = value
with open(path_file, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PY
}

hts_active_profile() {
  local p
  p="$(hts_cfg_get '.active_hctl_profile')"
  if [[ -z "$p" || "$p" == "null" ]]; then
    p="$(hts_hctl_current_profile 2>/dev/null || true)"
  fi
  print -- "${p:-default}"
}

hts_default_module() {
  local m
  m="$(hts_cfg_get '.defaults.module')"
  print -- "${m:-ci}"
}

hts_open_urls_enabled() {
  local v
  v="$(hts_cfg_get '.defaults.open_urls')"
  [[ "$v" == "true" || "$v" == "True" || "$v" == "1" ]]
}

hts_matrix_path() {
  local profile="${1:?}" module="${2:?}"
  print -- "${HTS_MATRICES_DIR}/${profile}/${module}.yaml"
}

hts_list_modules() {
  local profile="${1:?}"
  local dir="${HTS_MATRICES_DIR}/${profile}"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.yaml(N); do
    print -- "${f:t:r}"
  done
}

hts_open_url() {
  local url="$1"
  [[ -n "$url" ]] || return 0
  if [[ "$(uname -s)" == "Darwin" ]]; then
    open "$url" >/dev/null 2>&1 || true
  elif hts_have xdg-open; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

# --- hctl config helpers (auth lives in hctl) ---

hts_hctl_config_path() {
  print -- "$HTS_HCTL_CONFIG"
}

hts_hctl_current_profile() {
  if [[ -f "$(hts_hctl_config_path)" ]]; then
    hts_python - "$(hts_hctl_config_path)" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get("current_profile") or "default")
PY
  else
    print -- default
  fi
}

hts_hctl_profile_field() {
  # usage: hts_hctl_profile_field PROFILE KEY
  local profile="$1" key="$2"
  hts_python - "$(hts_hctl_config_path)" "$profile" "$key" <<'PY'
import json, sys
path, profile, key = sys.argv[1:4]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    sys.exit(0)
profiles = data.get("profiles") or {}
prof = dict(profiles.get(profile) or {})
# inherit api_key from default when missing
if key == "api_key" and not prof.get("api_key"):
    d = profiles.get("default") or {}
    print(d.get("api_key") or "")
else:
    print(prof.get(key) or "")
PY
}

hts_hctl_profile_exists() {
  local profile="$1"
  hts_python - "$(hts_hctl_config_path)" "$profile" <<'PY'
import json, sys
path, profile = sys.argv[1:3]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    sys.exit(1)
sys.exit(0 if profile in (data.get("profiles") or {}) else 1)
PY
}

hts_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  print -- "$s"
}
