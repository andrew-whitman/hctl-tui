# hctl profile wrappers for hctl-tui.
# shellcheck shell=zsh

hts_profile_list() {
  if hts_have hctl; then
    hctl config profile list "$@"
    return $?
  fi
  # Fallback: list keys from hctl config.json
  hts_python - "$(hts_hctl_config_path)" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except FileNotFoundError:
    print("(no hctl config — run: hctl init)")
    sys.exit(0)
cur = data.get("current_profile") or ""
for name in sorted((data.get("profiles") or {}).keys()):
    mark = "*" if name == cur else " "
    print(f"{mark} {name}")
PY
}

hts_profile_names() {
  hts_python - "$(hts_hctl_config_path)" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except FileNotFoundError:
    sys.exit(0)
for name in sorted((data.get("profiles") or {}).keys()):
    print(name)
PY
}

hts_profile_use() {
  local name="${1:?profile name required}"
  if ! hts_hctl_profile_exists "$name"; then
    hts_die "hctl profile not found: $name (run: hts profile init)"
    return 1
  fi
  if hts_have hctl; then
    hctl config profile use "$name" || true
  else
    hts_python - "$(hts_hctl_config_path)" "$name" <<'PY'
import json, sys
path, name = sys.argv[1:3]
with open(path) as f:
    data = json.load(f)
data["current_profile"] = name
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  fi
  hts_ensure_config
  hts_cfg_set_str '.active_hctl_profile' "$name"
  hts_log "active profile: $name"
}

hts_profile_init() {
  # Prefer hctl's own interactive/non-interactive init when available.
  local name="${1:-}"
  if hts_have hctl; then
    if [[ -n "$name" ]]; then
      hctl init --profile "$name"
    else
      hctl init
    fi
    # Sync active pointer from hctl
    local cur
    cur="$(hts_hctl_current_profile)"
    hts_ensure_config
    hts_cfg_set_str '.active_hctl_profile' "$cur"
    return $?
  fi
  hts_err "hctl is required to initialize profiles"
  hts_err "install: uv tool install git+https://github.com/ianmatson/harness-cli.git"
  hts_err "     or: brew tap imatson9119/tap && brew install hctl"
  return 1
}

hts_profile_doctor() {
  if hts_have hctl; then
    local profile
    profile="$(hts_active_profile)"
    hctl --profile "$profile" doctor "$@"
  else
    hts_die "hctl not found"
  fi
}

hts_resolve_profile() {
  # Optional override as $1; else config / hctl current
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    print -- "$override"
    return 0
  fi
  hts_active_profile
}
