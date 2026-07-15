# Matrix runner: filter + fire pipelines (GitHub-style execute or custom webhooks).
# shellcheck shell=zsh

# Discover a usable hctl op for custom webhooks (cached in-process).
# Real custom fires prefer curl; hctl op is optional/dry-run only.
typeset -g HTS_WEBHOOK_OP=""

hts_discover_webhook_op() {
  [[ -n "$HTS_WEBHOOK_OP" ]] && return 0
  hts_have hctl || return 1
  local hits
  hits="$(hts_hctl api list --search 'webhook custom' 2>/dev/null || true)"
  local op
  op="$(print -- "$hits" | hts_cmd awk '/custom.*webhook|webhook.*custom|trigger.*webhook/ {print $1; exit}' || true)"
  if [[ -z "$op" ]]; then
    hits="$(hts_hctl api list --search webhook 2>/dev/null || true)"
    op="$(print -- "$hits" | hts_cmd awk 'NR>1 {print $1; exit}' || true)"
  fi
  HTS_WEBHOOK_OP="$op"
  [[ -n "$HTS_WEBHOOK_OP" ]]
}

hts_urlencode() {
  hts_python -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

hts_module_type() {
  # Map matrix module name → Harness moduleType query value
  local m="${1:l}"
  case "$m" in
    ci|build) print CI ;;
    cd|deploy*) print CD ;;
    *) print "${1:u}" ;;
  esac
}

hts_entry_type() {
  # github (pipeline execute) | custom (custom webhook). Default: github.
  local t="${1:l}"
  case "$t" in
    custom|webhook|custom_webhook) print custom ;;
    github|execute|pipeline|""|*) print github ;;
  esac
}

hts_trigger_status() {
  hts_python -c '
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print("ERROR")
    raise SystemExit(0)
st = d.get("status")
if st:
    print(st)
    raise SystemExit(0)
# execute responses sometimes omit top-level status when planExecution is present
data = d.get("data") or {}
if data.get("planExecution") or data.get("planExecutionId"):
    print("SUCCESS")
else:
    print("ERROR")
' 2>/dev/null || print ERROR
}

hts_trigger_message() {
  hts_python -c '
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print((raw or "")[:200])
    raise SystemExit(0)
msg = d.get("message") or d.get("error") or ""
if not msg and isinstance(d.get("data"), dict):
    msg = d["data"].get("message") or ""
errs = d.get("responseMessages") or d.get("errors") or []
if not msg and isinstance(errs, list) and errs:
    e0 = errs[0]
    if isinstance(e0, dict):
        msg = e0.get("message") or e0.get("code") or str(e0)
    else:
        msg = str(e0)
print(msg or "")
' 2>/dev/null || true
}

hts_trigger_ui_url() {
  # Args (optional): host account org project pipeline
  local host="${1:-}" account="${2:-}" org="${3:-}" project="${4:-}" pipeline="${5:-}"
  HTS_UI_HOST="$host" HTS_UI_ACCOUNT="$account" HTS_UI_ORG="$org" \
    HTS_UI_PROJECT="$project" HTS_UI_PIPELINE="$pipeline" \
    hts_python -c '
import json, os, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
data = d.get("data") if isinstance(d.get("data"), dict) else {}
for key in ("uiUrl", "ui_url"):
    if d.get(key):
        print(d[key]); raise SystemExit(0)
    if data.get(key):
        print(data[key]); raise SystemExit(0)
pe = data.get("planExecution") if isinstance(data.get("planExecution"), dict) else {}
ex_id = pe.get("uuid") or data.get("planExecutionId") or data.get("executionId") or ""
host = (os.environ.get("HTS_UI_HOST") or "https://app.harness.io").rstrip("/")
acct = os.environ.get("HTS_UI_ACCOUNT") or ""
org = os.environ.get("HTS_UI_ORG") or ""
proj = os.environ.get("HTS_UI_PROJECT") or ""
pipe = os.environ.get("HTS_UI_PIPELINE") or ""
if ex_id and acct and org and proj and pipe:
    print("{}/ng/account/{}/home/orgs/{}/projects/{}/pipelines/{}/executions/{}/pipeline".format(
        host, acct, org, proj, pipe, ex_id))
else:
    print("")
' 2>/dev/null || true
}

hts_fire_custom_trigger() {
  # Args: profile org project pipeline_id trigger_id dry_run(0|1)
  local profile="$1" org="$2" project="$3" pipeline_id="$4" trigger_id="$5" dry_run="${6:-0}"
  local host account api_key
  host="$(hts_hctl_profile_field "$profile" host)"
  account="$(hts_hctl_profile_field "$profile" account)"
  api_key="$(hts_hctl_profile_field "$profile" api_key)"
  host="${host:-https://app.harness.io}"
  host="${host%/}"
  host="${host%/gateway}"

  org="$(hts_trim "$org")"
  project="$(hts_trim "$project")"
  pipeline_id="$(hts_trim "$pipeline_id")"
  trigger_id="$(hts_trim "$trigger_id")"
  account="$(hts_trim "$account")"

  if [[ -z "$account" ]]; then
    if [[ "$dry_run" == "1" ]]; then
      account="ACCOUNT"
      hts_log "warn: profile '$profile' has no account (dry-run placeholder)"
    else
      hts_err "profile '$profile' has no account — run: hctl init --profile $profile"
      return 1
    fi
  fi
  if [[ "$dry_run" != "1" && -z "$api_key" && -z "${HARNESS_API_KEY:-}" ]]; then
    hts_err "no API key for profile '$profile' (set in hctl or HARNESS_API_KEY)"
    return 1
  fi
  api_key="${api_key:-${HARNESS_API_KEY:-}}"

  local url
  url="${host}/gateway/pipeline/api/webhook/custom/v2?accountIdentifier=$(hts_urlencode "$account")&orgIdentifier=$(hts_urlencode "$org")&projectIdentifier=$(hts_urlencode "$project")&pipelineIdentifier=$(hts_urlencode "$pipeline_id")&triggerIdentifier=$(hts_urlencode "$trigger_id")"

  if [[ "$dry_run" == "1" ]]; then
    print -u2 -- "DRY-RUN POST (custom webhook) $url"
    print -u2 -- "  account=$account host=$host"
    print -u2 -- "  headers: content-type: application/json, X-Api-Key: ***"
    print -u2 -- "  body: {}"
    return 0
  fi

  local resp http_code=0 curl_ec=0
  resp="$(
    hts_curl -sS -X POST \
      -H 'content-type: application/json' \
      -H "X-Api-Key: ${api_key}" \
      --url "$url" \
      -d '{}' \
      -w $'\n%{http_code}'
  )" || curl_ec=$?

  if (( curl_ec != 0 )); then
    hts_err "curl failed (exit $curl_ec) posting custom trigger"
    return 1
  fi

  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  if [[ -z "$resp" ]]; then
    hts_err "empty response from Harness (HTTP ${http_code:-?})"
    return 1
  fi

  print -- "$resp"
  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    hts_err "Harness auth failed (HTTP $http_code) — check api_key on profile '$profile'"
  fi
  return 0
}

# Resolve trigger inputYaml / inputSetRefs for pipeline execute.
# Args: trigger_json_file branch repo connector body_out_file
# stdout: JSON {branch,repo,connector,has_body,input_set_refs,warnings[]}
# Writes resolved YAML body to body_out_file when inputYaml is present.
hts_resolve_trigger_input_yaml() {
  local trig_file="$1" branch="${2:-}" repo="${3:-}" connector="${4:-}" body_file="${5:-}"
  HTS_TRIG_FILE="$trig_file" HTS_BRANCH="$branch" HTS_REPO="$repo" \
  HTS_CONNECTOR="$connector" HTS_BODY_FILE="$body_file" \
    hts_python <<'PY'
import json, os, re, sys

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required to resolve trigger inputYaml\n")
    sys.exit(1)

branch = (os.environ.get("HTS_BRANCH") or "").strip()
repo_ov = (os.environ.get("HTS_REPO") or "").strip()
conn_ov = (os.environ.get("HTS_CONNECTOR") or "").strip()
body_file = (os.environ.get("HTS_BODY_FILE") or "").strip()
trig_file = (os.environ.get("HTS_TRIG_FILE") or "").strip()
warnings = []

try:
    with open(trig_file, "rb") as f:
        raw_bytes = f.read()
except Exception as e:
    sys.stderr.write(f"cannot read get-trigger response: {e}\n")
    sys.exit(1)

# Strip UTF-8 BOM / leading junk; decode leniently.
if raw_bytes.startswith(b"\xef\xbb\xbf"):
    raw_bytes = raw_bytes[3:]
raw = raw_bytes.decode("utf-8", errors="replace").strip()
if not raw:
    sys.stderr.write(
        "empty get-trigger file — hctl wrote no payload (auth, trigger id, or pipeline id?)\n"
    )
    sys.exit(1)
# Drop any non-JSON preamble (banners, log lines) before first { or [
for i, ch in enumerate(raw):
    if ch in "{[":
        raw = raw[i:]
        break
else:
    # no JSON object/array start — might still be YAML
    pass

def repair_json_control_chars(s):
    """Escape raw control chars inside JSON strings (Harness/hctl sometimes emit these)."""
    out = []
    in_string = False
    escape = False
    for ch in s:
        o = ord(ch)
        if not in_string:
            if ch == '"':
                in_string = True
            out.append(ch)
            continue
        if escape:
            out.append(ch)
            escape = False
            continue
        if ch == "\\":
            out.append(ch)
            escape = True
            continue
        if ch == '"':
            in_string = False
            out.append(ch)
            continue
        if o < 32:
            if ch == "\n":
                out.append("\\n")
            elif ch == "\r":
                out.append("\\r")
            elif ch == "\t":
                out.append("\\t")
            else:
                out.append("\\u%04x" % o)
            continue
        out.append(ch)
    return "".join(out)

def loads_trigger_payload(s):
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        pass
    try:
        return json.loads(repair_json_control_chars(s))
    except json.JSONDecodeError:
        pass
    # Some hctl builds return YAML (or YAML-wrapped) for this op
    try:
        loaded = yaml.safe_load(s)
        if isinstance(loaded, (dict, list)):
            return loaded
    except Exception:
        pass
    return None

resp = loads_trigger_payload(raw)
if resp is None:
    preview = raw[:240].replace("\n", "\\n")
    sys.stderr.write(
        "invalid get-trigger payload (not JSON/YAML). first bytes: %r\n" % (preview,)
    )
    sys.exit(1)

data = resp.get("data") if isinstance(resp, dict) else None
if not isinstance(data, dict):
    data = resp if isinstance(resp, dict) else {}

trigger_obj = None
yaml_str = data.get("yaml") if isinstance(data.get("yaml"), str) else None
if not yaml_str and isinstance(data.get("trigger"), dict):
    # some payloads nest under data.trigger
    t = data["trigger"]
    yaml_str = t.get("yaml") if isinstance(t.get("yaml"), str) else None
    if yaml_str is None:
        trigger_obj = t

if yaml_str:
    try:
        loaded = yaml.safe_load(yaml_str)
    except Exception as e:
        sys.stderr.write(f"failed to parse trigger yaml: {e}\n")
        sys.exit(1)
    if isinstance(loaded, dict) and isinstance(loaded.get("trigger"), dict):
        trigger_obj = loaded["trigger"]
    elif isinstance(loaded, dict):
        trigger_obj = loaded
elif trigger_obj is None and isinstance(data, dict):
    # Already-unwrapped trigger fields on data
    if data.get("inputYaml") is not None or data.get("source") is not None:
        trigger_obj = data

if not isinstance(trigger_obj, dict):
    sys.stderr.write("get-trigger response missing trigger yaml/object\n")
    sys.exit(1)

def dig_webhook_leaf(src):
    """Walk source.spec... to the Github/Gitlab leaf with connectorRef/repoName."""
    if not isinstance(src, dict):
        return {}
    node = src
    # source -> spec (Webhook) -> spec (Github) -> spec (Push/PR) -> spec (leaf)
    for _ in range(5):
        if not isinstance(node, dict):
            return {}
        if node.get("connectorRef") or node.get("repoName") or node.get("repo"):
            return node
        nxt = node.get("spec")
        if isinstance(nxt, dict):
            node = nxt
            continue
        break
    return node if isinstance(node, dict) else {}

leaf = dig_webhook_leaf(trigger_obj.get("source") or {})
repo = repo_ov or str(leaf.get("repoName") or leaf.get("repo") or "").strip()
connector = conn_ov or str(leaf.get("connectorRef") or "").strip()

# pipelineBranchName on trigger (Git Experience) often is <+trigger.branch>
pbn = trigger_obj.get("pipelineBranchName") or trigger_obj.get("pipeline_branch_name") or ""
if isinstance(pbn, str) and pbn.strip() and "<+" not in pbn and not branch:
    branch = pbn.strip()

input_yaml = trigger_obj.get("inputYaml")
if input_yaml is None:
    input_yaml = trigger_obj.get("input_yaml")
if input_yaml is None:
    input_yaml = ""
if not isinstance(input_yaml, str):
    # sometimes structured
    try:
        input_yaml = yaml.safe_dump(input_yaml, default_flow_style=False, sort_keys=False)
    except Exception:
        input_yaml = str(input_yaml)
input_yaml = input_yaml.strip()

def normalize_input_set_refs(refs):
    """Return comma-separated input set identifiers from trigger inputSetRefs."""
    if refs is None:
        return ""
    if isinstance(refs, str):
        s = refs.strip()
        if not s or "<+" in s:
            # expression-only refs can't be resolved without a webhook payload
            if s and "<+" in s:
                warnings.append("inputSetRefs is an expression; set input_set: on the matrix entry or use inline inputYaml")
            return ""
        # allow comma/space separated already
        parts = [p.strip() for p in s.replace(";", ",").split(",") if p.strip()]
        return ",".join(parts)
    if isinstance(refs, (list, tuple)):
        parts = []
        for item in refs:
            if item is None:
                continue
            if isinstance(item, dict):
                # rare: {identifier: x} shapes
                v = item.get("identifier") or item.get("name") or item.get("ref") or ""
            else:
                v = str(item).strip()
            if v and "<+" not in v:
                parts.append(v)
            elif v and "<+" in v:
                warnings.append("skipping expression inputSetRef: %s" % v)
        return ",".join(parts)
    return ""

trigger_input_sets = normalize_input_set_refs(
    trigger_obj.get("inputSetRefs")
    if trigger_obj.get("inputSetRefs") is not None
    else trigger_obj.get("input_set_refs")
)

EXPR_RE = re.compile(r"<\+\s*trigger\.([A-Za-z0-9_.'\[\]-]+)\s*>")

def expr_value(path):
    p = path.strip()
    # Common webhook aliases → matrix branch
    if p in (
        "branch", "sourceBranch", "targetBranch",
        "payload.pull_request.head.ref", "payload.pull_request.base.ref",
        "payload.ref",
    ):
        return branch or None
    if p in ("repoName", "repo", "payload.repository.name"):
        return repo or None
    if p in ("connectorRef", "connector"):
        return connector or None
    # PR number has no meaning after PR→branch conversion
    if p in ("prNumber", "pull_request.number", "payload.pull_request.number"):
        return ""
    return None

def replace_exprs(text):
    def repl(m):
        path = m.group(1)
        val = expr_value(path)
        if val is None:
            warnings.append(f"unresolved expression: <+trigger.{path}>")
            return m.group(0)
        return val
    return EXPR_RE.sub(repl, text)

def convert_pr_build(node):
    """Convert codebase build type PR/PullRequest → branch."""
    if isinstance(node, list):
        for item in node:
            convert_pr_build(item)
        return
    if not isinstance(node, dict):
        return
    build = node.get("build")
    if isinstance(build, dict):
        btype = str(build.get("type") or "").strip().lower()
        if btype in ("pr", "pullrequest", "pull_request"):
            if not branch:
                warnings.append("PR build type found but no branch set — pass a branch at run time")
            build.clear()
            build["type"] = "branch"
            build["spec"] = {"branch": branch or "<+trigger.branch>"}
    for v in node.values():
        convert_pr_build(v)

resolved_text = replace_exprs(input_yaml)
has_body = bool(resolved_text.strip())
if has_body:
    try:
        parsed = yaml.safe_load(resolved_text)
    except Exception as e:
        sys.stderr.write(f"failed to parse inputYaml after expression replace: {e}\n")
        sys.exit(1)
    if parsed is not None:
        convert_pr_build(parsed)
        # Second pass: expressions inside converted tree (e.g. leftover)
        dumped = yaml.safe_dump(parsed, default_flow_style=False, sort_keys=False)
        resolved_text = replace_exprs(dumped)
        # Prefer concrete branch from yaml if still unset
        if not branch and isinstance(parsed, dict):
            try:
                b = (
                    parsed.get("pipeline", {})
                    .get("properties", {})
                    .get("ci", {})
                    .get("codebase", {})
                    .get("build", {})
                    .get("spec", {})
                    .get("branch")
                )
                if isinstance(b, str) and b.strip() and "<+" not in b:
                    branch = b.strip()
            except Exception:
                pass

# Final check for leftover <+trigger.*>
leftover = EXPR_RE.findall(resolved_text or "")
for path in leftover:
    w = f"unresolved expression: <+trigger.{path}>"
    if w not in warnings:
        warnings.append(w)

if body_file and has_body:
    with open(body_file, "w") as f:
        f.write(resolved_text if resolved_text.endswith("\n") else resolved_text + "\n")

out = {
    "branch": branch,
    "repo": repo,
    "connector": connector,
    "has_body": has_body,
    "input_set_refs": trigger_input_sets if not has_body else "",
    "warnings": warnings,
}
print(json.dumps(out))
PY
}

hts_fetch_trigger_json() {
  # Args: profile account org project pipeline_id trigger_id [out_file]
  # Writes get-trigger payload to out_file (or stdout if omitted).
  # Prefer --output-file so zsh `print` never mangles JSON escapes (\c, \n, …).
  local profile="$1" account="$2" org="$3" project="$4" pipeline_id="$5" trigger_id="$6"
  local out_file="${7:-}"
  local hctl_bin errfile outfile ec=0
  hctl_bin="$(hts_hctl_bin)" || return 1
  errfile="$(hts_mktemp hts-get-trigger-err)" || return 1
  if [[ -n "$out_file" ]]; then
    outfile="$out_file"
    : >"$outfile"
  else
    outfile="$(hts_mktemp hts-get-trigger-out)" || {
      hts_rm -f "$errfile"
      return 1
    }
  fi

  "$hctl_bin" --profile "$profile" triggers get-trigger \
    --account-identifier "$account" \
    --org-identifier "$org" \
    --project-identifier "$project" \
    --target-identifier "$pipeline_id" \
    --trigger-identifier "$trigger_id" \
    --output json \
    --output-file "$outfile" \
    >/dev/null 2>"$errfile" || ec=$?

  local err=""
  err="$(/bin/cat "$errfile" 2>/dev/null || true)"
  hts_rm -f "$errfile"

  # hctl sometimes exits 0 on transport errors while writing nothing
  if (( ec != 0 )) || [[ ! -s "$outfile" ]]; then
    hts_err "hctl triggers get-trigger failed for trigger=$trigger_id pipeline=$org/$project/$pipeline_id (exit=$ec)"
    [[ -n "$err" ]] && hts_err "  $err"
    if [[ -s "$outfile" ]]; then
      hts_err "  partial output: $(/bin/head -c 200 "$outfile" | tr '\n' ' ')"
    else
      hts_err "  (empty response — check trigger id, pipeline id, and hctl profile auth)"
    fi
    [[ -z "$out_file" ]] && hts_rm -f "$outfile"
    return 1
  fi

  if [[ -z "$out_file" ]]; then
    /bin/cat "$outfile"
    hts_rm -f "$outfile"
  fi
  return 0
}

hts_fire_pipeline_execute() {
  # Args: profile org project pipeline_id module dry_run
  #        [trigger_id] [branch] [repo] [connector] [input_set]
  # Fetches GitHub/webhook trigger config, resolves inputYaml / <+trigger.*>,
  # converts PR build → branch, then executes via
  # hctl pipeline-execute post-pipeline-execute-with-input-set-yaml --body @file
  local profile="$1" org="$2" project="$3" pipeline_id="$4" module="$5" dry_run="${6:-0}"
  local trigger_id="${7:-}" branch="${8:-}" repo="${9:-}" connector="${10:-}" input_set="${11:-}"
  local account
  account="$(hts_hctl_profile_field "$profile" account)"

  org="$(hts_trim "$org")"
  project="$(hts_trim "$project")"
  pipeline_id="$(hts_trim "$pipeline_id")"
  account="$(hts_trim "$account")"
  trigger_id="$(hts_trim "$trigger_id")"
  branch="$(hts_trim "$branch")"
  repo="$(hts_trim "$repo")"
  connector="$(hts_trim "$connector")"
  input_set="$(hts_trim "$input_set")"
  : "$module"

  local hctl_bin
  hctl_bin="$(hts_hctl_bin)" || {
    hts_err "hctl is required — run: hts init   (expected in ~/.local/bin)"
    return 1
  }

  if [[ -z "$account" ]]; then
    if [[ "$dry_run" == "1" ]]; then
      account="ACCOUNT"
      hts_log "warn: profile '$profile' has no account (dry-run placeholder)"
    else
      hts_err "profile '$profile' has no account — run: hctl init --profile $profile"
      return 1
    fi
  fi

  local body_file="" has_body=0 resolved_meta=""
  local trig_file=""

  if [[ -n "$trigger_id" ]]; then
    if [[ "$dry_run" == "1" && "$account" == "ACCOUNT" ]]; then
      print -u2 -- "DRY-RUN would: hctl triggers get-trigger --trigger-identifier $trigger_id --target-identifier $pipeline_id"
    else
      trig_file="$(hts_mktemp hts-trigger)" || {
        hts_err "could not create temp trigger file"
        return 1
      }
      hts_fetch_trigger_json "$profile" "$account" "$org" "$project" "$pipeline_id" "$trigger_id" "$trig_file" || {
        hts_rm -f "$trig_file"
        return 1
      }
      body_file="$(hts_mktemp hts-body)" || {
        hts_err "could not create temp body file"
        hts_rm -f "$trig_file"
        return 1
      }
      resolved_meta="$(
        hts_resolve_trigger_input_yaml "$trig_file" "$branch" "$repo" "$connector" "$body_file"
      )" || {
        local ec=$?
        hts_rm -f "$trig_file" "$body_file"
        return $ec
      }
      hts_rm -f "$trig_file"
      branch="$(print -- "$resolved_meta" | hts_python -c 'import json,sys; print(json.load(sys.stdin).get("branch") or "")')"
      repo="$(print -- "$resolved_meta" | hts_python -c 'import json,sys; print(json.load(sys.stdin).get("repo") or "")')"
      connector="$(print -- "$resolved_meta" | hts_python -c 'import json,sys; print(json.load(sys.stdin).get("connector") or "")')"
      has_body="$(print -- "$resolved_meta" | hts_python -c 'import json,sys; print(1 if json.load(sys.stdin).get("has_body") else 0)')"
      # Fallback: trigger inputSetRefs when there is no inline inputYaml
      local trigger_input_sets=""
      trigger_input_sets="$(print -- "$resolved_meta" | hts_python -c 'import json,sys; print(json.load(sys.stdin).get("input_set_refs") or "")')"
      if [[ -z "$input_set" && -n "$trigger_input_sets" ]]; then
        input_set="$trigger_input_sets"
      fi
      print -- "$resolved_meta" | hts_python -c '
import json,sys
for w in json.load(sys.stdin).get("warnings") or []:
    print(w)
' 2>/dev/null | while IFS= read -r w; do
        [[ -n "$w" ]] && hts_log "warn: $w"
      done
      if [[ "$has_body" != "1" ]]; then
        hts_rm -f "$body_file"
        body_file=""
        if [[ -z "$input_set" ]]; then
          hts_log "warn: trigger=$trigger_id has no inputYaml or inputSetRefs — execute will use pipeline defaults only"
        fi
      fi
    fi
  fi

  # moduleType omitted intentionally (wrong CI/CD → NOT_FOUND).
  local -a cmd=(
    "$hctl_bin" --profile "$profile"
    pipeline-execute post-pipeline-execute-with-input-set-yaml
    --account-identifier "$account"
    --org-identifier "$org"
    --project-identifier "$project"
    --identifier "$pipeline_id"
    --output json
  )
  [[ -n "$branch" ]] && cmd+=(--branch "$branch")
  [[ -n "$repo" ]] && cmd+=(--repo-identifier "$repo")
  [[ -n "$connector" ]] && cmd+=(--query "connectorRef=$connector")
  # Prefer resolved trigger inputYaml body; else inputSetRefs / matrix input_set.
  if [[ -n "$body_file" ]]; then
    cmd+=(--content-type application/yaml --body "@${body_file}")
  elif [[ -n "$input_set" ]]; then
    cmd+=(--input-set-identifiers "$input_set")
  fi

  if [[ "$dry_run" == "1" ]]; then
    print -u2 -- "DRY-RUN hctl pipeline-execute post-pipeline-execute-with-input-set-yaml"
    print -u2 -- "  profile=$profile account=$account"
    print -u2 -- "  org=$org project=$project pipeline=$pipeline_id"
    [[ -n "$trigger_id" ]] && print -u2 -- "  trigger=$trigger_id (get-trigger → inputYaml|inputSetRefs)"
    if [[ -n "$body_file" ]]; then
      print -u2 -- "  inputs=inputYaml (--body @file)"
    elif [[ -n "$input_set" ]]; then
      print -u2 -- "  inputs=inputSetRefs/input_set ($input_set)"
    else
      print -u2 -- "  inputs=(none)"
    fi
    [[ -n "$branch" ]] && print -u2 -- "  branch=$branch" || print -u2 -- "  branch=(none — set for git-backed pipelines)"
    [[ -n "$repo" ]] && print -u2 -- "  repo=$repo"
    [[ -n "$connector" ]] && print -u2 -- "  connector=$connector"
    if [[ -n "$body_file" && -f "$body_file" ]]; then
      print -u2 -- "  body @${body_file}:"
      /bin/sed 's/^/    /' "$body_file" 1>&2 || true
    fi
    "${cmd[@]}" --dry-run --curl 1>&2 || true
    hts_rm -f "$body_file"
    return 0
  fi

  local resp ec=0 errfile
  errfile="$(hts_mktemp hts-hctl)" || {
    hts_err "could not create temp file"
    hts_rm -f "$body_file"
    return 1
  }
  resp="$("${cmd[@]}" 2>"$errfile")" || ec=$?
  hts_rm -f "$body_file"
  if (( ec != 0 )); then
    local err msg=""
    err="$(/bin/cat "$errfile" 2>/dev/null || true)"
    hts_rm -f "$errfile"
    if [[ -n "$resp" ]]; then
      print -- "$resp"
      msg="$(print -- "$resp" | hts_trigger_message)"
    fi
    [[ -z "$msg" && -n "$err" ]] && msg="$err"
    hts_err "hctl execute failed for account=$account org=$org project=$project pipeline=$pipeline_id${branch:+ branch=$branch}"
    [[ -n "$msg" ]] && hts_err "  $msg"
    if [[ "$msg" == *404* || "$msg" == *NOT_FOUND* || "$msg" == *"not found"* ]]; then
      hts_err "  hint: confirm org/project/pipeline ids match the Harness URL"
      if [[ -z "$branch" ]]; then
        hts_err "  hint: git-backed pipelines need a branch — you will be prompted at run time (or pass --branch)"
      fi
      if [[ -z "$trigger_id" ]]; then
        hts_err "  hint: set trigger: to a GitHub webhook trigger id so hts can resolve inputYaml"
      fi
    fi
    return 1
  fi
  hts_rm -f "$errfile"

  if [[ -z "$resp" ]]; then
    hts_err "empty response from hctl pipeline-execute"
    return 1
  fi
  print -- "$resp"
  return 0
}

hts_fire_entry() {
  # Args: profile module type org project pipeline_id trigger dry_run
  #       [branch] [repo] [connector] [input_set]
  local profile="$1" module="$2" etype="$3" org="$4" project="$5" pipeline_id="$6"
  local trigger="$7" dry_run="${8:-0}" branch="${9:-}" repo="${10:-}" connector="${11:-}" input_set="${12:-}"
  etype="$(hts_entry_type "$etype")"
  case "$etype" in
    custom)
      hts_fire_custom_trigger "$profile" "$org" "$project" "$pipeline_id" "$trigger" "$dry_run"
      ;;
    *)
      hts_fire_pipeline_execute "$profile" "$org" "$project" "$pipeline_id" "$module" "$dry_run" \
        "$trigger" "$branch" "$repo" "$connector" "$input_set"
      ;;
  esac
}

hts_prompt_run_branch() {
  # Prompt for a git branch at run time (per pipeline).
  # usage: hts_prompt_run_branch alias org project pipeline_id [default]
  local alias="$1" org="$2" project="$3" pipeline_id="$4" default="${5:-}"
  local val="" label
  label="Branch for ${alias} (${org}/${project}/${pipeline_id})"
  if [[ -n "$default" ]]; then
    label="${label} [${default}]"
  fi
  while true; do
    print -n -- "${label}: " >/dev/tty 2>/dev/null || print -n -- "${label}: "
    if ! IFS= read -r val </dev/tty 2>/dev/null; then
      # no tty — caller should have required --branch
      print -- "$default"
      return 0
    fi
    val="$(hts_trim "$val")"
    if [[ -z "$val" && -n "$default" ]]; then
      print -- "$default"
      return 0
    fi
    if [[ -n "$val" ]]; then
      print -- "$val"
      return 0
    fi
    print -- "(required)" >/dev/tty 2>/dev/null || print -- "(required)"
  done
}

hts_run_matrix() {
  # usage: hts_run_matrix profile module tech set aliases dry_run open_urls [cli_branch]
  # cli_branch: optional same branch for every github entry (hts run --branch).
  # Otherwise prompts per github pipeline when a TTY is available.
  local profile="$1" module="$2" tech="${3:-}" set_="${4:-}" aliases="${5:-}" dry_run="${6:-0}" open_urls="${7:-0}"
  local cli_branch="${8:-}"
  cli_branch="$(hts_trim "$cli_branch")"

  if [[ "$dry_run" != "1" ]] && ! hts_hctl_profile_exists "$profile"; then
    hts_die "hctl profile not found: $profile"
    return 1
  fi

  local path
  path="$(hts_matrix_path "$profile" "$module")"
  if [[ ! -f "$path" ]]; then
    hts_die "no matrix at $path — add entries with: hts matrix add --module $module ..."
    return 1
  fi

  local entries filtered
  entries="$(hts_matrix_entries_json "$profile" "$module")"
  filtered="$(print -- "$entries" | hts_matrix_filter "$tech" "$set_" "$aliases")"

  local count
  count="$(print -- "$filtered" | hts_python -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  if [[ "$count" == "0" ]]; then
    local total
    total="$(print -- "$entries" | hts_python -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || print 0)"
    if [[ "$total" == "0" ]]; then
      hts_log "matrix is empty for profile=$profile module=$module — add entries with: hts matrix add --module $module ..."
    else
      hts_log "no entries matched filters (tech=${tech:-*} set=${set_:-*} alias=${aliases:-*})"
    fi
    return 1
  fi

  if [[ "$dry_run" != "1" ]]; then
    local ak
    ak="$(hts_hctl_profile_field "$profile" api_key)"
    ak="${ak:-${HARNESS_API_KEY:-}}"
    if [[ -z "$ak" ]]; then
      hts_die "no API key for profile '$profile' — run: hts init / hctl init (dry-run skips this)"
      return 1
    fi
  fi

  local host account
  host="$(hts_hctl_profile_field "$profile" host)"
  account="$(hts_hctl_profile_field "$profile" account)"
  host="${host:-https://app.harness.io}"
  host="${host%/}"
  host="${host%/gateway}"

  local have_tty=0
  if [[ -r /dev/tty ]]; then
    have_tty=1
  fi

  # Non-interactive github runs need --branch up front
  local need_branch_prompt=0
  if [[ -z "$cli_branch" ]]; then
    need_branch_prompt="$(print -- "$filtered" | hts_python -c '
import json,sys
for e in json.load(sys.stdin):
    t=(e.get("type") or "github").lower()
    if t not in ("custom","webhook","custom_webhook"):
        print(1); raise SystemExit
print(0)
')"
  fi
  if [[ "$need_branch_prompt" == "1" && "$have_tty" != "1" ]]; then
    hts_die "branch required for github pipelines — pass: hts run --branch NAME (or run interactively to be prompted per pipeline)"
    return 1
  fi

  hts_log "profile=$profile module=$module entries=$count dry_run=$dry_run${cli_branch:+ branch=$cli_branch}"

  local ok=0 fail=0
  local results=()
  local targets=()
  local alias trigger org project pid etype repo connector input_set branch
  local resp ui_url trig_status trig_msg fire_ec line

  # Materialize target rows first (no network yet).
  while IFS=$'\t' read -r alias etype trigger org project pid repo connector input_set; do
    [[ -n "$alias" ]] || continue
    targets+=("${alias}"$'\t'"${etype}"$'\t'"${trigger}"$'\t'"${org}"$'\t'"${project}"$'\t'"${pid}"$'\t'"${repo}"$'\t'"${connector}"$'\t'"${input_set}")
  done < <(print -- "$filtered" | hts_python -c '
import json,sys
for e in json.load(sys.stdin):
    p=e.get("pipeline") or {}
    etype=(e.get("type") or "github").lower()
    trig=str(e.get("trigger") or "")
    input_set=str(e.get("input_set") or "")
    print("\t".join([
        str(e.get("alias") or ""),
        str(e.get("type") or "github"),
        trig,
        str(p.get("org") or ""),
        str(p.get("project") or ""),
        str(p.get("identifier") or ""),
        str(e.get("repo") or e.get("repo_identifier") or ""),
        str(e.get("connector") or e.get("connector_ref") or ""),
        input_set,
    ]))
')

  # Collect all runtime inputs (branches) before any get-trigger / execute calls.
  local -a planned=()
  local skipped=0
  if [[ -z "$cli_branch" && "$need_branch_prompt" == "1" ]]; then
    hts_log "enter a branch for each pipeline (before triggering)…"
    print -- "" >/dev/tty 2>/dev/null || true
  fi
  for line in "${targets[@]}"; do
    IFS=$'\t' read -r alias etype trigger org project pid repo connector input_set <<<"$line"
    etype="$(hts_entry_type "$etype")"
    branch=""
    if [[ "$etype" != "custom" ]]; then
      if [[ -n "$cli_branch" ]]; then
        branch="$cli_branch"
      else
        branch="$(hts_prompt_run_branch "$alias" "$org" "$project" "$pid")" || {
          hts_err "cancelled while prompting for branch ($alias)"
          skipped=$((skipped + 1))
          results+=("${alias}"$'\t'"ERROR"$'\t'"")
          continue
        }
        branch="$(hts_trim "$branch")"
      fi
      if [[ -z "$branch" ]]; then
        hts_err "no branch for $alias — skipping"
        skipped=$((skipped + 1))
        results+=("${alias}"$'\t'"ERROR"$'\t'"")
        continue
      fi
    fi
    planned+=("${alias}"$'\t'"${etype}"$'\t'"${trigger}"$'\t'"${org}"$'\t'"${project}"$'\t'"${pid}"$'\t'"${repo}"$'\t'"${connector}"$'\t'"${input_set}"$'\t'"${branch}")
  done

  if (( ${#planned[@]} == 0 )); then
    hts_err "nothing to run (no branches collected)"
    return 1
  fi

  if [[ -z "$cli_branch" && "$need_branch_prompt" == "1" ]]; then
    print -- "" >/dev/tty 2>/dev/null || true
    hts_log "inputs collected — triggering ${#planned[@]} pipeline(s)…"
  fi

  for line in "${planned[@]}"; do
    IFS=$'\t' read -r alias etype trigger org project pid repo connector input_set branch <<<"$line"
    hts_log "→ $alias  type=$etype  org=$org project=$project pipeline=$pid branch=${branch:-(-)} trigger=${trigger:-(-)} repo=${repo:-(-)}"
    fire_ec=0
    resp="$(hts_fire_entry "$profile" "$module" "$etype" "$org" "$project" "$pid" "$trigger" "$dry_run" "$branch" "$repo" "$connector" "$input_set")" || fire_ec=$?
    if [[ "$dry_run" == "1" ]]; then
      trig_status="DRY-RUN"
      ui_url=""
      ok=$((ok + 1))
    elif (( fire_ec != 0 )); then
      trig_status="ERROR"
      ui_url=""
      fail=$((fail + 1))
      hts_err "transport error for $alias (see above)"
    else
      trig_status="$(print -- "$resp" | hts_trigger_status)"
      trig_msg="$(print -- "$resp" | hts_trigger_message)"
      ui_url="$(print -- "$resp" | hts_trigger_ui_url "$host" "$account" "$org" "$project" "$pid")"
      if [[ "$trig_status" == "SUCCESS" ]]; then
        ok=$((ok + 1))
        if [[ "$open_urls" == "1" && -n "$ui_url" ]]; then
          hts_open_url "$ui_url"
        fi
      else
        fail=$((fail + 1))
        if [[ -n "$trig_msg" ]]; then
          hts_err "$trig_status for $alias: $trig_msg"
        else
          hts_err "$trig_status for $alias: $resp"
        fi
      fi
    fi
    results+=("${alias}"$'\t'"${trig_status}"$'\t'"${ui_url:-}")
  done

  fail=$((fail + skipped))

  print -- ""
  if (( ${#results[@]} )); then
    print -l -- "${results[@]}" | hts_format_results
  else
    print -- "(no results)"
  fi
  print -- ""
  hts_log "done: ok=$ok fail=$fail"
  (( fail == 0 ))
}

hts_preview_matrix() {
  local profile="$1" module="$2" tech="${3:-}" set_="${4:-}" aliases="${5:-}"
  local entries filtered
  entries="$(hts_matrix_entries_json "$profile" "$module")"
  filtered="$(print -- "$entries" | hts_matrix_filter "$tech" "$set_" "$aliases")"
  if [[ "$filtered" == "[]" ]]; then
    print -- "(no matching entries)"
    return 0
  fi
  print -- "$filtered" | hts_format_entries
}
