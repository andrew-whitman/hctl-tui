# Shared utilities for hctl-tui.
# shellcheck shell=zsh

HTS_CONFIG_DIR="${HTS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/hctl-tui}"
HTS_CONFIG_FILE="${HTS_CONFIG_DIR}/config.yaml"
HTS_MATRICES_DIR="${HTS_CONFIG_DIR}/matrices"
HTS_HCTL_CONFIG="${HARNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/hctl/config.json}"
HTS_PYTHON="${HTS_PYTHON:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || print /usr/bin/python3)}"

# When HTS_TUI_ACTIVE=1, status logs are silenced so they don't litter the
# alt-screen above gum boxes after a clear/redraw.
hts_log()  {
  [[ "${HTS_TUI_ACTIVE:-0}" == "1" ]] && return 0
  print -u2 -- "[hts] $*"
}
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

# --- terminal size / adaptive display ---

hts_term_cols() {
  local c="${COLUMNS:-}"
  if [[ -z "$c" || "$c" -lt 1 ]]; then
    c="$(tput cols 2>/dev/null || true)"
  fi
  if [[ -z "$c" || "$c" -lt 1 ]] && [[ -r /dev/tty ]]; then
    c="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  fi
  if [[ -z "$c" || "$c" -lt 20 ]]; then
    c=80
  fi
  print -- "$c"
}

hts_term_rows() {
  local r="${LINES:-}"
  if [[ -z "$r" || "$r" -lt 1 ]]; then
    r="$(tput lines 2>/dev/null || true)"
  fi
  if [[ -z "$r" || "$r" -lt 1 ]] && [[ -r /dev/tty ]]; then
    r="$(stty size </dev/tty 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -z "$r" || "$r" -lt 8 ]]; then
    r=24
  fi
  print -- "$r"
}

hts_gum_width() {
  # Leave a little margin for borders/padding inside the viewport.
  local w
  w="$(hts_term_cols)"
  w=$(( w - 2 ))
  (( w < 32 )) && w=32
  print -- "$w"
}

# Short status messages (args preferred). Avoid piping preformatted tables here —
# gum --width reflows lines and UTF-8 borders can show as mojibake in some terminals.
hts_gum_box() {
  local fg="${HTS_GUM_FG:-212}"
  local w
  w="$(hts_gum_width)"
  if (( $# )); then
    gum style --border rounded --padding "0 1" --width "$w" --border-foreground "$fg" "$@"
  else
    # stdin path: no --width so aligned tables are not reflowed
    gum style --border rounded --padding "0 1" --border-foreground "$fg"
  fi
}

hts_gum_box_warn()  { HTS_GUM_FG=214 hts_gum_box "$@"; }
hts_gum_box_error() { HTS_GUM_FG=196 hts_gum_box "$@"; }

# Clean multi-line text for the TUI (no lipgloss reflow).
# Args are lines, or stdin when no args. Prefer /dev/tty when it actually works.
hts_tui_show() {
  if { print -n -- "" >/dev/tty; } 2>/dev/null; then
    if (( $# )); then
      printf '%s\n' "$@" >/dev/tty
    else
      /bin/cat >/dev/tty
    fi
  else
    if (( $# )); then
      printf '%s\n' "$@"
    else
      /bin/cat
    fi
  fi
}

# Truncate a string to max width with an ellipsis when needed.
hts_trunc() {
  local s="$1" max="${2:-40}"
  hts_python -c '
import sys
s, max_w = sys.argv[1], int(sys.argv[2])
if max_w < 1:
    print("")
elif len(s) <= max_w:
    print(s)
elif max_w <= 3:
    print(s[:max_w])
else:
    print(s[: max_w - 3] + "...")
' "$s" "$max"
}

# Format matrix entries (JSON array on stdin) for the current terminal width.
# Wide: aligned columns. Narrow: stacked cards.
hts_format_entries() {
  local cols raw
  cols="$(hts_term_cols)"
  # Capture stdin before the heredoc steals it for the Python program.
  raw="$(/bin/cat)"
  HTS_FMT_INPUT="$raw" hts_python - "$cols" <<'PY'
import json, os, sys

cols = int(sys.argv[1]) if sys.argv[1].isdigit() else 80
raw = (os.environ.get("HTS_FMT_INPUT") or "").strip() or "[]"
try:
    entries = json.loads(raw)
except json.JSONDecodeError:
    print(raw)
    raise SystemExit(0)

if not entries:
    print("(empty)")
    raise SystemExit(0)

def trunc(s, n):
    s = str(s or "")
    if n <= 0:
        return ""
    if len(s) <= n:
        return s
    if n <= 3:
        return s[:n]
    return s[: n - 3] + "..."

def pipeline(e):
    p = e.get("pipeline") or {}
    return "{}/{}/{}".format(p.get("org") or "", p.get("project") or "", p.get("identifier") or "")

# Narrow terminals: stacked cards (readable at any width)
if cols < 72:
    width = max(24, cols - 2)
    for i, e in enumerate(entries):
        if i:
            print("-" * min(width, cols))
        rows = [
            ("alias", e.get("alias") or ""),
            ("trigger", e.get("trigger") or ""),
            ("tech", e.get("tech") or ""),
            ("set", e.get("set") or ""),
            ("pipeline", pipeline(e)),
        ]
        label_w = 9  # len("pipeline:")
        val_w = max(8, width - label_w - 1)
        for label, val in rows:
            print("{:<{lw}} {}".format(label + ":", trunc(val, val_w), lw=label_w))
    raise SystemExit(0)

# Wide: distribute columns to fit terminal
# budgets for alias, trigger, tech, set; pipeline takes the rest
headers = ["ALIAS", "TRIGGER", "TECH", "SET", "PIPELINE"]
keys = ["alias", "trigger", "tech", "set", "pipeline"]
rows = []
for e in entries:
    rows.append([
        str(e.get("alias") or ""),
        str(e.get("trigger") or ""),
        str(e.get("tech") or ""),
        str(e.get("set") or ""),
        pipeline(e),
    ])

# Natural widths (min of content / generous caps)
caps = [20, 18, 10, 10, 60]
mins = [5, 7, 4, 3, 8]
natural = []
for i in range(5):
    w = len(headers[i])
    for r in rows:
        w = max(w, len(r[i]))
    natural.append(min(caps[i], max(mins[i], w)))

# gaps: 4 spaces between 5 cols
sep = 1
avail = cols - sep * 4
total = sum(natural)
if total > avail:
    # Shrink from the right (pipeline first), then evenly
    overflow = total - avail
    order = [4, 0, 1, 2, 3]
    for i in order:
        if overflow <= 0:
            break
        can = natural[i] - mins[i]
        cut = min(can, overflow)
        natural[i] -= cut
        overflow -= cut

widths = natural

def fmt_row(vals):
    parts = []
    for i, v in enumerate(vals):
        parts.append("{:<{w}}".format(trunc(v, widths[i]), w=widths[i]))
    return (" " * sep).join(parts)

print(fmt_row(headers))
print("-" * min(cols, sum(widths) + sep * 4))
for r in rows:
    print(fmt_row(r))
PY
}

# Format run results (TSV alias/status/url lines on stdin) for terminal width.
hts_format_results() {
  local cols raw
  cols="$(hts_term_cols)"
  raw="$(/bin/cat)"
  HTS_FMT_INPUT="$raw" hts_python - "$cols" <<'PY'
import os, sys

cols = int(sys.argv[1]) if sys.argv[1].isdigit() else 80
raw = os.environ.get("HTS_FMT_INPUT") or ""
lines = [ln.rstrip("\n") for ln in raw.splitlines() if ln.strip()]
if not lines:
    print("(no results)")
    raise SystemExit(0)

def trunc(s, n):
    s = str(s or "")
    if n <= 0:
        return ""
    if len(s) <= n:
        return s
    if n <= 3:
        return s[:n]
    return s[: n - 3] + "..."

rows = []
for ln in lines:
    parts = ln.split("\t")
    while len(parts) < 3:
        parts.append("")
    rows.append(parts[:3])

print("RESULTS")
if cols < 56:
    width = max(24, cols)
    for i, (alias, status, url) in enumerate(rows):
        if i:
            print("-" * min(width, cols))
        print("alias:  " + trunc(alias, max(8, width - 8)))
        print("status: " + trunc(status, max(8, width - 8)))
        if url:
            print("url:    " + trunc(url, max(8, width - 8)))
else:
    # alias | status | url
    w_status = 10
    w_alias = min(28, max(8, cols // 4))
    w_url = max(12, cols - w_alias - w_status - 2)
    print("{:<{a}} {:<{s}} {}".format("ALIAS", "STATUS", "URL", a=w_alias, s=w_status))
    print("-" * min(cols, w_alias + w_status + w_url + 2))
    for alias, status, url in rows:
        print("{:<{a}} {:<{s}} {}".format(
            trunc(alias, w_alias),
            trunc(status, w_status),
            trunc(url, w_url),
            a=w_alias,
            s=w_status,
        ))
PY
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
    /bin/cat >"$HTS_CONFIG_FILE" <<'EOF'
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
