# Matrix runner: filter + fire Harness custom webhook triggers.
# shellcheck shell=zsh

# Discover a usable hctl op for custom webhooks (cached in-process).
typeset -g HTS_WEBHOOK_OP=""

hts_discover_webhook_op() {
  [[ -n "$HTS_WEBHOOK_OP" ]] && return 0
  hts_have hctl || return 1
  local hits
  hits="$(hctl api list --search 'webhook custom' 2>/dev/null || true)"
  # Prefer operation ids that look like custom webhook POST
  local op
  op="$(print -- "$hits" | awk '/custom.*webhook|webhook.*custom|trigger.*webhook/ {print $1; exit}' || true)"
  if [[ -z "$op" ]]; then
    hits="$(hctl api list --search webhook 2>/dev/null || true)"
    op="$(print -- "$hits" | awk 'NR>1 {print $1; exit}' || true)"
  fi
  HTS_WEBHOOK_OP="$op"
  [[ -n "$HTS_WEBHOOK_OP" ]]
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
  url="${host}/gateway/pipeline/api/webhook/custom/v2?accountIdentifier=${account}&orgIdentifier=${org}&projectIdentifier=${project}&pipelineIdentifier=${pipeline_id}&triggerIdentifier=${trigger_id}"

  if [[ "$dry_run" == "1" ]]; then
    print -u2 -- "DRY-RUN POST $url"
    print -u2 -- "  headers: content-type: application/json, X-Api-Key: ***"
    print -u2 -- "  body: {}"
    # Also show hctl-style dry-run if we discovered an op
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

  # Prefer hctl api call when an op was discovered; else curl with profile credentials.
  local resp ec=0
  if hts_discover_webhook_op; then
    resp="$(
      hctl --profile "$profile" api call "$HTS_WEBHOOK_OP" \
        --query "accountIdentifier=$account" \
        --query "orgIdentifier=$org" \
        --query "projectIdentifier=$project" \
        --query "pipelineIdentifier=$pipeline_id" \
        --query "triggerIdentifier=$trigger_id" \
        --body-json '{}' \
        2>/dev/null
    )" || ec=$?
  else
    resp="$(
      curl -sS -X POST \
        -H 'content-type: application/json' \
        -H "X-Api-Key: ${api_key}" \
        --url "$url" \
        -d '{}'
    )" || ec=$?
  fi

  if (( ec != 0 )) || [[ -z "$resp" ]]; then
    # Retry with curl if hctl path failed
    if [[ -n "$HTS_WEBHOOK_OP" ]]; then
      resp="$(
        curl -sS -X POST \
          -H 'content-type: application/json' \
          -H "X-Api-Key: ${api_key}" \
          --url "$url" \
          -d '{}'
      )" || return 1
    else
      return 1
    fi
  fi

  print -- "$resp"
  # Success heuristic
  print -- "$resp" | hts_python -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("status")=="SUCCESS" else 1)' 2>/dev/null
}

hts_run_matrix() {
  # usage: hts_run_matrix profile module tech set aliases dry_run open_urls
  local profile="$1" module="$2" tech="${3:-}" set_="${4:-}" aliases="${5:-}" dry_run="${6:-0}" open_urls="${7:-0}"

  # Allow dry-run preview even if hctl profile file is missing (resolved fields shown as placeholders)
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
    hts_log "no entries matched filters (tech=${tech:-*} set=${set_:-*} alias=${aliases:-*})"
    return 1
  fi

  hts_log "profile=$profile module=$module entries=$count dry_run=$dry_run"

  local ok=0 fail=0
  local results=()
  local line alias trigger org project pid resp ui_url trig_status

  while IFS=$'\t' read -r alias trigger org project pid; do
    [[ -n "$alias" ]] || continue
    hts_log "→ $alias  trigger=$trigger  pipeline=$org/$project/$pid"
    if resp="$(hts_fire_custom_trigger "$profile" "$org" "$project" "$pid" "$trigger" "$dry_run")"; then
      if [[ "$dry_run" == "1" ]]; then
        trig_status="DRY-RUN"
        ui_url=""
        ok=$((ok + 1))
      else
        trig_status="$(print -- "$resp" | hts_python -c 'import json,sys
try:
  d=json.load(sys.stdin); print(d.get("status") or "UNKNOWN")
except Exception:
  print("UNKNOWN")' 2>/dev/null || print UNKNOWN)"
        ui_url="$(print -- "$resp" | hts_python -c 'import json,sys
try:
  d=json.load(sys.stdin); print((d.get("data") or {}).get("uiUrl") or "")
except Exception:
  print("")' 2>/dev/null || true)"
        if [[ "$trig_status" == "SUCCESS" ]]; then
          ok=$((ok + 1))
          if [[ "$open_urls" == "1" && -n "$ui_url" ]]; then
            hts_open_url "$ui_url"
          fi
        else
          fail=$((fail + 1))
          hts_err "trigger failed for $alias: $resp"
        fi
      fi
    else
      trig_status="ERROR"
      ui_url=""
      fail=$((fail + 1))
      hts_err "trigger error for $alias"
    fi
    results+=("$(printf '%-24s %-10s %s' "$alias" "$trig_status" "${ui_url:-}")")
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
  print -- "RESULTS"
  print -- "-------"
  local r
  for r in "${results[@]}"; do
    print -- "$r"
  done
  print -- ""
  hts_log "done: ok=$ok fail=$fail"
  (( fail == 0 ))
}

hts_preview_matrix() {
  local profile="$1" module="$2" tech="${3:-}" set_="${4:-}" aliases="${5:-}"
  local entries filtered
  entries="$(hts_matrix_entries_json "$profile" "$module")"
  filtered="$(print -- "$entries" | hts_matrix_filter "$tech" "$set_" "$aliases")"
  print -- "$filtered" | hts_python -c '
import json, sys
entries = json.load(sys.stdin)
if not entries:
    print("(no matching entries)")
    raise SystemExit(0)
fmt = "{:<24} {:<16} {:<10} {:<10} {}"
print(fmt.format("ALIAS", "TRIGGER", "TECH", "SET", "PIPELINE"))
print("-" * 80)
for e in entries:
    p = e.get("pipeline") or {}
    pid = "{}/{}/{}".format(p.get("org", ""), p.get("project", ""), p.get("identifier", ""))
    print(fmt.format(e.get("alias") or "", e.get("trigger") or "", e.get("tech") or "", e.get("set") or "", pid))
'
}
