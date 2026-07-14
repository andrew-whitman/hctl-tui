# gum-based TUI flows for hctl-tui.
# shellcheck shell=zsh

hts_tui_header() {
  gum style --border rounded --padding "0 2" --border-foreground 212 \
    "hctl-tui" "Harness test-suite orchestration (via hctl)"
}

hts_tui_main() {
  hts_require_deps tui || return 1
  hts_ensure_config

  while true; do
    print -- ""
    hts_tui_header
    local choice
    choice="$(
      gum choose \
        "Run test suite" \
        "Manage profiles" \
        "Manage pipelines" \
        "Settings" \
        "Quit"
    )" || return 0

    case "$choice" in
      "Run test suite")     hts_tui_run_suite || true ;;
      "Manage profiles")    hts_tui_profiles || true ;;
      "Manage pipelines")   hts_tui_pipelines || true ;;
      "Settings")           hts_tui_settings || true ;;
      "Quit"|*)             return 0 ;;
    esac
  done
}

hts_tui_pick_profile() {
  local names=()
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(hts_profile_names)

  if (( ${#names[@]} == 0 )); then
    gum style --foreground 196 "No hctl profiles found. Creating one…"
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
    gum style --foreground 214 "No matrices for profile '$profile'."
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

  local default_mod
  default_mod="$(hts_default_module)"
  module="$(gum choose --header "Module" "${modules[@]}")" || return 1

  # Optional filters
  if gum confirm --default=false "Filter by tech/set/alias?"; then
    tech="$(gum input --placeholder "tech (blank=any)" --value "")"
    set_="$(gum input --placeholder "set (blank=any)" --value "")"
    aliases="$(gum input --placeholder "aliases comma-separated (blank=any)" --value "")"
  else
    tech=""; set_=""; aliases=""
  fi

  if gum confirm --default=false "Dry-run only?"; then
    dry_run=1
  fi

  if hts_open_urls_enabled && [[ "$dry_run" != "1" ]]; then
    open_urls=1
  fi

  print -- ""
  gum style --bold "Preview"
  hts_preview_matrix "$profile" "$module" "$tech" "$set_" "$aliases" | gum style --border rounded --padding "0 1"

  gum confirm "Run this?" || return 0
  hts_run_matrix "$profile" "$module" "$tech" "$set_" "$aliases" "$dry_run" "$open_urls"
}

hts_tui_profiles() {
  local action
  action="$(
    gum choose \
      "List profiles" \
      "Switch active profile" \
      "Init / create profile (hctl)" \
      "Doctor" \
      "Back"
  )" || return 0

  case "$action" in
    "List profiles")
      hts_profile_list | gum pager
      ;;
    "Switch active profile")
      local p
      p="$(hts_tui_pick_profile)" || return 0
      hts_profile_use "$p"
      gum style --foreground 212 "Active: $p"
      ;;
    "Init / create profile (hctl)")
      local name
      name="$(gum input --placeholder "profile name (blank=default flow)" --value "")"
      hts_profile_init "${name:-}"
      ;;
    "Doctor")
      hts_profile_doctor | gum pager
      ;;
    *) return 0 ;;
  esac
}

hts_tui_matrix_progress() {
  # Show filled vs pending fields while collecting a matrix entry.
  # usage: hts_tui_matrix_progress profile module alias trigger tech set org project identifier
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

  /usr/bin/clear 2>/dev/null || true
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

hts_tui_matrix_add() {
  local profile="${1:-$(hts_active_profile)}"
  local module="" alias="" trigger="" tech="" set_="" org="" project="" identifier=""

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  module="$(gum input --placeholder "module (e.g. ci, cd)")" || return 1
  [[ -n "$module" ]] || { gum style --foreground 196 "module is required."; return 1; }

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  alias="$(gum input --placeholder "alias (short name for this matrix entry)")" || return 1
  [[ -n "$alias" ]] || { gum style --foreground 196 "alias is required."; return 1; }

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  trigger="$(gum input --placeholder "trigger (Harness custom trigger identifier)")" || return 1
  [[ -n "$trigger" ]] || { gum style --foreground 196 "trigger is required."; return 1; }

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  tech="$(gum input --placeholder "tech (e.g. java, go, python)")" || return 1
  [[ -n "$tech" ]] || { gum style --foreground 196 "tech is required."; return 1; }

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  set_="$(gum input --placeholder "set (e.g. shared, exclusive)")" || return 1
  [[ -n "$set_" ]] || { gum style --foreground 196 "set is required."; return 1; }

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  org="$(gum input --placeholder "pipeline org (Harness orgIdentifier)")" || return 1
  [[ -n "$org" ]] || { gum style --foreground 196 "org is required."; return 1; }

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  project="$(gum input --placeholder "pipeline project (Harness projectIdentifier)")" || return 1
  [[ -n "$project" ]] || { gum style --foreground 196 "project is required."; return 1; }

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  identifier="$(gum input --placeholder "pipeline identifier (Harness pipelineIdentifier)")" || return 1
  [[ -n "$identifier" ]] || { gum style --foreground 196 "pipeline identifier is required."; return 1; }

  hts_tui_matrix_progress "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  gum confirm "Save this matrix entry?" || return 0

  hts_matrix_add "$profile" "$module" "$alias" "$trigger" "$tech" "$set_" "$org" "$project" "$identifier"
  gum style --foreground 212 "Saved $alias → matrices/$profile/$module.yaml"
}

hts_tui_pipelines() {
  local profile
  profile="$(hts_tui_pick_profile)" || return 1
  hts_profile_use "$profile" >/dev/null

  local action
  action="$(
    gum choose \
      "List matrix" \
      "Add / update entry" \
      "Remove entry" \
      "Back"
  )" || return 0

  case "$action" in
    "List matrix")
      local modules=() m module
      while IFS= read -r m; do [[ -n "$m" ]] && modules+=("$m"); done < <(hts_list_modules "$profile")
      if (( ${#modules[@]} == 0 )); then
        gum style "No matrices yet."
        return 0
      fi
      module="$(gum choose --header "Module" "${modules[@]}")" || return 0
      hts_matrix_list "$profile" "$module" | gum pager
      ;;
    "Add / update entry")
      hts_tui_matrix_add "$profile"
      ;;
    "Remove entry")
      local modules=() m module alias
      while IFS= read -r m; do [[ -n "$m" ]] && modules+=("$m"); done < <(hts_list_modules "$profile")
      (( ${#modules[@]} == 0 )) && { gum style "No matrices."; return 0; }
      module="$(gum choose --header "Module" "${modules[@]}")" || return 0
      alias="$(gum input --placeholder "alias to remove")" || return 0
      hts_matrix_remove "$profile" "$module" "$alias"
      ;;
    *) return 0 ;;
  esac
}

hts_tui_settings() {
  local action
  action="$(
    gum choose \
      "Set default module" \
      "Toggle open_urls" \
      "Back"
  )" || return 0

  case "$action" in
    "Set default module")
      local mod
      mod="$(gum input --placeholder "default module" --value "$(hts_default_module)")" || return 0
      hts_cfg_set_str '.defaults.module' "$mod"
      gum style --foreground 212 "default module: $mod"
      ;;
    "Toggle open_urls")
      local cur new
      if hts_open_urls_enabled; then cur=true; else cur=false; fi
      if [[ "$cur" == "true" ]]; then new=false; else new=true; fi
      hts_cfg_set_str '.defaults.open_urls' "$new"
      gum style --foreground 212 "open_urls: $new"
      ;;
    *) return 0 ;;
  esac
}
