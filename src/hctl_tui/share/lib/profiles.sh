# hctl profile wrappers for hctl-tui.
# shellcheck shell=zsh

# True when this hctl build supports `hctl config profile …`
# (older builds only have get/set/list and error: Unknown config action: profile)
hts_hctl_supports_config_profile() {
  hts_have hctl || return 1
  # Prefer a cheap probe; older hctl returns non-zero / that error string.
  local out
  out="$(hctl config profile list 2>&1)" && return 0
  print -- "$out" | grep -qi 'Unknown config action: *profile' && return 1
  # Other errors (no config yet) still indicate the subcommand exists
  print -- "$out" | grep -qi 'usage:\|config profile\|No such file\|not found\|no profile\|profiles' && return 0
  return 1
}

hts_profile_list_from_file() {
  hts_python - "$(hts_hctl_config_path)" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except FileNotFoundError:
    print("(no hctl config — run: hts init)", file=sys.stderr)
    sys.exit(1)
profiles = data.get("profiles") or {}
if not profiles:
    print("(no profiles — run: hts init)", file=sys.stderr)
    sys.exit(1)
cur = data.get("current_profile") or ""
for name in sorted(profiles.keys()):
    mark = "*" if name == cur else " "
    print(f"{mark} {name}")
PY
}

hts_profile_use_in_file() {
  local name="${1:?}"
  hts_python - "$(hts_hctl_config_path)" "$name" <<'PY'
import json, sys
path, name = sys.argv[1:3]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    print(f"no hctl config at {path} — run: hts init", file=sys.stderr)
    sys.exit(1)
if name not in (data.get("profiles") or {}):
    print(f"profile not found: {name}", file=sys.stderr)
    sys.exit(1)
data["current_profile"] = name
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

hts_profile_list() {
  if hts_have hctl && hts_hctl_supports_config_profile; then
    if hctl config profile list "$@"; then
      return 0
    fi
  elif hts_have hctl; then
    hts_log "hctl build lacks 'config profile' — listing from $(hts_hctl_config_path)"
    hts_log "upgrade: uv tool install --force git+https://github.com/ianmatson/harness-cli.git"
  fi
  hts_profile_list_from_file
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
  if hts_have hctl && hts_hctl_supports_config_profile; then
    hctl config profile use "$name" || hts_profile_use_in_file "$name"
  else
    hts_profile_use_in_file "$name"
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
    if ! hts_hctl_supports_config_profile; then
      hts_log "note: hctl is outdated (no 'config profile' support)"
      hts_log "upgrade: uv tool install --force git+https://github.com/ianmatson/harness-cli.git"
    fi
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
