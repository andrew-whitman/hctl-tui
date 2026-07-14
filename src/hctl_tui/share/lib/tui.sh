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
  # Reset attrs, home cursor, erase screen + scrollback (where supported).
  # Always target /dev/tty so leftovers on stdout don't coexist with the UI.
  {
    printf '\e[0m\e[H\e[2J\e[3J'
  } >/dev/tty 2>/dev/null || printf '\e[0m\e[H\e[2J\e[3J'
}

hts_tui_pause() {
  # Brief acknowledgment before returning to a menu
  local msg="${1:-Press Enter to continue}"
  print -- "" >/dev/tty 2>/dev/null || print -- ""
  gum input --placeholder "$msg" --value "" >/dev/null || true
}

hts_gum_choose_height() {
  local r
  r="$(hts_term_rows)"
  r=$(( r - 8 ))
  (( r < 5 )) && r=5
  (( r > 16 )) && r=16
  print -- "$r"
}

# Keep stdout for the selection; give gum the real keyboard via /dev/tty.
hts_gum_pick() {
  unsetopt xtrace verbose 2>/dev/null || true
  if [[ -r /dev/tty ]]; then
    gum choose "$@" </dev/tty
  else
    gum choose "$@"
  fi
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
    local choice=""
    choice="$(
      hts_gum_pick \
        --height="$(hts_gum_choose_height)" \
        --header "Harness Test Suite Orchestration" \
        "Run test suite" \
        "Manage profiles" \
        "Manage pipelines" \
        "Settings" \
        "Quit"
    )" || { hts_tui_leave; trap - EXIT INT TERM; return 0; }

    case "$choice" in
      "Run test suite")     hts_tui_run_suite || true ;;
      "Manage profiles")    hts_tui_profiles || true ;;
      "Manage pipelines")   hts_tui_pipelines || true ;;
      "Settings")           hts_tui_settings || true ;;
      "Quit"|*)
        hts_tui_leave
        trap - EXIT INT TERM
        return 0
        ;;
    esac
  done
}

hts_tui_pick_profile() {
  local names=()
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(hts_profile_names)

  hts_tui_clear
  if (( ${#names[@]} == 0 )); then
    hts_gum_box_error \
      "No hctl profiles found" "Creating one via hctl init..."
    print -- "" >/dev/tty 2>/dev/null || print -- ""
    hts_profile_init
    hts_active_profile
    return 0
  fi

  local active
  active="$(hts_active_profile)"
  local picked
  picked="$(
    hts_gum_pick \
      --height="$(hts_gum_choose_height)" \
      --header "$(hts_trunc "Profile (active: $active)" "$(( $(hts_term_cols) - 4 ))")" \
      "${names[@]}"
  )" || return 1
  print -- "$picked"
}

hts_tui_run_suite() {
  local profile module tech set_ aliases dry_run=0 open_urls=0

  profile="$(hts_tui_pick_profile)" || return 1
  hts_profile_use "$profile" >/dev/null

  local modules=()
  local m
  while IFS= read -r m; do
    [[ -n "$m" ]] && modules+=("$m")
  done < <(hts_list_modules "$profile")

  if (( ${#modules[@]} == 0 )); then
    hts_tui_clear
    hts_gum_box_warn \
      "No matrices for profile '$profile'."
    print -- "" >/dev/tty 2>/dev/null || print -- ""
    if gum confirm "Create a matrix entry now?"; then
      hts_tui_matrix_add "$profile"
      modules=()
      while IFS= read -r m; do
        [[ -n "$m" ]] && modules+=("$m")
      done < <(hts_list_modules "$profile")
    else
      return 0
    fi
  fi

  (( ${#modules[@]} == 0 )) && return 0

  hts_tui_clear
  module="$(hts_gum_pick --height="$(hts_gum_choose_height)" --header "Module" "${modules[@]}")" || return 1

  hts_tui_clear
  if gum confirm --default=false "Filter by tech/set/alias?"; then
    hts_tui_clear
    tech="$(gum input --placeholder "tech (blank=any)")" || return 1
    hts_tui_clear
    set_="$(gum input --placeholder "set (blank=any)")" || return 1
    hts_tui_clear
    aliases="$(gum input --placeholder "aliases comma-separated (blank=any)")" || return 1
  else
    tech=""; set_=""; aliases=""
  fi

  hts_tui_clear
  if gum confirm --default=false "Dry-run only?"; then
    dry_run=1
  fi

  if hts_open_urls_enabled && [[ "$dry_run" != "1" ]]; then
    open_urls=1
  fi

  hts_tui_clear
  {
    local tw
    tw="$(hts_term_cols)"
    print -- "$(hts_trunc "Preview - profile=$profile module=$module" "$tw")"
    [[ -n "$tech" ]] && print -- "$(hts_trunc "tech=$tech" "$tw")"
    [[ -n "$set_" ]] && print -- "$(hts_trunc "set=$set_" "$tw")"
    [[ -n "$aliases" ]] && print -- "$(hts_trunc "alias=$aliases" "$tw")"
    (( dry_run )) && print -- "mode=dry-run"
    print -- ""
    hts_preview_matrix "$profile" "$module" "$tech" "$set_" "$aliases"
  } | hts_tui_show
  print -- "" >/dev/tty 2>/dev/null || print -- ""
  gum confirm "Run this?" || return 0

  hts_tui_clear
  hts_run_matrix "$profile" "$module" "$tech" "$set_" "$aliases" "$dry_run" "$open_urls"
  hts_tui_pause "Press Enter to return to menu"
}

hts_tui_profiles() {
  hts_tui_clear
  local action
  action="$(
    hts_gum_pick \
      --height="$(hts_gum_choose_height)" \
      --header "Manage profiles" \
      "List profiles" \
      "Switch active profile" \
      "Init / create profile (hctl)" \
      "Doctor" \
      "Back"
  )" || return 0

  case "$action" in
    "List profiles")
      hts_tui_clear
      hts_profile_list 2>/dev/null | hts_tui_show
      hts_tui_pause
      ;;
    "Switch active profile")
      local p
      p="$(hts_tui_pick_profile)" || return 0
      hts_profile_use "$p"
      hts_tui_clear
      hts_gum_box "Active profile: $p"
      hts_tui_pause
      ;;
    "Init / create profile (hctl)")
      hts_tui_clear
      local name
      name="$(gum input --placeholder "profile name (blank=default flow)")" || return 0
      hts_profile_init "${name:-}"
      hts_tui_pause
      ;;
    "Doctor")
      hts_tui_clear
      hts_profile_doctor | gum pager
      ;;
    *) return 0 ;;
  esac
}

hts_tui_matrix_progress() {
  # Render progress card only (caller clears the screen first).
  # Args: profile module alias trigger tech set org project identifier [type]
  local profile="$1" module="$2" alias="$3" trigger="$4" tech="$5" set_="$6" org="$7" project="$8" identifier="$9"
  local etype="${10:-}"
  local line filled pending tw vw

  tw="$(hts_term_cols)"
  vw=$(( tw - 16 ))
  (( vw < 12 )) && vw=12

  filled=()
  pending=()
  [[ -n "$module" ]]     && filled+=("module:     $(hts_trunc "$module" "$vw")")     || pending+=("module")
  [[ -n "$etype" ]]      && filled+=("type:       $(hts_trunc "$etype" "$vw")")      || pending+=("type")
  [[ -n "$alias" ]]      && filled+=("alias:      $(hts_trunc "$alias" "$vw")")      || pending+=("alias")
  if [[ "$etype" == "custom" ]]; then
    [[ -n "$trigger" ]]  && filled+=("trigger:    $(hts_trunc "$trigger" "$vw")")    || pending+=("trigger")
  elif [[ -n "$etype" ]]; then
    [[ -n "$trigger" ]]  && filled+=("input_set:  $(hts_trunc "$trigger" "$vw")")    || filled+=("input_set:  (none)")
  fi
  [[ -n "$tech" ]]       && filled+=("tech:       $(hts_trunc "$tech" "$vw")")       || pending+=("tech")
  [[ -n "$set_" ]]       && filled+=("set:        $(hts_trunc "$set_" "$vw")")       || pending+=("set")
  [[ -n "$org" ]]        && filled+=("org:        $(hts_trunc "$org" "$vw")")        || pending+=("org")
  [[ -n "$project" ]]    && filled+=("project:    $(hts_trunc "$project" "$vw")")    || pending+=("project")
  [[ -n "$identifier" ]] && filled+=("pipeline:   $(hts_trunc "$identifier" "$vw")") || pending+=("pipeline")

  {
    print -- "New matrix entry"
    print -- "profile: $(hts_trunc "$profile" "$vw")"
    print -- ""
    if (( ${#filled[@]} )); then
      print -- "Entered:"
      for line in "${filled[@]}"; do
        print -- "  * $line"
      done
    else
      print -- "Entered: (none yet)"
    fi
    if (( ${#pending[@]} )); then
      print -- ""
      print -- "Still needed: $(hts_trunc "${(j:, :)pending}" "$vw")"
    else
      print -- ""
      print -- "All fields complete - confirm to save."
    fi
  } | hts_tui_show
  print -- "" >/dev/tty 2>/dev/null || print -- ""
}

hts_tui_matrix_prompt() {
  # Clear, show progress, ask one field.
  # usage: hts_tui_matrix_prompt <var_name> <placeholder> [--optional] profile module alias trigger tech set org project identifier [type]
  local __var="$1" __ph="$2"
  shift 2
  local __optional=0
  if [[ "${1:-}" == "--optional" ]]; then
    __optional=1
    shift
  fi
  hts_tui_clear
  hts_tui_matrix_progress "$@"
  local __val
  __val="$(gum input --placeholder "$__ph")" || return 1
  if [[ -z "$__val" && "$__optional" != "1" ]]; then
    hts_tui_clear
    hts_gum_box_error "${__var} is required."
    hts_tui_pause
    return 1
  fi
  eval "${__var}=${(q)__val}"
}

hts_tui_matrix_add() {
  local profile="${1:-$(hts_active_profile)}"
  local module="" alias="" trigger="" tech="" set_="" org="" project="" identifier="" etype=""

  hts_tui_matrix_prompt module "module (e.g. ci, cd)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1

  hts_tui_clear
  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype"
  etype="$(
    hts_gum_pick \
      --height="$(hts_gum_choose_height)" \
      --header "How should hts fire this pipeline?" \
      "github — execute pipeline (GitHub / ad-hoc runs)" \
      "custom — Harness custom webhook trigger"
  )" || return 1
  case "$etype" in
    custom*) etype="custom" ;;
    *) etype="github" ;;
  esac

  hts_tui_matrix_prompt alias "alias (short name for this matrix entry)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1
  if [[ "$etype" == "custom" ]]; then
    hts_tui_matrix_prompt trigger "custom trigger identifier (required)" \
      "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1
  else
    hts_tui_matrix_prompt trigger --optional "optional input set id (blank=none)" \
      "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1
  fi
  hts_tui_matrix_prompt tech "tech (e.g. java, go, python)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1
  hts_tui_matrix_prompt set_ "set (e.g. shared, exclusive)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1
  hts_tui_matrix_prompt org "pipeline org (Harness orgIdentifier)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1
  hts_tui_matrix_prompt project "pipeline project (Harness projectIdentifier)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1
  hts_tui_matrix_prompt identifier "pipeline identifier (Harness pipelineIdentifier)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" || return 1

  hts_tui_clear
  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype"
  gum confirm "Save this matrix entry?" || return 0

  hts_matrix_add "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" "$etype" >/dev/null
  hts_tui_clear
  local path_show
  path_show="$(hts_trunc "matrices/$profile/$module.yaml" "$(( $(hts_term_cols) - 8 ))")"
  hts_gum_box \
    "$(hts_trunc "Saved $alias ($etype)" "$(( $(hts_term_cols) - 8 ))")" "$path_show"
  hts_tui_pause
}

hts_tui_pipelines() {
  local profile
  profile="$(hts_tui_pick_profile)" || return 1
  hts_profile_use "$profile" >/dev/null

  hts_tui_clear
  local action
  action="$(
    hts_gum_pick \
      --height="$(hts_gum_choose_height)" \
      --header "Manage pipelines (profile: $(hts_trunc "$profile" 24))" \
      "List matrix" \
      "Add / update entry" \
      "Remove entry" \
      "Back"
  )" || return 0

  case "$action" in
    "List matrix")
      local modules=() m module
      while IFS= read -r m; do [[ -n "$m" ]] && modules+=("$m"); done < <(hts_list_modules "$profile")
      hts_tui_clear
      if (( ${#modules[@]} == 0 )); then
        hts_gum_box "No matrices yet."
        hts_tui_pause
        return 0
      fi
      module="$(hts_gum_pick --height="$(hts_gum_choose_height)" --header "Module" "${modules[@]}")" || return 0
      hts_tui_clear
      hts_matrix_list "$profile" "$module" 2>/dev/null | hts_tui_show
      hts_tui_pause
      ;;
    "Add / update entry")
      hts_tui_matrix_add "$profile"
      ;;
    "Remove entry")
      local modules=() m module alias
      while IFS= read -r m; do [[ -n "$m" ]] && modules+=("$m"); done < <(hts_list_modules "$profile")
      hts_tui_clear
      (( ${#modules[@]} == 0 )) && {
        hts_gum_box "No matrices."
        hts_tui_pause
        return 0
      }
      module="$(hts_gum_pick --height="$(hts_gum_choose_height)" --header "Module" "${modules[@]}")" || return 0
      hts_tui_clear
      alias="$(gum input --placeholder "alias to remove")" || return 0
      hts_matrix_remove "$profile" "$module" "$alias"
      hts_tui_clear
      hts_gum_box "Removed: $alias"
      hts_tui_pause
      ;;
    *) return 0 ;;
  esac
}

hts_tui_settings() {
  hts_tui_clear
  local action
  action="$(
    hts_gum_pick \
      --height="$(hts_gum_choose_height)" \
      --header "Settings" \
      "Set default module" \
      "Toggle open_urls" \
      "Back"
  )" || return 0

  case "$action" in
    "Set default module")
      hts_tui_clear
      local mod
      mod="$(gum input --placeholder "default module (currently: $(hts_default_module))")" || return 0
      [[ -n "$mod" ]] || return 0
      hts_cfg_set_str '.defaults.module' "$mod"
      hts_tui_clear
      hts_gum_box "default module: $mod"
      hts_tui_pause
      ;;
    "Toggle open_urls")
      local cur new
      if hts_open_urls_enabled; then cur=true; else cur=false; fi
      if [[ "$cur" == "true" ]]; then new=false; else new=true; fi
      hts_cfg_set_str '.defaults.open_urls' "$new"
      hts_tui_clear
      hts_gum_box "open_urls: $new"
      hts_tui_pause
      ;;
    *) return 0 ;;
  esac
}
