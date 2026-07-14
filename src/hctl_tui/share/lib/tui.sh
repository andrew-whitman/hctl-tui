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
  hts_gum input --placeholder "$msg" --value "" >/dev/null || true
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
    hts_gum choose "$@" </dev/tty
  else
    hts_gum choose "$@"
  fi
}

hts_gum_input() {
  if [[ -r /dev/tty ]]; then
    hts_gum input "$@" </dev/tty
  else
    hts_gum input "$@"
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
    if hts_gum confirm "No pipelines yet. Add one now?"; then
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
      if hts_gum confirm --default=false "Dry-run only?"; then
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
  hts_gum confirm "Continue?" || return 0

  hts_tui_clear
  hts_run_matrix "$profile" "$module" "$tech" "$set_" "$aliases" "$dry_run" "$open_urls"
  hts_tui_pause "Enter — back to menu"
}

hts_tui_ask() {
  # usage: hts_tui_ask <header> <placeholder> [required=1]
  local header="$1" ph="$2" required="${3:-1}" val=""
  val="$(hts_gum_input --header "$header" --placeholder "$ph")" || return 1
  val="$(hts_trim "$val")"
  if [[ -z "$val" && "$required" == "1" ]]; then
    return 1
  fi
  print -- "$val"
}

hts_tui_matrix_add() {
  local profile="${1:-}"
  if [[ -z "$profile" ]]; then
    profile="$(hts_tui_profile)" || return 1
  fi
  hts_profile_use "$profile" >/dev/null

  local module alias org project identifier trigger mset branch
  module="$(hts_default_module)"

  hts_tui_clear
  {
    print -- "Add pipeline"
    print -- "profile=$profile  module=$module"
    print -- "Required: alias, org, project, pipeline, trigger, set"
    print -- "Optional: branch (needed for git-backed / remote pipelines)"
  } | hts_tui_show
  print -- "" >/dev/tty 2>/dev/null || print -- ""

  alias="$(hts_tui_ask "1/7 Alias" "short name")" || return 0
  org="$(hts_tui_ask "2/7 Org" "orgIdentifier")" || return 0
  project="$(hts_tui_ask "3/7 Project" "projectIdentifier")" || return 0
  identifier="$(hts_tui_ask "4/7 Pipeline" "pipelineIdentifier")" || return 0
  trigger="$(hts_tui_ask "5/7 Trigger" "triggerIdentifier")" || return 0
  mset="$(hts_tui_ask "6/7 Set" "matrix set (e.g. shared)")" || return 0
  branch="$(hts_tui_ask "7/7 Branch (optional)" "e.g. main — leave empty if inline")" || return 0

  [[ -n "$alias" && -n "$org" && -n "$project" && -n "$identifier" && -n "$trigger" && -n "$mset" ]] || {
    hts_gum_box_error "Alias, org, project, pipeline, trigger, and set are required."
    hts_tui_pause
    return 0
  }

  hts_matrix_add "$profile" "$module" "$alias" "$trigger" "java" "$mset" \
    "$org" "$project" "$identifier" "github" "$branch" >/dev/null
  hts_tui_clear
  hts_gum_box \
    "Saved: $alias" \
    "$org / $project / $identifier" \
    "trigger: $trigger  set: $mset  branch: ${branch:-(none)}"
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
  hts_gum confirm "Delete '$alias'?" || return 0
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
        hts_profile_doctor | hts_gum pager
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
