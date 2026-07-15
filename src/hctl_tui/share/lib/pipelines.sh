# Matrix / pipeline CRUD for hctl-tui.
# shellcheck shell=zsh

hts_matrix_ensure() {
  local profile="${1:?}" module="${2:?}"
  local path
  path="$(hts_matrix_path "$profile" "$module")"
  /bin/mkdir -p "${path:h}"
  if [[ ! -f "$path" ]]; then
    /bin/cat >"$path" <<EOF
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
  local entries
  entries="$(hts_matrix_entries_json "$profile" "$module")"
  if [[ "$entries" == "[]" ]]; then
    print -- "(empty matrix)"
    return 0
  fi
  print -- "$entries" | hts_format_entries
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
    print("[]")
PY
}

hts_matrix_get_entry_json() {
  # usage: hts_matrix_get_entry_json profile module alias
  local profile="$1" module="$2" alias="$3"
  local entries
  entries="$(hts_matrix_entries_json "$profile" "$module")"
  HTS_MX_ENTRIES="$entries" HTS_MX_ALIAS="$alias" hts_python <<'PY'
import json, os, sys
entries = json.loads(os.environ.get("HTS_MX_ENTRIES") or "[]")
alias = os.environ.get("HTS_MX_ALIAS") or ""
for e in entries:
    if (e or {}).get("alias") == alias:
        print(json.dumps(e))
        raise SystemExit(0)
sys.stderr.write(f"no entry with alias: {alias}\n")
raise SystemExit(1)
PY
}

hts_matrix_add() {
  # optional 10th arg: type (github|custom), default github
  # optional 11th/12th: repo, connector overrides (branch is NOT stored — prompted at run)
  local profile="$1" module="$2"
  local alias="$3" trigger="$4" tech="$5" set_="$6"
  local org="$7" project="$8" identifier="$9"
  local etype="${10:-github}" repo="${11:-}" connector="${12:-}"
  local path
  path="$(hts_matrix_ensure "$profile" "$module")"
  HTS_MX_PATH="$path" \
  HTS_MX_ALIAS="$alias" \
  HTS_MX_TRIGGER="$trigger" \
  HTS_MX_TECH="$tech" \
  HTS_MX_SET="$set_" \
  HTS_MX_ORG="$org" \
  HTS_MX_PROJECT="$project" \
  HTS_MX_IDENTIFIER="$identifier" \
  HTS_MX_TYPE="$etype" \
  HTS_MX_REPO="$repo" \
  HTS_MX_CONNECTOR="$connector" \
  hts_python <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required for matrix writes (pip install pyyaml) or install mikefarah yq\n")
    sys.exit(1)

path = os.environ["HTS_MX_PATH"]
alias = os.environ.get("HTS_MX_ALIAS") or ""
trigger = os.environ.get("HTS_MX_TRIGGER") or ""
tech = os.environ.get("HTS_MX_TECH") or ""
set_ = os.environ.get("HTS_MX_SET") or ""
org = os.environ.get("HTS_MX_ORG") or ""
project = os.environ.get("HTS_MX_PROJECT") or ""
identifier = os.environ.get("HTS_MX_IDENTIFIER") or ""
etype = (os.environ.get("HTS_MX_TYPE") or "github").strip().lower()
repo = os.environ.get("HTS_MX_REPO") or ""
connector = os.environ.get("HTS_MX_CONNECTOR") or ""

if etype in ("webhook", "custom_webhook"):
    etype = "custom"
if etype not in ("github", "custom"):
    etype = "github"

data = yaml.safe_load(open(path)) or {}
entries = list(data.get("entries") or [])
entries = [e for e in entries if (e or {}).get("alias") != alias]
entry = {
    "alias": alias,
    "type": etype,
    "tech": tech,
    "set": set_,
    "pipeline": {
        "org": org,
        "project": project,
        "identifier": identifier,
    },
}
if trigger:
    entry["trigger"] = trigger
if repo:
    entry["repo"] = repo
if connector:
    entry["connector"] = connector
# branch is runtime-only — never persist
entries.append(entry)
data["module"] = data.get("module") or "ci"
data["entries"] = entries
with open(path, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
print("added/updated entry: {} (type={}) org={}/{}/{}".format(
    alias, etype, org, project, identifier))
PY
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

hts_matrix_update() {
  # Full replace of an existing entry (TUI edit). Fails if alias missing.
  # Args: profile module alias new_alias trigger tech set org project id type repo connector
  # Branch is never stored (prompted at run time); legacy branch keys are stripped.
  local profile="$1" module="$2" alias="$3"
  local path
  path="$(hts_matrix_path "$profile" "$module")"
  [[ -f "$path" ]] || { hts_die "matrix not found: $path"; return 1; }
  HTS_MX_PATH="$path" \
  HTS_MX_ALIAS="$alias" \
  HTS_MX_NEW_ALIAS="${4:-}" \
  HTS_MX_TRIGGER="${5:-}" \
  HTS_MX_TECH="${6:-}" \
  HTS_MX_SET="${7:-}" \
  HTS_MX_ORG="${8:-}" \
  HTS_MX_PROJECT="${9:-}" \
  HTS_MX_IDENTIFIER="${10:-}" \
  HTS_MX_TYPE="${11:-github}" \
  HTS_MX_REPO="${12:-}" \
  HTS_MX_CONNECTOR="${13:-}" \
  hts_python <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required for matrix writes\n")
    sys.exit(1)

path = os.environ["HTS_MX_PATH"]
alias = os.environ.get("HTS_MX_ALIAS") or ""
new_alias = (os.environ.get("HTS_MX_NEW_ALIAS") or "").strip() or alias

data = yaml.safe_load(open(path)) or {}
entries = list(data.get("entries") or [])
idx = next((i for i, e in enumerate(entries) if (e or {}).get("alias") == alias), None)
if idx is None:
    sys.stderr.write(f"no entry with alias: {alias}\n")
    sys.exit(1)
if new_alias != alias and any((e or {}).get("alias") == new_alias for e in entries):
    sys.stderr.write(f"alias already exists: {new_alias}\n")
    sys.exit(1)

etype = (os.environ.get("HTS_MX_TYPE") or "github").strip().lower()
if etype in ("webhook", "custom_webhook"):
    etype = "custom"
if etype not in ("github", "custom"):
    etype = "github"

entry = {
    "alias": new_alias,
    "type": etype,
    "tech": os.environ.get("HTS_MX_TECH") or "java",
    "set": os.environ.get("HTS_MX_SET") or "shared",
    "pipeline": {
        "org": os.environ.get("HTS_MX_ORG") or "",
        "project": os.environ.get("HTS_MX_PROJECT") or "",
        "identifier": os.environ.get("HTS_MX_IDENTIFIER") or "",
    },
}
trigger = os.environ.get("HTS_MX_TRIGGER") or ""
repo = os.environ.get("HTS_MX_REPO") or ""
connector = os.environ.get("HTS_MX_CONNECTOR") or ""
if trigger:
    entry["trigger"] = trigger
if repo:
    entry["repo"] = repo
if connector:
    entry["connector"] = connector

entries[idx] = entry
data["entries"] = entries
with open(path, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
p = entry["pipeline"]
suffix = f" → {new_alias}" if new_alias != alias else ""
print("updated entry: {}{} org={}/{}/{}".format(
    alias, suffix, p.get("org"), p.get("project"), p.get("identifier")))
PY
}

hts_matrix_patch() {
  # Partial update for CLI: only fields with HTS_MX_PATCH_<NAME>=1 are applied.
  local profile="$1" module="$2" alias="$3"
  local path
  path="$(hts_matrix_path "$profile" "$module")"
  [[ -f "$path" ]] || { hts_die "matrix not found: $path"; return 1; }
  HTS_MX_PATH="$path" HTS_MX_ALIAS="$alias" hts_python <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required for matrix writes\n")
    sys.exit(1)

path = os.environ["HTS_MX_PATH"]
alias = os.environ.get("HTS_MX_ALIAS") or ""
new_alias = (os.environ.get("HTS_MX_NEW_ALIAS") or "").strip()

data = yaml.safe_load(open(path)) or {}
entries = list(data.get("entries") or [])
idx = next((i for i, e in enumerate(entries) if (e or {}).get("alias") == alias), None)
if idx is None:
    sys.stderr.write(f"no entry with alias: {alias}\n")
    sys.exit(1)

entry = dict(entries[idx] or {})
pipe = dict(entry.get("pipeline") or {})

def patching(key):
    return os.environ.get("HTS_MX_PATCH_" + key) == "1"

if new_alias:
    if new_alias != alias and any((e or {}).get("alias") == new_alias for e in entries):
        sys.stderr.write(f"alias already exists: {new_alias}\n")
        sys.exit(1)
    entry["alias"] = new_alias

if patching("TYPE"):
    etype = (os.environ.get("HTS_MX_TYPE") or "github").strip().lower()
    if etype in ("webhook", "custom_webhook"):
        etype = "custom"
    if etype not in ("github", "custom"):
        etype = "github"
    entry["type"] = etype
if patching("TECH"):
    entry["tech"] = os.environ.get("HTS_MX_TECH") or ""
if patching("SET"):
    entry["set"] = os.environ.get("HTS_MX_SET") or ""
if patching("ORG"):
    pipe["org"] = os.environ.get("HTS_MX_ORG") or ""
if patching("PROJECT"):
    pipe["project"] = os.environ.get("HTS_MX_PROJECT") or ""
if patching("IDENTIFIER"):
    pipe["identifier"] = os.environ.get("HTS_MX_IDENTIFIER") or ""
if patching("TRIGGER"):
    v = os.environ.get("HTS_MX_TRIGGER") or ""
    if v:
        entry["trigger"] = v
    else:
        entry.pop("trigger", None)
if patching("REPO"):
    v = os.environ.get("HTS_MX_REPO") or ""
    if v:
        entry["repo"] = v
    else:
        entry.pop("repo", None)
if patching("CONNECTOR"):
    v = os.environ.get("HTS_MX_CONNECTOR") or ""
    if v:
        entry["connector"] = v
    else:
        entry.pop("connector", None)

# Branch is runtime-only — always strip legacy persisted branch keys
entry.pop("branch", None)

entry["pipeline"] = pipe
entries[idx] = entry
data["entries"] = entries
with open(path, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
p = entry.get("pipeline") or {}
suffix = f" → {entry.get('alias')}" if entry.get("alias") != alias else ""
print("updated entry: {}{} org={}/{}/{}".format(
    alias, suffix, p.get("org"), p.get("project"), p.get("identifier")))
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
