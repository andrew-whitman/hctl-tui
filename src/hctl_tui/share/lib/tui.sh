# gum-based TUI flows for hctl-tui.
# shellcheck shell=zsh

# Use the alternate screen buffer so menus redraw in place (like vim/htop)
# instead of stacking boxes in the scrollback.
hts_tui_enter() {
  HTS_TUI_ACTIVE=1
  printf '\e[?1049h' >/dev/tty 2>/dev/null || printf '\e[?1049h'
  hts_tui_clear
}

hts_tui_leave() {
  HTS_TUI_ACTIVE=0
  printf '\e[?1049l' >/dev/tty 2>/dev/null || printf '\e[?1049l'
}

hts_tui_clear() {
  {
    printf '\e[0m\e[H\e[2J\e[3J'
  } >/dev/tty 2>/dev/null || printf '\e[0m\e[H\e[2J\e[3J'
}

hts_tui_pause() {
  local msg="${1:-Press Enter}"
  print -- "" >/dev/tty 2>/dev/null || print -- ""
  gum input --placeholder "$msg" --value "" >/dev/null || true
}

hts_gum_choose_height() {
  local r
  r="$(hts_term_rows)"
  r=$(( r - 6 ))
  if (( r < 5 )); then r=5; fi
  if (( r > 20 )); then r=20; fi
  print -- "$r"
}

hts_gum_pick() {
  unsetopt xtrace verbose 2>/dev/null || true
  if [[ -r /dev/tty ]]; then
    gum choose "$@" </dev/tty
  else
    gum choose "$@"
  fi
}

hts_gum_input() {
  if [[ -r /dev/tty ]]; then
    gum input "$@" </dev/tty
  else
    gum input "$@"
  fi
}

# Active profile without an extra chooser. Only prompts when needed.
hts_tui_profile() {
  local names=() n active
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(hts_profile_names)

  if (( ${#names[@]} == 0 )); then
    hts_tui_clear
    hts_gum_box_warn "No hctl profiles — running hctl init…"
    print -- "" >/dev/tty 2>/dev/null || print -- ""
    hts_profile_init
    hts_active_profile
    return 0
  fi

  active="$(hts_active_profile)"
  if [[ -n "$active" ]] && hts_hctl_profile_exists "$active"; then
    print -- "$active"
    return 0
  fi
  if (( ${#names[@]} == 1 )); then
    print -- "${names[1]}"
    return 0
  fi

  hts_tui_clear
  hts_gum_pick \
    --height="$(hts_gum_choose_height)" \
    --header "Select hctl profile" \
    "${names[@]}"
}

hts_tui_pick_module() {
  local profile="$1" header="${2:-Module}"
  local modules=() m
  while IFS= read -r m; do
    [[ -n "$m" ]] && modules+=("$m")
  done < <(hts_list_modules "$profile")

  if (( ${#modules[@]} == 0 )); then
    return 1
  fi
  if (( ${#modules[@]} == 1 )); then
    print -- "${modules[1]}"
    return 0
  fi

  local def sel_args=()
  def="$(hts_default_module)"
  if [[ -n "$def" ]]; then
    for m in "${modules[@]}"; do
      if [[ "$m" == "$def" ]]; then
        sel_args=(--selected "$def")
        break
      fi
    done
  fi
  hts_gum_pick --height="$(hts_gum_choose_height)" --header "$header" \
    "${sel_args[@]}" "${modules[@]}"
}

hts_tui_main() {
  hts_require_deps tui || return 1
  hts_ensure_config
  unsetopt xtrace verbose 2>/dev/null || true

  hts_tui_enter
  trap 'hts_tui_leave' EXIT INT TERM

  while true; do
    unsetopt xtrace verbose 2>/dev/null || true
    hts_tui_clear
    local choice="" active
    active="$(hts_active_profile 2>/dev/null || print default)"
    choice="$(
      hts_gum_pick \
        --height="$(hts_gum_choose_height)" \
        --header "Harness Test Suite  ·  profile: ${active}" \
        "Run test suite" \
        "Add pipeline" \
        "List pipelines" \
        "Remove pipeline" \
        "Profiles" \
        "Settings" \
        "Quit"
    )" || { hts_tui_leave; trap - EXIT INT TERM; return 0; }

    case "$choice" in
      "Run test suite")   hts_tui_run_suite || true ;;
      "Add pipeline")     hts_tui_matrix_add || true ;;
      "List pipelines")   hts_tui_list_matrix || true ;;
      "Remove pipeline")  hts_tui_remove_entry || true ;;
      "Profiles")         hts_tui_profiles || true ;;
      "Settings")         hts_tui_settings || true ;;
      "Quit"|*)
        hts_tui_leave
        trap - EXIT INT TERM
        return 0
        ;;
    esac
  done
}

hts_tui_run_suite() {
  local profile module tech="" set_="" aliases="" dry_run=0 open_urls=0 mode

  profile="$(hts_tui_profile)" || return 1
  hts_profile_use "$profile" >/dev/null

  local modules=()
  local m
  while IFS= read -r m; do
    [[ -n "$m" ]] && modules+=("$m")
  done < <(hts_list_modules "$profile")

  if (( ${#modules[@]} == 0 )); then
    hts_tui_clear
    if gum confirm "No pipelines yet. Add one now?"; then
      hts_tui_matrix_add "$profile" || return 0
    fi
    return 0
  fi

  hts_tui_clear
  module="$(hts_tui_pick_module "$profile" "Run · module")" || return 1

  hts_tui_clear
  mode="$(
    hts_gum_pick \
      --height="$(hts_gum_choose_height)" \
      --header "Run $module ($profile)" \
      "Run" \
      "Dry-run" \
      "Filter then run" \
      "Cancel"
  )" || return 0

  case "$mode" in
    Cancel) return 0 ;;
    Dry-run) dry_run=1 ;;
    "Filter then run")
      hts_tui_clear
      tech="$(hts_gum_input --placeholder "tech (blank=any)")" || return 0
      set_="$(hts_gum_input --placeholder "set (blank=any)")" || return 0
      aliases="$(hts_gum_input --placeholder "aliases comma-separated (blank=any)")" || return 0
      hts_tui_clear
      if gum confirm --default=false "Dry-run only?"; then
        dry_run=1
      fi
      ;;
    Run) dry_run=0 ;;
  esac

  if hts_open_urls_enabled && [[ "$dry_run" != "1" ]]; then
    open_urls=1
  fi

  hts_tui_clear
  {
    print -- "profile=$profile  module=$module"
    [[ -n "$tech" ]] && print -- "tech=$tech"
    [[ -n "$set_" ]] && print -- "set=$set_"
    [[ -n "$aliases" ]] && print -- "alias=$aliases"
    (( dry_run )) && print -- "mode=dry-run"
    print -- ""
    hts_preview_matrix "$profile" "$module" "$tech" "$set_" "$aliases"
  } | hts_tui_show
  print -- "" >/dev/tty 2>/dev/null || print -- ""
  gum confirm "Continue?" || return 0

  hts_tui_clear
  hts_run_matrix "$profile" "$module" "$tech" "$set_" "$aliases" "$dry_run" "$open_urls"
  hts_tui_pause "Enter — back to menu"
}

hts_tui_parse_entry_form() {
  # stdin: key: value form → prints TSV:
  # module type alias trigger tech set org project pipeline branch
  local raw
  raw="$(/bin/cat)"
  HTS_FORM_INPUT="$raw" hts_python - <<'PY'
import os
raw = os.environ.get("HTS_FORM_INPUT") or ""
data = {}
for line in raw.splitlines():
    s = line.strip()
    if not s or s.startswith("#") or ":" not in s:
        continue
    k, v = s.split(":", 1)
    data[k.strip().lower()] = v.strip()

def g(*keys, default=""):
    for k in keys:
        if data.get(k):
            return data[k]
    return default

etype = g("type", default="github").lower()
if etype in ("webhook", "custom_webhook"):
    etype = "custom"
if etype not in ("github", "custom"):
    etype = "github"

vals = [
    g("module", default="ci"),
    etype,
    g("alias"),
    g("trigger", "input_set", "inputset"),
    g("tech", default="java"),
    g("set", default="shared"),
    g("org", "pipeline.org"),
    g("project", "pipeline.project"),
    g("pipeline", "pipeline_id", "identifier", "pipeline.identifier"),
    g("branch"),
]
print("\t".join(vals))
PY
}

hts_tui_matrix_add() {
  local profile="${1:-}"
  if [[ -z "$profile" ]]; then
    profile="$(hts_tui_profile)" || return 1
  fi
  hts_profile_use "$profile" >/dev/null

  local def_mod form module etype alias trigger tech set_ org project identifier branch
  def_mod="$(hts_default_module)"

  hts_tui_clear
  form="$(
    gum write \
      --header "Add pipeline  ·  profile ${profile}  ·  Ctrl+D to save, Esc cancel" \
      --height 16 \
      --value "$(/bin/cat <<EOF
module: ${def_mod}
type: github
alias: 
tech: java
set: shared
org: 
project: 
pipeline: 
trigger: 
branch: 
EOF
)"
  )" || return 0

  local parsed
  parsed="$(print -- "$form" | hts_tui_parse_entry_form)"
  IFS=$'\t' read -r module etype alias trigger tech set_ org project identifier branch <<<"$parsed"

  if [[ -z "$alias" || -z "$org" || -z "$project" || -z "$identifier" ]]; then
    hts_tui_clear
    hts_gum_box_error "Need alias, org, project, and pipeline."
    hts_tui_pause
    return 1
  fi
  if [[ "$etype" == "custom" && -z "$trigger" ]]; then
    hts_tui_clear
    hts_gum_box_error "type=custom requires trigger."
    hts_tui_pause
    return 1
  fi

  hts_matrix_add "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" "$branch" >/dev/null
  hts_cfg_set_str '.defaults.module' "$module" >/dev/null 2>&1 || true
  hts_tui_clear
  hts_gum_box "Saved $alias" "type=$etype  module=$module"
  # brief pause only so the confirmation is readable
  hts_tui_pause "Enter — done"
}

hts_tui_list_matrix() {
  local profile module
  profile="$(hts_tui_profile)" || return 1
  hts_profile_use "$profile" >/dev/null

  hts_tui_clear
  module="$(hts_tui_pick_module "$profile" "List · module")" || {
    hts_gum_box "No pipelines yet."
    hts_tui_pause
    return 0
  }
  hts_tui_clear
  hts_matrix_list "$profile" "$module" 2>/dev/null | hts_tui_show
  hts_tui_pause
}

hts_tui_remove_entry() {
  local profile module alias aliases=() a
  profile="$(hts_tui_profile)" || return 1
  hts_profile_use "$profile" >/dev/null

  hts_tui_clear
  module="$(hts_tui_pick_module "$profile" "Remove · module")" || {
    hts_gum_box "No pipelines yet."
    hts_tui_pause
    return 0
  }

  while IFS= read -r a; do
    [[ -n "$a" ]] && aliases+=("$a")
  done < <(
    hts_matrix_entries_json "$profile" "$module" | hts_python -c '
import json,sys
for e in json.load(sys.stdin):
    al=e.get("alias") or ""
    if al: print(al)
'
  )

  if (( ${#aliases[@]} == 0 )); then
    hts_tui_clear
    hts_gum_box "Matrix is empty."
    hts_tui_pause
    return 0
  fi

  hts_tui_clear
  alias="$(hts_gum_pick --height="$(hts_gum_choose_height)" --header "Remove alias" "${aliases[@]}")" || return 0
  gum confirm "Delete '$alias'?" || return 0
  hts_matrix_remove "$profile" "$module" "$alias" >/dev/null
  hts_tui_clear
  hts_gum_box "Removed: $alias"
  hts_tui_pause
}

hts_tui_profiles() {
  while true; do
    hts_tui_clear
    local action active
    active="$(hts_active_profile 2>/dev/null || print -)"
    action="$(
      hts_gum_pick \
        --height="$(hts_gum_choose_height)" \
        --header "Profiles  ·  active: ${active}" \
        "Switch profile" \
        "List profiles" \
        "Init / create (hctl)" \
        "Doctor" \
        "Back"
    )" || return 0

    case "$action" in
      "Switch profile")
        local names=() n p
        while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(hts_profile_names)
        (( ${#names[@]} )) || { hts_gum_box_error "No profiles."; hts_tui_pause; continue; }
        hts_tui_clear
        p="$(hts_gum_pick --height="$(hts_gum_choose_height)" --header "Switch to" --selected "$active" "${names[@]}")" || continue
        hts_profile_use "$p" >/dev/null
        ;;
      "List profiles")
        hts_tui_clear
        hts_profile_list 2>/dev/null | hts_tui_show
        hts_tui_pause
        ;;
      "Init / create (hctl)")
        hts_tui_clear
        local name
        name="$(hts_gum_input --placeholder "profile name (blank=default flow)")" || continue
        hts_profile_init "${name:-}"
        hts_tui_pause
        ;;
      "Doctor")
        hts_tui_clear
        hts_profile_doctor | gum pager
        ;;
      Back|*) return 0 ;;
    esac
  done
}

hts_tui_settings() {
  while true; do
    hts_tui_clear
    local action mod urls
    mod="$(hts_default_module)"
    if hts_open_urls_enabled; then urls=on; else urls=off; fi
    action="$(
      hts_gum_pick \
        --height="$(hts_gum_choose_height)" \
        --header "Settings  ·  module=${mod}  open_urls=${urls}" \
        "Set default module" \
        "Toggle open_urls" \
        "Back"
    )" || return 0

    case "$action" in
      "Set default module")
        hts_tui_clear
        mod="$(hts_gum_input --value "$mod" --placeholder "default module")" || continue
        [[ -n "$mod" ]] || continue
        hts_cfg_set_str '.defaults.module' "$mod"
        ;;
      "Toggle open_urls")
        local new
        if hts_open_urls_enabled; then new=false; else new=true; fi
        hts_cfg_set_str '.defaults.open_urls' "$new"
        ;;
      Back|*) return 0 ;;
    esac
  done
}
