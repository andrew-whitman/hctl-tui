# Matrix / pipeline CRUD for hctl-tui.
# shellcheck shell=zsh

hts_matrix_ensure() {
  local profile="${1:?}" module="${2:?}"
  local path
  path="$(hts_matrix_path "$profile" "$module")"
  /bin/mkdir -p "${path:h}"
  if [[ ! -f "$path" ]]; then
    cat >"$path" <<EOF
module: ${module}
entries: []
EOF
  fi
  print -- "$path"
}

hts_matrix_list() {
  local profile="${1:?}" module="${2:?}"
  local path
  path="$(hts_matrix_path "$profile" "$module")"
  if [[ ! -f "$path" ]]; then
    hts_log "no matrix for profile=$profile module=$module"
    return 0
  fi
  hts_python - "$path" <<'PY'
import sys
path = sys.argv[1]
try:
    import yaml
except ImportError:
    # Minimal display without PyYAML: print file
    print(open(path).read())
    sys.exit(0)

data = yaml.safe_load(open(path)) or {}
entries = data.get("entries") or []
if not entries:
    print("(empty matrix)")
    sys.exit(0)
fmt = "{:<24} {:<16} {:<10} {:<10} {}"
print(fmt.format("ALIAS", "TRIGGER", "TECH", "SET", "PIPELINE"))
print("-" * 80)
for e in entries:
    pipe = e.get("pipeline") or {}
    pid = f"{pipe.get('org','')}/{pipe.get('project','')}/{pipe.get('identifier','')}"
    print(fmt.format(
        str(e.get("alias") or ""),
        str(e.get("trigger") or ""),
        str(e.get("tech") or ""),
        str(e.get("set") or ""),
        pid,
    ))
PY
}

hts_matrix_entries_json() {
  # Emit entries as JSON array for filtering in runner
  local profile="${1:?}" module="${2:?}"
  local path
  path="$(hts_matrix_path "$profile" "$module")"
  [[ -f "$path" ]] || { print -- '[]'; return 0; }
  hts_python - "$path" <<'PY'
import json, sys
path = sys.argv[1]
try:
    import yaml
    data = yaml.safe_load(open(path)) or {}
    print(json.dumps(data.get("entries") or []))
except ImportError:
    # ultra-fallback: empty
    print("[]")
PY
}

hts_matrix_add() {
  local profile="$1" module="$2"
  local alias="$3" trigger="$4" tech="$5" set_="$6"
  local org="$7" project="$8" identifier="$9"
  local path
  path="$(hts_matrix_ensure "$profile" "$module")"
  hts_python - "$path" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" <<'PY'
import sys
path, alias, trigger, tech, set_, org, project, identifier = sys.argv[1:9]
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required for matrix writes (pip install pyyaml) or install mikefarah yq\n")
    sys.exit(1)

data = yaml.safe_load(open(path)) or {}
entries = list(data.get("entries") or [])
# replace if alias exists
entries = [e for e in entries if (e or {}).get("alias") != alias]
entries.append({
    "alias": alias,
    "trigger": trigger,
    "tech": tech,
    "set": set_,
    "pipeline": {
        "org": org,
        "project": project,
        "identifier": identifier,
    },
})
data["module"] = data.get("module") or "ci"
data["entries"] = entries
with open(path, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
print(f"added/updated entry: {alias}")
PY
  # Ensure module field matches the matrix file we wrote
  hts_python - "$path" "$module" <<'PY' || true
import sys
path, module = sys.argv[1:3]
try:
    import yaml
except ImportError:
    raise SystemExit(0)
data = yaml.safe_load(open(path)) or {}
data["module"] = module
with open(path, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PY
}

hts_matrix_remove() {
  local profile="$1" module="$2" alias="$3"
  local path
  path="$(hts_matrix_path "$profile" "$module")"
  [[ -f "$path" ]] || { hts_die "matrix not found: $path"; return 1; }
  hts_python - "$path" "$alias" <<'PY'
import sys
path, alias = sys.argv[1:3]
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required\n")
    sys.exit(1)
data = yaml.safe_load(open(path)) or {}
before = len(data.get("entries") or [])
data["entries"] = [e for e in (data.get("entries") or []) if (e or {}).get("alias") != alias]
after = len(data["entries"])
with open(path, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
if before == after:
    print(f"no entry with alias: {alias}", file=sys.stderr)
    sys.exit(1)
print(f"removed entry: {alias}")
PY
}

hts_matrix_filter() {
  # Filter JSON entries by optional tech/set/alias (comma-separated aliases)
  # stdin: JSON array; args: tech set aliases
  # NOTE: do not use `python - <<EOF` here — the heredoc would steal stdin from the pipe.
  local tech="${1:-}" set_="${2:-}" aliases="${3:-}"
  local raw
  raw="$(/bin/cat)"
  hts_python -c '
import json, sys
tech, set_, aliases, raw = sys.argv[1:5]
entries = json.loads(raw or "[]")
alias_set = {a.strip() for a in aliases.split(",") if a.strip()} if aliases else set()
out = []
for e in entries:
    if tech and (e.get("tech") or "") != tech:
        continue
    if set_ and (e.get("set") or "") != set_:
        continue
    if alias_set and (e.get("alias") or "") not in alias_set:
        continue
    out.append(e)
print(json.dumps(out))
' "$tech" "$set_" "$aliases" "$raw"
}
