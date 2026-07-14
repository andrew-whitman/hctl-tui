# gum-based TUI flows for hctl-tui.
# shellcheck shell=zsh

# Use the alternate screen buffer so menus redraw in place (like vim/htop)
# instead of stacking boxes in the scrollback.
hts_tui_enter() {
  printf '\e[?1049h' >/dev/tty 2>/dev/null || printf '\e[?1049h'
  hts_tui_clear
}

hts_tui_leave() {
  printf '\e[?1049l' >/dev/tty 2>/dev/null || printf '\e[?1049l'
}

hts_tui_clear() {
  # cursor home + erase screen + clear scrollback (where supported)
  printf '\e[H\e[2J\e[3J' >/dev/tty 2>/dev/null || printf '\e[H\e[2J\e[3J'
}

hts_tui_pause() {
  # Brief acknowledgment before returning to a menu
  local msg="${1:-Press Enter to continue}"
  print -- ""
  gum input --placeholder "$msg" --value "" >/dev/null || true
}

hts_tui_main() {
  hts_require_deps tui || return 1
  hts_ensure_config

  hts_tui_enter
  trap 'hts_tui_leave' EXIT INT TERM

  while true; do
    hts_tui_clear
    local choice
    choice="$(
      gum choose \
        --header "hctl-tui — Harness test-suite orchestration (via hctl)" \
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
    gum style --border rounded --padding "0 1" --border-foreground 196 \
      "No hctl profiles found" "Creating one via hctl init…"
    print -- ""
    hts_profile_init
    hts_active_profile
    return 0
  fi

  local active
  active="$(hts_active_profile)"
  local picked
  picked="$(gum choose --header "Profile (active: $active)" "${names[@]}")" || return 1
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
    gum style --border rounded --padding "0 1" --border-foreground 214 \
      "No matrices for profile '$profile'."
    print -- ""
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
  module="$(gum choose --header "Module" "${modules[@]}")" || return 1

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
    print -- "Preview — profile=$profile module=$module"
    [[ -n "$tech" ]] && print -- "tech=$tech"
    [[ -n "$set_" ]] && print -- "set=$set_"
    [[ -n "$aliases" ]] && print -- "alias=$aliases"
    (( dry_run )) && print -- "mode=dry-run"
    print -- ""
    hts_preview_matrix "$profile" "$module" "$tech" "$set_" "$aliases"
  } | gum style --border rounded --padding "0 1" --border-foreground 212
  print -- ""
  gum confirm "Run this?" || return 0

  hts_tui_clear
  hts_run_matrix "$profile" "$module" "$tech" "$set_" "$aliases" "$dry_run" "$open_urls"
  hts_tui_pause "Press Enter to return to menu"
}

hts_tui_profiles() {
  hts_tui_clear
  local action
  action="$(
    gum choose \
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
      hts_profile_list | gum style --border rounded --padding "0 1" --border-foreground 212
      hts_tui_pause
      ;;
    "Switch active profile")
      local p
      p="$(hts_tui_pick_profile)" || return 0
      hts_profile_use "$p"
      hts_tui_clear
      gum style --border rounded --padding "0 1" --border-foreground 212 "Active profile: $p"
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
  local profile="$1" module="$2" alias="$3" trigger="$4" tech="$5" set_="$6" org="$7" project="$8" identifier="$9"
  local line filled pending

  filled=()
  pending=()
  [[ -n "$module" ]]     && filled+=("module:     $module")     || pending+=("module")
  [[ -n "$alias" ]]      && filled+=("alias:      $alias")      || pending+=("alias")
  [[ -n "$trigger" ]]    && filled+=("trigger:    $trigger")    || pending+=("trigger")
  [[ -n "$tech" ]]       && filled+=("tech:       $tech")       || pending+=("tech")
  [[ -n "$set_" ]]       && filled+=("set:        $set_")       || pending+=("set")
  [[ -n "$org" ]]        && filled+=("org:        $org")        || pending+=("org")
  [[ -n "$project" ]]    && filled+=("project:    $project")    || pending+=("project")
  [[ -n "$identifier" ]] && filled+=("pipeline:   $identifier") || pending+=("pipeline")

  {
    print -- "New matrix entry  (profile: $profile)"
    print -- ""
    if (( ${#filled[@]} )); then
      print -- "Entered:"
      for line in "${filled[@]}"; do
        print -- "  ✓ $line"
      done
    else
      print -- "Entered: (none yet)"
    fi
    if (( ${#pending[@]} )); then
      print -- ""
      print -- "Still needed: ${(j:, :)pending}"
    else
      print -- ""
      print -- "All fields complete — confirm to save."
    fi
  } | gum style --border rounded --padding "0 1" --border-foreground 212
  print -- ""
}

hts_tui_matrix_prompt() {
  # Clear, show progress, ask one field.
  # usage: hts_tui_matrix_prompt <var_name> <placeholder> profile module alias trigger tech set org project identifier
  local __var="$1" __ph="$2"
  shift 2
  hts_tui_clear
  hts_tui_matrix_progress "$@"
  local __val
  __val="$(gum input --placeholder "$__ph")" || return 1
  [[ -n "$__val" ]] || {
    hts_tui_clear
    gum style --border rounded --padding "0 1" --border-foreground 196 "${__var} is required."
    hts_tui_pause
    return 1
  }
  eval "${__var}=${(q)__val}"
}

hts_tui_matrix_add() {
  local profile="${1:-$(hts_active_profile)}"
  local module="" alias="" trigger="" tech="" set_="" org="" project="" identifier=""

  hts_tui_matrix_prompt module "module (e.g. ci, cd)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" || return 1
  hts_tui_matrix_prompt alias "alias (short name for this matrix entry)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" || return 1
  hts_tui_matrix_prompt trigger "trigger (Harness custom trigger identifier)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" || return 1
  hts_tui_matrix_prompt tech "tech (e.g. java, go, python)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" || return 1
  hts_tui_matrix_prompt set_ "set (e.g. shared, exclusive)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" || return 1
  hts_tui_matrix_prompt org "pipeline org (Harness orgIdentifier)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" || return 1
  hts_tui_matrix_prompt project "pipeline project (Harness projectIdentifier)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" || return 1
  hts_tui_matrix_prompt identifier "pipeline identifier (Harness pipelineIdentifier)" \
    "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier" || return 1

  hts_tui_clear
  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  gum confirm "Save this matrix entry?" || return 0

  hts_matrix_add "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  hts_tui_clear
  gum style --border rounded --padding "0 1" --border-foreground 212 \
    "Saved $alias" "matrices/$profile/$module.yaml"
  hts_tui_pause
}

hts_tui_pipelines() {
  local profile
  profile="$(hts_tui_pick_profile)" || return 1
  hts_profile_use "$profile" >/dev/null

  hts_tui_clear
  local action
  action="$(
    gum choose \
      --header "Manage pipelines (profile: $profile)" \
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
        gum style --border rounded --padding "0 1" "No matrices yet."
        hts_tui_pause
        return 0
      fi
      module="$(gum choose --header "Module" "${modules[@]}")" || return 0
      hts_tui_clear
      hts_matrix_list "$profile" "$module" | gum style --border rounded --padding "0 1" --border-foreground 212
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
        gum style --border rounded --padding "0 1" "No matrices."
        hts_tui_pause
        return 0
      }
      module="$(gum choose --header "Module" "${modules[@]}")" || return 0
      hts_tui_clear
      alias="$(gum input --placeholder "alias to remove")" || return 0
      hts_matrix_remove "$profile" "$module" "$alias"
      hts_tui_clear
      gum style --border rounded --padding "0 1" --border-foreground 212 "Removed: $alias"
      hts_tui_pause
      ;;
    *) return 0 ;;
  esac
}

hts_tui_settings() {
  hts_tui_clear
  local action
  action="$(
    gum choose \
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
      gum style --border rounded --padding "0 1" --border-foreground 212 "default module: $mod"
      hts_tui_pause
      ;;
    "Toggle open_urls")
      local cur new
      if hts_open_urls_enabled; then cur=true; else cur=false; fi
      if [[ "$cur" == "true" ]]; then new=false; else new=true; fi
      hts_cfg_set_str '.defaults.open_urls' "$new"
      hts_tui_clear
      gum style --border rounded --padding "0 1" --border-foreground 212 "open_urls: $new"
      hts_tui_pause
      ;;
    *) return 0 ;;
  esac
}
