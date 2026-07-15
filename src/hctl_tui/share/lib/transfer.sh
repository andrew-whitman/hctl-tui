# Export / import bundles for matrices + hctl profile stubs.
# shellcheck shell=zsh
#
# Bundle layout:
#   <out>/
#     manifest.yaml
#     matrices/<profile>/*.yaml
#     profiles/<profile>.json   # hctl profile fields; api_key redacted unless --include-secrets
#     hctl-tui-config.yaml      # optional copy of local defaults (no secrets)
#     branch-history.yaml       # optional recent app/source branches (--with-branch-history)

hts_transfer_default_out() {
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || print now)"
  print -- "hts-export-${stamp}"
}

hts_export_bundle() {
  # usage: hts_export_bundle out_dir profile|ALL include_secrets(0|1) include_config(0|1) [include_branch_history(0|1)]
  local out="${1:?}" profile="${2:-}" include_secrets="${3:-0}" include_config="${4:-1}"
  local include_branch_history="${5:-0}"
  profile="$(hts_trim "$profile")"
  [[ -n "$profile" ]] || profile="$(hts_active_profile)"

  hts_ensure_config
  /bin/mkdir -p "$out"

  HTS_XFER_OUT="$out" \
  HTS_XFER_PROFILE="$profile" \
  HTS_XFER_MATRICES="$HTS_MATRICES_DIR" \
  HTS_XFER_HCTL="$(hts_hctl_config_path)" \
  HTS_XFER_CONFIG="$HTS_CONFIG_FILE" \
  HTS_XFER_BRANCH_HISTORY_FILE="$HTS_BRANCH_HISTORY_FILE" \
  HTS_XFER_SECRETS="$include_secrets" \
  HTS_XFER_CFG="$include_config" \
  HTS_XFER_BRANCH_HISTORY="$include_branch_history" \
  HTS_XFER_VERSION="$(
    hts_python -c 'from importlib.metadata import version
try:
  print(version("hctl-tui"))
except Exception:
  print("")' 2>/dev/null || print ""
  )" \
  hts_python <<'PY'
import json, os, shutil, sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required for export\n")
    sys.exit(1)

out = Path(os.environ["HTS_XFER_OUT"])
want = os.environ.get("HTS_XFER_PROFILE") or "default"
matrices_root = Path(os.environ["HTS_XFER_MATRICES"])
hctl_path = Path(os.environ["HTS_XFER_HCTL"])
cfg_path = Path(os.environ["HTS_XFER_CONFIG"])
bh_path = Path(os.environ.get("HTS_XFER_BRANCH_HISTORY_FILE") or "")
include_secrets = os.environ.get("HTS_XFER_SECRETS") == "1"
include_config = os.environ.get("HTS_XFER_CFG") != "0"
include_branch_history = os.environ.get("HTS_XFER_BRANCH_HISTORY") == "1"
tool_ver = os.environ.get("HTS_XFER_VERSION") or ""

profiles_to_export = []
if want.lower() in ("all", "*"):
    if matrices_root.is_dir():
        profiles_to_export = sorted(p.name for p in matrices_root.iterdir() if p.is_dir())
    # also any hctl profiles not yet listed
    if hctl_path.is_file():
        data = json.loads(hctl_path.read_text())
        for name in sorted((data.get("profiles") or {}).keys()):
            if name not in profiles_to_export:
                profiles_to_export.append(name)
else:
    profiles_to_export = [want]

if not profiles_to_export:
    sys.stderr.write("nothing to export (no matrices or profiles found)\n")
    sys.exit(1)

(out / "matrices").mkdir(parents=True, exist_ok=True)
(out / "profiles").mkdir(parents=True, exist_ok=True)

exported_matrices = []
exported_profiles = []

for name in profiles_to_export:
    src_dir = matrices_root / name
    dst_dir = out / "matrices" / name
    if src_dir.is_dir():
        dst_dir.mkdir(parents=True, exist_ok=True)
        for f in sorted(src_dir.glob("*.yaml")):
            shutil.copy2(f, dst_dir / f.name)
            exported_matrices.append(f"{name}/{f.name}")

    # hctl profile stub
    stub = {"name": name}
    if hctl_path.is_file():
        try:
            data = json.loads(hctl_path.read_text())
            prof = dict((data.get("profiles") or {}).get(name) or {})
        except Exception:
            prof = {}
        for key in ("host", "account", "org", "project", "default_org", "default_project"):
            if prof.get(key):
                stub[key] = prof[key]
        if include_secrets and prof.get("api_key"):
            stub["api_key"] = prof["api_key"]
        else:
            stub["api_key"] = ""
            stub["api_key_present"] = bool(prof.get("api_key"))
    stub_path = out / "profiles" / f"{name}.json"
    stub_path.write_text(json.dumps(stub, indent=2) + "\n")
    exported_profiles.append(name)

if include_config and cfg_path.is_file():
    shutil.copy2(cfg_path, out / "hctl-tui-config.yaml")

includes_branch_history = False
branch_history_keys = 0
if include_branch_history and bh_path.is_file():
    try:
        bh_data = yaml.safe_load(bh_path.read_text()) or {}
    except Exception:
        bh_data = {}
    if not isinstance(bh_data, dict):
        bh_data = {}
    if want.lower() not in ("all", "*"):
        prefix = f"{want}::"
        bh_data = {
            k: v
            for k, v in bh_data.items()
            if isinstance(k, str) and k.startswith(prefix)
        }
    if bh_data:
        (out / "branch-history.yaml").write_text(
            yaml.safe_dump(bh_data, default_flow_style=False, sort_keys=False)
        )
        includes_branch_history = True
        branch_history_keys = len(bh_data)

manifest = {
    "format": "hctl-tui-export",
    "format_version": 1,
    "tool_version": tool_ver or None,
    "profiles": exported_profiles,
    "matrices": exported_matrices,
    "includes_secrets": include_secrets,
    "includes_hctl_tui_config": include_config and (out / "hctl-tui-config.yaml").is_file(),
    "includes_branch_history": includes_branch_history,
}
(out / "manifest.yaml").write_text(
    yaml.safe_dump(manifest, default_flow_style=False, sort_keys=False)
)

print(f"exported {len(exported_profiles)} profile(s), {len(exported_matrices)} matrix file(s)")
if includes_branch_history:
    print(f"  + branch-history.yaml ({branch_history_keys} pipeline key(s))")
elif include_branch_history:
    print("  note: no branch history matched this export (file missing or empty for profile)")
print(f"  → {out}")
if not include_secrets:
    print("  note: api keys redacted — recipients must set their own key (hts profile init)")
PY
}

hts_import_bundle() {
  # usage: hts_import_bundle bundle_dir [target_profile] force(0|1) import_config(0|1) import_profiles(0|1) [import_branch_history(0|1)]
  # target_profile: remap single-profile bundle into this name (blank = keep names in bundle)
  local src="${1:?}" target_profile="${2:-}" force="${3:-0}" import_config="${4:-0}" import_profiles="${5:-1}"
  local import_branch_history="${6:-0}"
  src="${src%/}"
  [[ -d "$src" ]] || { hts_die "import path not a directory: $src"; return 1; }
  [[ -f "$src/manifest.yaml" || -d "$src/matrices" || -f "$src/branch-history.yaml" ]] \
    || { hts_die "not an hts export bundle (missing manifest.yaml / matrices/): $src"; return 1; }

  hts_ensure_config

  HTS_XFER_SRC="$src" \
  HTS_XFER_TARGET="$target_profile" \
  HTS_XFER_MATRICES="$HTS_MATRICES_DIR" \
  HTS_XFER_HCTL="$(hts_hctl_config_path)" \
  HTS_XFER_CONFIG="$HTS_CONFIG_FILE" \
  HTS_XFER_BRANCH_HISTORY_FILE="$HTS_BRANCH_HISTORY_FILE" \
  HTS_XFER_BRANCH_HISTORY_MAX="${HTS_BRANCH_HISTORY_MAX:-10}" \
  HTS_XFER_FORCE="$force" \
  HTS_XFER_IMPORT_CFG="$import_config" \
  HTS_XFER_IMPORT_PROFILES="$import_profiles" \
  HTS_XFER_IMPORT_BRANCH_HISTORY="$import_branch_history" \
  hts_python <<'PY'
import json, os, shutil, sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required for import\n")
    sys.exit(1)

src = Path(os.environ["HTS_XFER_SRC"])
target = (os.environ.get("HTS_XFER_TARGET") or "").strip()
matrices_root = Path(os.environ["HTS_XFER_MATRICES"])
hctl_path = Path(os.environ["HTS_XFER_HCTL"])
cfg_path = Path(os.environ["HTS_XFER_CONFIG"])
bh_dst = Path(os.environ.get("HTS_XFER_BRANCH_HISTORY_FILE") or "")
try:
    bh_max = int(os.environ.get("HTS_XFER_BRANCH_HISTORY_MAX") or "10")
except ValueError:
    bh_max = 10
force = os.environ.get("HTS_XFER_FORCE") == "1"
import_cfg = os.environ.get("HTS_XFER_IMPORT_CFG") == "1"
import_profiles = os.environ.get("HTS_XFER_IMPORT_PROFILES") != "0"
import_bh = os.environ.get("HTS_XFER_IMPORT_BRANCH_HISTORY") == "1"

manifest = {}
man_path = src / "manifest.yaml"
if man_path.is_file():
    manifest = yaml.safe_load(man_path.read_text()) or {}
    if manifest.get("format") not in (None, "hctl-tui-export"):
        sys.stderr.write(f"warn: unexpected format: {manifest.get('format')}\n")

mat_src = src / "matrices"
copied = []
skipped = []

if mat_src.is_dir():
    profile_dirs = [p for p in sorted(mat_src.iterdir()) if p.is_dir()]
    # single anonymous dump: matrices/*.yaml
    loose = list(mat_src.glob("*.yaml"))
    if loose and not profile_dirs:
        dest_name = target or "default"
        profile_dirs = []  # handle below
        dest = matrices_root / dest_name
        dest.mkdir(parents=True, exist_ok=True)
        for f in sorted(loose):
            out = dest / f.name
            if out.exists() and not force:
                skipped.append(f"{dest_name}/{f.name}")
                continue
            shutil.copy2(f, out)
            copied.append(f"{dest_name}/{f.name}")
    for pdir in profile_dirs:
        dest_name = target if (target and len(profile_dirs) == 1) else pdir.name
        if target and len(profile_dirs) > 1:
            # multi-profile bundle: target remaps only when single; otherwise keep names
            dest_name = pdir.name
        dest = matrices_root / dest_name
        dest.mkdir(parents=True, exist_ok=True)
        for f in sorted(pdir.glob("*.yaml")):
            out = dest / f.name
            if out.exists() and not force:
                skipped.append(f"{dest_name}/{f.name}")
                continue
            shutil.copy2(f, out)
            copied.append(f"{dest_name}/{f.name}")

# profiles
merged_profiles = []
created_profiles = []
if import_profiles:
    prof_dir = src / "profiles"
    stubs = []
    if prof_dir.is_dir():
        stubs = sorted(prof_dir.glob("*.json"))
    if stubs:
        if hctl_path.is_file():
            data = json.loads(hctl_path.read_text())
        else:
            data = {"current_profile": "default", "profiles": {}}
            hctl_path.parent.mkdir(parents=True, exist_ok=True)
        profiles = dict(data.get("profiles") or {})
        single = len(stubs) == 1
        for stub_path in stubs:
            stub = json.loads(stub_path.read_text())
            name = target if (target and single) else (stub.get("name") or stub_path.stem)
            incoming = {k: v for k, v in stub.items() if k not in ("name", "api_key_present") and v not in (None, "")}
            # never invent a blank api_key overwrite of existing secret unless force+explicit key
            existing = dict(profiles.get(name) or {})
            if name not in profiles:
                if "api_key" not in incoming or not incoming.get("api_key"):
                    incoming.pop("api_key", None)
                profiles[name] = incoming
                created_profiles.append(name)
            else:
                # merge non-secret fields; only set api_key if provided non-empty
                for k, v in incoming.items():
                    if k == "api_key":
                        if v:
                            existing["api_key"] = v
                        continue
                    if force or k not in existing or not existing.get(k):
                        existing[k] = v
                profiles[name] = existing
                merged_profiles.append(name)
        data["profiles"] = profiles
        if not data.get("current_profile"):
            data["current_profile"] = next(iter(profiles), "default")
        with open(hctl_path, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")

if import_cfg:
    cfg_src = src / "hctl-tui-config.yaml"
    if cfg_src.is_file():
        if cfg_path.exists() and not force:
            skipped.append("hctl-tui-config.yaml")
        else:
            shutil.copy2(cfg_src, cfg_path)
            copied.append("hctl-tui-config.yaml")

bh_merged_keys = 0
if import_bh:
    bh_src = src / "branch-history.yaml"
    if not bh_src.is_file():
        sys.stderr.write("warn: --with-branch-history set but bundle has no branch-history.yaml\n")
    elif not bh_dst:
        sys.stderr.write("warn: branch history path unset — skipping\n")
    else:
        try:
            incoming = yaml.safe_load(bh_src.read_text()) or {}
        except Exception:
            incoming = {}
        if not isinstance(incoming, dict):
            incoming = {}

        # Remap profile prefix when --as targets a single-profile history set.
        if target and incoming:
            prefixes = set()
            for k in incoming:
                if isinstance(k, str) and "::" in k:
                    prefixes.add(k.split("::", 1)[0])
            if len(prefixes) == 1:
                old = next(iter(prefixes))
                remapped = {}
                for k, v in incoming.items():
                    if isinstance(k, str) and k.startswith(old + "::"):
                        remapped[target + k[len(old):]] = v
                    else:
                        remapped[k] = v
                incoming = remapped

        existing = {}
        if bh_dst.is_file():
            try:
                existing = yaml.safe_load(bh_dst.read_text()) or {}
            except Exception:
                existing = {}
            if not isinstance(existing, dict):
                existing = {}

        def normalize_branches(raw):
            out = []
            seen = set()
            if not isinstance(raw, list):
                return out
            for b in raw:
                if not isinstance(b, str):
                    continue
                b = b.strip()
                if not b or b in seen:
                    continue
                seen.add(b)
                out.append(b)
                if len(out) >= bh_max:
                    break
            return out

        for k, v in incoming.items():
            if not isinstance(k, str) or not k.strip():
                continue
            inc = normalize_branches(v)
            if force or k not in existing:
                existing[k] = inc
            else:
                merged = []
                seen = set()
                for b in inc + normalize_branches(existing.get(k)):
                    if b in seen:
                        continue
                    seen.add(b)
                    merged.append(b)
                    if len(merged) >= bh_max:
                        break
                existing[k] = merged
            bh_merged_keys += 1

        bh_dst.parent.mkdir(parents=True, exist_ok=True)
        bh_dst.write_text(
            yaml.safe_dump(existing, default_flow_style=False, sort_keys=False)
        )
        copied.append(f"branch-history.yaml ({bh_merged_keys} key(s))")

print(f"imported {len(copied)} file(s)")
for c in copied:
    print(f"  + {c}")
if skipped:
    print(f"skipped {len(skipped)} existing (use --force to overwrite):")
    for s in skipped:
        print(f"  ~ {s}")
if created_profiles:
    print("created hctl profile stub(s): " + ", ".join(created_profiles))
    print("  set API key: hts profile init <name>   (or edit ~/.config/hctl/config.json)")
if merged_profiles:
    print("updated hctl profile field(s): " + ", ".join(merged_profiles))
if not copied and not created_profiles and not merged_profiles:
    sys.stderr.write("nothing imported\n")
    sys.exit(1)
PY
}
