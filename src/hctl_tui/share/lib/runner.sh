# Matrix runner: filter + fire Harness custom webhook triggers.
# shellcheck shell=zsh

# Discover a usable hctl op for custom webhooks (cached in-process).
# Real fires prefer curl (matches Harness docs); hctl op is optional/dry-run only.
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

hts_trigger_status() {
  # stdin: JSON body → print status or ERROR
  hts_python -c '
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print("ERROR")
    raise SystemExit(0)
print(d.get("status") or "ERROR")
' 2>/dev/null || print ERROR
}

hts_trigger_message() {
  # stdin: JSON body → short human message
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
  hts_python -c '
import json,sys
try:
    d=json.loads(sys.stdin.read())
    print((d.get("data") or {}).get("uiUrl") or "")
except Exception:
    print("")
' 2>/dev/null || true
}

hts_fire_custom_trigger() {
  # Args: profile org project pipeline_id trigger_id dry_run(0|1)
  # Prints response body on stdout. Exit 0 when HTTP transport succeeded
  # (even if Harness status is ERROR/FAILURE). Exit 1 only on transport failure.
  local profile="$1" org="$2" project="$3" pipeline_id="$4" trigger_id="$5" dry_run="${6:-0}"
  local host account api_key
  host="$(hts_hctl_profile_field "$profile" host)"
  account="$(hts_hctl_profile_field "$profile" account)"
  api_key="$(hts_hctl_profile_field "$profile" api_key)"
  host="${host:-https://app.harness.io}"
  host="${host%/}"

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
    print -u2 -- "DRY-RUN POST $url"
    print -u2 -- "  headers: content-type: application/json, X-Api-Key: ***"
    print -u2 -- "  body: {}"
    if hts_discover_webhook_op; then
      hctl --profile "$profile" api call "$HTS_WEBHOOK_OP" \
        --query "accountIdentifier=$account" \
        --query "orgIdentifier=$org" \
        --query "projectIdentifier=$project" \
        --query "pipelineIdentifier=$pipeline_id" \
        --query "triggerIdentifier=$trigger_id" \
        --body-json '{}' \
        --dry-run 2>&1 | print -u2 -- || true
    fi
    return 0
  fi

  # Prefer curl — same contract as Harness "Copy as cURL". hctl op discovery is
  # best-effort and often selects the wrong OpenAPI operation.
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

  # Transport ok if we got a body; 401/403 still return JSON we want the caller to show.
  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    hts_err "Harness auth failed (HTTP $http_code) — check api_key on profile '$profile'"
  fi
  return 0
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

  hts_log "profile=$profile module=$module entries=$count dry_run=$dry_run"

  local ok=0 fail=0
  local results=()
  local line alias trigger org project pid resp ui_url trig_status trig_msg fire_ec

  while IFS=$'\t' read -r alias trigger org project pid; do
    [[ -n "$alias" ]] || continue
    hts_log "→ $alias  trigger=$trigger  pipeline=$org/$project/$pid"
    fire_ec=0
    resp="$(hts_fire_custom_trigger "$profile" "$org" "$project" "$pid" "$trigger" "$dry_run")" || fire_ec=$?
    if [[ "$dry_run" == "1" ]]; then
      trig_status="DRY-RUN"
      ui_url=""
      ok=$((ok + 1))
    elif (( fire_ec != 0 )); then
      trig_status="ERROR"
      ui_url=""
      fail=$((fail + 1))
      hts_err "trigger transport error for $alias (see above)"
    else
      trig_status="$(print -- "$resp" | hts_trigger_status)"
      trig_msg="$(print -- "$resp" | hts_trigger_message)"
      ui_url="$(print -- "$resp" | hts_trigger_ui_url)"
      if [[ "$trig_status" == "SUCCESS" ]]; then
        ok=$((ok + 1))
        if [[ "$open_urls" == "1" && -n "$ui_url" ]]; then
          hts_open_url "$ui_url"
        fi
      else
        fail=$((fail + 1))
        if [[ -n "$trig_msg" ]]; then
          hts_err "trigger $trig_status for $alias: $trig_msg"
        else
          hts_err "trigger $trig_status for $alias: $resp"
        fi
      fi
    fi
    results+=("${alias}"$'\t'"${trig_status}"$'\t'"${ui_url:-}")
  done < <(print -- "$filtered" | hts_python -c '
import json,sys
for e in json.load(sys.stdin):
    p=e.get("pipeline") or {}
    print("\t".join([
        str(e.get("alias") or ""),
        str(e.get("trigger") or ""),
        str(p.get("org") or ""),
        str(p.get("project") or ""),
        str(p.get("identifier") or ""),
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
