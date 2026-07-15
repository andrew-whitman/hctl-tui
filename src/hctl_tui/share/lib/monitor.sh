# Watch pipeline executions and fetch console logs into the cwd.
# shellcheck shell=zsh

# HTS_LAST_RUN_BATCH rows (from runner.sh):
#   alias \t org \t project \t pipeline \t planExecutionId \t uiUrl \t triggerStatus

hts_logs_dir() {
  # Prefer --out / HTS_LOGS_DIR; else ./hts-logs under cwd.
  local override="${1:-${HTS_LOGS_DIR:-}}"
  if [[ -n "$override" ]]; then
    print -- "$override"
  else
    print -- "./hts-logs"
  fi
}

hts_execution_status_is_running() {
  # Allowlist of non-terminal Harness statuses (case-insensitive).
  local st="${1:l}"
  case "$st" in
    running|asyncwaiting|taskwaiting|timedwaiting|notstarted|queued|paused|pausing)
      return 0
      ;;
    resourcewaiting|interventionwaiting|approvalwaiting|waitsteprunning)
      return 0
      ;;
    queuedlicenselimitreached|queuedexecutionconcurrencyreached|inputwaiting)
      return 0
      ;;
    uploadwaiting|queuedglobalinfracapacityreached|queued_plan_creation|discontinuing)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

hts_execution_status_is_terminal() {
  local st="$1"
  [[ -n "$st" ]] || return 1
  hts_execution_status_is_running "$st" && return 1
  return 0
}

hts_get_execution_detail_json() {
  # usage: hts_get_execution_detail_json profile org project planExecutionId
  # Prints raw JSON on stdout; returns non-zero on transport/CLI failure.
  local profile="$1" org="$2" project="$3" plan_id="$4"
  local account
  account="$(hts_hctl_profile_field "$profile" account)"
  account="$(hts_trim "$account")"
  org="$(hts_trim "$org")"
  project="$(hts_trim "$project")"
  plan_id="$(hts_trim "$plan_id")"

  if [[ -z "$account" || -z "$org" || -z "$project" || -z "$plan_id" ]]; then
    hts_err "get-execution-detail: missing account/org/project/planExecutionId"
    return 1
  fi

  local out ec=0
  out="$(
    hts_hctl --profile "$profile" pipeline-execution-details get-execution-detail-v2 \
      --account-identifier "$account" \
      --org-identifier "$org" \
      --project-identifier "$project" \
      --plan-execution-id "$plan_id" 2>/dev/null
  )" || ec=$?

  if (( ec != 0 )) || [[ -z "$out" ]]; then
    # Fallback: curl (same auth as custom webhook fires)
    local host api_key
    host="$(hts_hctl_profile_field "$profile" host)"
    api_key="$(hts_hctl_profile_field "$profile" api_key)"
    api_key="${api_key:-${HARNESS_API_KEY:-}}"
    host="${host:-https://app.harness.io}"
    host="${host%/}"
    host="${host%/gateway}"
    if [[ -z "$api_key" ]]; then
      hts_err "get-execution-detail failed and no API key for profile '$profile'"
      return 1
    fi
    local url http
    url="${host}/gateway/pipeline/api/pipelines/execution/v2/$(hts_urlencode "$plan_id")"
    url+="?accountIdentifier=$(hts_urlencode "$account")"
    url+="&orgIdentifier=$(hts_urlencode "$org")"
    url+="&projectIdentifier=$(hts_urlencode "$project")"
    out="$(
      hts_curl -sS -w $'\n%{http_code}' \
        -H "X-Api-Key: ${api_key}" \
        -H 'accept: application/json' \
        "$url"
    )" || return 1
    http="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if [[ "$http" != 2* ]]; then
      hts_err "get-execution-detail HTTP $http for $plan_id"
      return 1
    fi
  fi

  # Drop non-JSON preamble if hctl printed banners
  print -- "$out" | hts_python -c '
import sys
raw = sys.stdin.read()
i = raw.find("{")
j = raw.find("[")
starts = [x for x in (i, j) if x >= 0]
if not starts:
    sys.stdout.write(raw)
else:
    sys.stdout.write(raw[min(starts):])
'
}

hts_parse_execution_summary() {
  # stdin: execution detail JSON
  # stdout: status \t runSequence \t pipelineIdentifier \t planExecutionId
  hts_python -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("\t\t\t")
    raise SystemExit(0)
data = d.get("data") if isinstance(d.get("data"), dict) else d
summ = data.get("pipelineExecutionSummary") if isinstance(data.get("pipelineExecutionSummary"), dict) else {}
status = summ.get("status") or data.get("status") or ""
run_seq = summ.get("runSequence")
if run_seq is None:
    run_seq = data.get("runSequence") or ""
pipe = summ.get("pipelineIdentifier") or data.get("pipelineIdentifier") or ""
plan = summ.get("planExecutionId") or data.get("planExecutionId") or ""
print("\t".join([str(status), str(run_seq), str(pipe), str(plan)]))
' 2>/dev/null || print $'\t\t\t'
}

hts_format_watch_table() {
  # stdin: TSV alias \t status \t runSequence \t shortId
  local cols raw
  cols="$(hts_term_cols)"
  raw="$(/bin/cat)"
  HTS_FMT_INPUT="$raw" hts_python - "$cols" <<'PY'
import os, sys

cols = int(sys.argv[1]) if sys.argv[1].isdigit() else 80
raw = os.environ.get("HTS_FMT_INPUT") or ""
lines = [ln.rstrip("\n") for ln in raw.splitlines() if ln.strip()]
if not lines:
    print("(no executions)")
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
    while len(parts) < 4:
        parts.append("")
    rows.append(parts[:4])

print("WATCH")
w_alias = min(24, max(8, cols // 4))
w_status = 18
w_run = 8
w_id = max(10, cols - w_alias - w_status - w_run - 3)
print("{:<{a}} {:<{s}} {:<{r}} {}".format(
    "ALIAS", "STATUS", "RUN#", "EXECUTION", a=w_alias, s=w_status, r=w_run))
print("-" * min(cols, w_alias + w_status + w_run + w_id + 3))
for alias, status, run_seq, short_id in rows:
    print("{:<{a}} {:<{s}} {:<{r}} {}".format(
        trunc(alias, w_alias),
        trunc(status, w_status),
        trunc(run_seq, w_run),
        trunc(short_id, w_id),
        a=w_alias,
        s=w_status,
        r=w_run,
    ))
PY
}

hts_watchable_batch_lines() {
  # Prints HTS_LAST_RUN_BATCH rows that have a planExecutionId (SUCCESS triggers).
  local line alias org project pid exec_id ui_url st
  for line in "${HTS_LAST_RUN_BATCH[@]}"; do
    IFS=$'\t' read -r alias org project pid exec_id ui_url st <<<"$line"
    [[ -n "$exec_id" ]] || continue
    print -- "$line"
  done
}

hts_watch_last_batch() {
  # usage: hts_watch_last_batch profile [interval_sec] [timeout_sec]
  local profile="$1"
  local interval="${2:-10}"
  local timeout="${3:-3600}"
  local -a batch=()
  local line

  while IFS= read -r line; do
    [[ -n "$line" ]] && batch+=("$line")
  done < <(hts_watchable_batch_lines)

  if (( ${#batch[@]} == 0 )); then
    hts_log "watch: no planExecutionIds to monitor (nothing to watch)"
    return 0
  fi

  # Validate numeric
  [[ "$interval" == <-> ]] || interval=10
  [[ "$timeout" == <-> ]] || timeout=3600
  (( interval < 1 )) && interval=1
  (( timeout < 1 )) && timeout=1

  hts_log "watching ${#batch[@]} execution(s) (interval=${interval}s timeout=${timeout}s)…"
  print -- ""

  local started now elapsed all_done=0 timed_out=0
  started="$(hts_cmd date +%s)"
  local alias org project pid exec_id ui_url st
  # Note: zsh reserves readonly `status` (== $?); never use that name as a local.
  local detail exec_status run_seq pipe_id plan_id short_id
  local -a table=()
  local any_err=0

  while true; do
    now="$(hts_cmd date +%s)"
    elapsed=$(( now - started ))
    if (( elapsed >= timeout )); then
      timed_out=1
    fi

    table=()
    all_done=1
    for line in "${batch[@]}"; do
      IFS=$'\t' read -r alias org project pid exec_id ui_url st <<<"$line"
      detail="$(hts_get_execution_detail_json "$profile" "$org" "$project" "$exec_id")" || {
        any_err=1
        table+=("${alias}"$'\t'"ERROR"$'\t'""$'\t'"${exec_id:0:12}…")
        all_done=0
        continue
      }
      IFS=$'\t' read -r exec_status run_seq pipe_id plan_id <<<"$(print -- "$detail" | hts_parse_execution_summary)"
      exec_status="${exec_status:-UNKNOWN}"
      short_id="$exec_id"
      if (( ${#short_id} > 16 )); then
        short_id="${short_id:0:12}…"
      fi
      table+=("${alias}"$'\t'"${exec_status}"$'\t'"${run_seq}"$'\t'"${short_id}")
      if ! hts_execution_status_is_terminal "$exec_status"; then
        all_done=0
      fi
    done

    # Clear previous table when on a TTY (reprint in place-ish)
    if [[ -t 1 ]]; then
      print -- ""
    fi
    print -l -- "${table[@]}" | hts_format_watch_table
    print -- "elapsed: ${elapsed}s / ${timeout}s"

    if (( all_done )); then
      print -- ""
      hts_log "watch: all executions reached a terminal status"
      (( any_err == 0 ))
      return $?
    fi
    if (( timed_out )); then
      print -- ""
      hts_err "watch: timed out after ${timeout}s (some executions still running)"
      return 1
    fi

    hts_cmd sleep "$interval"
  done
}

hts_log_blob_prefix() {
  # usage: hts_log_blob_prefix account pipelineId runSequence planExecutionId
  local account="$1" pipeline_id="$2" run_seq="$3" plan_id="$4"
  print -- "${account}/pipeline/${pipeline_id}/${run_seq}/-${plan_id}"
}

hts_log_service_download_job() {
  # usage: hts_log_service_download_job profile account prefix
  # POST blob/download; print response JSON (status/link).
  local profile="$1" account="$2" prefix="$3"
  local host api_key
  host="$(hts_hctl_profile_field "$profile" host)"
  api_key="$(hts_hctl_profile_field "$profile" api_key)"
  api_key="${api_key:-${HARNESS_API_KEY:-}}"
  host="${host:-https://app.harness.io}"
  host="${host%/}"
  host="${host%/gateway}"

  if [[ -z "$api_key" ]]; then
    hts_err "no API key for profile '$profile'"
    return 1
  fi

  local url out http
  url="${host}/gateway/log-service/blob/download"
  url+="?accountID=$(hts_urlencode "$account")"
  url+="&prefix=$(hts_urlencode "$prefix")"

  out="$(
    hts_curl -sS -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: ${api_key}" \
      -H 'content-type: application/json' \
      -H 'accept: application/json' \
      "$url"
  )" || return 1
  http="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [[ "$http" != 2* ]]; then
    hts_err "log-service download HTTP $http: ${out:0:300}"
    return 1
  fi
  print -- "$out"
}

hts_parse_log_download_status() {
  # stdin JSON → status \t link
  hts_python -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("\t")
    raise SystemExit(0)
# response may be wrapped
if isinstance(d.get("data"), dict) and ("status" in d["data"] or "link" in d["data"]):
    d = d["data"]
status = str(d.get("status") or "")
link = str(d.get("link") or d.get("downloadUrl") or "")
print(status + "\t" + link)
' 2>/dev/null || print $'\t'
}

hts_fetch_execution_logs() {
  # usage: hts_fetch_execution_logs profile alias org project pipeline_id plan_execution_id [out_root] [force=0]
  # Writes: <out_root>/<alias>/<planExecutionId>/{meta.json,logs.zip,extracted/}
  local profile="$1" alias="$2" org="$3" project="$4" pipeline_id="$5" plan_id="$6"
  local out_root="${7:-}" force="${8:-0}"
  local account host ui_hint=""
  account="$(hts_hctl_profile_field "$profile" account)"
  account="$(hts_trim "$account")"
  org="$(hts_trim "$org")"
  project="$(hts_trim "$project")"
  pipeline_id="$(hts_trim "$pipeline_id")"
  plan_id="$(hts_trim "$plan_id")"
  alias="$(hts_trim "$alias")"
  [[ -n "$alias" ]] || alias="pipeline"

  if [[ -z "$account" || -z "$org" || -z "$project" || -z "$pipeline_id" || -z "$plan_id" ]]; then
    hts_err "logs: missing required ids (account/org/project/pipeline/execution)"
    return 1
  fi

  out_root="$(hts_logs_dir "$out_root")"
  local dest
  dest="${out_root}/${alias}/${plan_id}"
  /bin/mkdir -p "$dest" || {
    hts_err "logs: cannot create $dest"
    return 1
  }

  # Note: zsh reserves readonly `status` (== $?); never use that name as a local.
  local detail exec_status run_seq pipe_from_api _
  detail="$(hts_get_execution_detail_json "$profile" "$org" "$project" "$plan_id")" || return 1
  IFS=$'\t' read -r exec_status run_seq pipe_from_api _ <<<"$(print -- "$detail" | hts_parse_execution_summary)"
  [[ -n "$pipe_from_api" ]] && pipeline_id="$pipe_from_api"

  if [[ -z "$run_seq" ]]; then
    hts_err "logs: could not resolve runSequence for $plan_id"
    return 1
  fi

  if [[ "$force" != "1" ]] && hts_execution_status_is_running "$exec_status"; then
    hts_err "logs: execution $plan_id is still '$exec_status' — wait until terminal (or pass --force)"
    return 1
  fi

  local prefix job job_status link attempt max_attempts=36
  prefix="$(hts_log_blob_prefix "$account" "$pipeline_id" "$run_seq" "$plan_id")"
  hts_log "→ logs $alias  status=$exec_status runSequence=$run_seq"
  hts_log "  prefix=$prefix"
  hts_log "  dest=$dest"

  link=""
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    job="$(hts_log_service_download_job "$profile" "$account" "$prefix")" || return 1
    IFS=$'\t' read -r job_status link <<<"$(print -- "$job" | hts_parse_log_download_status)"
    job_status="${job_status:l}"
    if [[ "$job_status" == "success" && -n "$link" ]]; then
      break
    fi
    if [[ "$job_status" == "failed" || "$job_status" == "error" ]]; then
      hts_err "logs: download job failed: $job"
      return 1
    fi
    # queued / in-progress
    hts_log "  log pack status=${job_status:-queued} (attempt $attempt/$max_attempts)…"
    hts_cmd sleep 5
    link=""
  done

  if [[ -z "$link" ]]; then
    hts_err "logs: timed out waiting for download link"
    return 1
  fi

  local zip_path extract_dir
  zip_path="${dest}/logs.zip"
  extract_dir="${dest}/extracted"
  hts_log "  downloading logs.zip…"
  if ! hts_curl -sS -L -o "$zip_path" "$link"; then
    hts_err "logs: failed to download zip from link"
    return 1
  fi
  if [[ ! -s "$zip_path" ]]; then
    hts_err "logs: downloaded empty file"
    return 1
  fi

  /bin/rm -rf "$extract_dir"
  /bin/mkdir -p "$extract_dir"
  if ! hts_cmd unzip -q -o "$zip_path" -d "$extract_dir" 2>/dev/null; then
    # Some environments lack unzip; keep the zip and warn
    hts_log "warn: unzip failed or missing — left logs.zip in place"
  fi

  host="$(hts_hctl_profile_field "$profile" host)"
  host="${host:-https://app.harness.io}"
  host="${host%/}"
  host="${host%/gateway}"
  ui_hint="${host}/ng/account/${account}/home/orgs/${org}/projects/${project}/pipelines/${pipeline_id}/executions/${plan_id}/pipeline"

  HTS_META_ALIAS="$alias" HTS_META_ORG="$org" HTS_META_PROJECT="$project" \
    HTS_META_PIPELINE="$pipeline_id" HTS_META_PLAN="$plan_id" \
    HTS_META_STATUS="$exec_status" HTS_META_RUN="$run_seq" HTS_META_UI="$ui_hint" \
    HTS_META_PREFIX="$prefix" HTS_META_DEST="$dest" \
    hts_python - <<'PY'
import json, os, time
meta = {
    "alias": os.environ.get("HTS_META_ALIAS") or "",
    "org": os.environ.get("HTS_META_ORG") or "",
    "project": os.environ.get("HTS_META_PROJECT") or "",
    "pipeline": os.environ.get("HTS_META_PIPELINE") or "",
    "planExecutionId": os.environ.get("HTS_META_PLAN") or "",
    "status": os.environ.get("HTS_META_STATUS") or "",
    "runSequence": os.environ.get("HTS_META_RUN") or "",
    "uiUrl": os.environ.get("HTS_META_UI") or "",
    "logPrefix": os.environ.get("HTS_META_PREFIX") or "",
    "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
path = os.path.join(os.environ.get("HTS_META_DEST") or ".", "meta.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY

  hts_log "✓ logs written to $dest"
  return 0
}

hts_fetch_last_batch_logs() {
  # usage: hts_fetch_last_batch_logs profile [out_root]
  local profile="$1" out_root="${2:-}"
  local -a batch=()
  local line alias org project pid exec_id ui_url st
  local ok=0 fail=0

  while IFS= read -r line; do
    [[ -n "$line" ]] && batch+=("$line")
  done < <(hts_watchable_batch_lines)

  if (( ${#batch[@]} == 0 )); then
    hts_log "fetch-logs: no planExecutionIds in last run batch"
    return 0
  fi

  hts_log "fetching logs for ${#batch[@]} execution(s)…"
  for line in "${batch[@]}"; do
    IFS=$'\t' read -r alias org project pid exec_id ui_url st <<<"$line"
    if hts_fetch_execution_logs "$profile" "$alias" "$org" "$project" "$pid" "$exec_id" "$out_root"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done
  hts_log "fetch-logs: ok=$ok fail=$fail"
  (( fail == 0 ))
}
