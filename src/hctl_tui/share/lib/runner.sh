# Matrix runner: filter + fire pipelines (GitHub-style execute or custom webhooks).
# shellcheck shell=zsh

# Discover a usable hctl op for custom webhooks (cached in-process).
# Real custom fires prefer curl; hctl op is optional/dry-run only.
typeset -g HTS_WEBHOOK_OP=""

hts_discover_webhook_op() {
  [[ -n "$HTS_WEBHOOK_OP" ]] && return 0
  hts_have hctl || return 1
  local hits
  hits="$(hctl api list --search 'webhook custom' 2>/dev/null || true)"
  local op
  op="$(print -- "$hits" | awk '/custom.*webhook|webhook.*custom|trigger.*webhook/ {print $1; exit}' || true)"
  if [[ -z "$op" ]]; then
    hits="$(hctl api list --search webhook 2>/dev/null || true)"
    op="$(print -- "$hits" | awk 'NR>1 {print $1; exit}' || true)"
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

hts_fire_pipeline_execute() {
  # Args: profile org project pipeline_id module dry_run [input_set] [branch]
  # Uses: hctl pipeline-execute post-pipeline-execute-with-input-set-yaml
  local profile="$1" org="$2" project="$3" pipeline_id="$4" module="$5" dry_run="${6:-0}"
  local input_set="${7:-}" branch="${8:-}"
  local account module_type
  account="$(hts_hctl_profile_field "$profile" account)"
  module_type="$(hts_module_type "$module")"

  org="$(hts_trim "$org")"
  project="$(hts_trim "$project")"
  pipeline_id="$(hts_trim "$pipeline_id")"
  account="$(hts_trim "$account")"
  input_set="$(hts_trim "$input_set")"
  branch="$(hts_trim "$branch")"

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

  local -a cmd=(
    "$hctl_bin" --profile "$profile"
    pipeline-execute post-pipeline-execute-with-input-set-yaml
    --account-identifier "$account"
    --org-identifier "$org"
    --project-identifier "$project"
    --identifier "$pipeline_id"
    --module-type "$module_type"
    --content-type application/yaml
    --body ''
    --output json
  )
  [[ -n "$branch" ]] && cmd+=(--branch "$branch")
  [[ -n "$input_set" ]] && cmd+=(--input-set-identifiers "$input_set")

  if [[ "$dry_run" == "1" ]]; then
    print -u2 -- "DRY-RUN hctl pipeline-execute post-pipeline-execute-with-input-set-yaml"
    print -u2 -- "  profile=$profile account=$account moduleType=$module_type"
    print -u2 -- "  org=$org project=$project pipeline=$pipeline_id"
    [[ -n "$input_set" ]] && print -u2 -- "  inputSet=$input_set"
    [[ -n "$branch" ]] && print -u2 -- "  branch=$branch"
    "${cmd[@]}" --dry-run --curl 1>&2 || true
    return 0
  fi

  local resp ec=0 errfile
  errfile="$(hts_mktemp hts-hctl)" || {
    hts_err "could not create temp file"
    return 1
  }
  resp="$("${cmd[@]}" 2>"$errfile")" || ec=$?
  if (( ec != 0 )); then
    local err
    err="$(/bin/cat "$errfile" 2>/dev/null || true)"
    rm -f "$errfile"
    if [[ -n "$resp" ]]; then
      print -- "$resp"
      local msg
      msg="$(print -- "$resp" | hts_trigger_message)"
      [[ -n "$msg" ]] && hts_err "hctl execute failed for $org/$project/$pipeline_id: $msg"
    fi
    [[ -n "$err" ]] && hts_err "$err"
    (( ec != 0 )) && [[ -z "$resp" && -z "$err" ]] && \
      hts_err "hctl execute failed (exit $ec) for $org/$project/$pipeline_id"
    return 1
  fi
  rm -f "$errfile"

  if [[ -z "$resp" ]]; then
    hts_err "empty response from hctl pipeline-execute"
    return 1
  fi
  print -- "$resp"
  return 0
}

hts_fire_entry() {
  # Args: profile module type org project pipeline_id trigger_or_inputset dry_run [branch]
  local profile="$1" module="$2" etype="$3" org="$4" project="$5" pipeline_id="$6"
  local trigger="$7" dry_run="${8:-0}" branch="${9:-}"
  etype="$(hts_entry_type "$etype")"
  case "$etype" in
    custom)
      hts_fire_custom_trigger "$profile" "$org" "$project" "$pipeline_id" "$trigger" "$dry_run"
      ;;
    *)
      # github / execute via hctl; $trigger holds optional input_set id only
      hts_fire_pipeline_execute "$profile" "$org" "$project" "$pipeline_id" "$module" "$dry_run" "$trigger" "$branch"
      ;;
  esac
}

hts_run_matrix() {
  # usage: hts_run_matrix profile module tech set aliases dry_run open_urls
  local profile="$1" module="$2" tech="${3:-}" set_="${4:-}" aliases="${5:-}" dry_run="${6:-0}" open_urls="${7:-0}"

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

  hts_log "profile=$profile module=$module entries=$count dry_run=$dry_run"

  local ok=0 fail=0
  local results=()
  local alias trigger org project pid etype branch resp ui_url trig_status trig_msg fire_ec

  while IFS=$'\t' read -r alias etype trigger org project pid branch; do
    [[ -n "$alias" ]] || continue
    etype="$(hts_entry_type "$etype")"
    hts_log "→ $alias  type=$etype  pipeline=$org/$project/$pid  trigger/inputSet=${trigger:-(-)}"
    fire_ec=0
    resp="$(hts_fire_entry "$profile" "$module" "$etype" "$org" "$project" "$pid" "$trigger" "$dry_run" "$branch")" || fire_ec=$?
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
  done < <(print -- "$filtered" | hts_python -c '
import json,sys
for e in json.load(sys.stdin):
    p=e.get("pipeline") or {}
    etype=(e.get("type") or "github").lower()
    # custom: trigger id is the webhook id. github execute: only pass explicit input_set.
    if etype in ("custom", "webhook", "custom_webhook"):
        trig=str(e.get("trigger") or "")
    else:
        trig=str(e.get("input_set") or "")
    print("\t".join([
        str(e.get("alias") or ""),
        str(e.get("type") or "github"),
        trig,
        str(p.get("org") or ""),
        str(p.get("project") or ""),
        str(p.get("identifier") or ""),
        str(e.get("branch") or ""),
    ]))
')

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
