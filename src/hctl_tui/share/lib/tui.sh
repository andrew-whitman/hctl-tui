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
  hts_gum input --placeholder "$msg" --value "" </dev/null >/dev/null || true
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
  # Capture gum's answer via a temp file so $(...) never races the TUI against
  # gum's stdin/"value from stdin" behavior. Stdin is /dev/null (not a tty), so
  # gum will open /dev/tty for the interactive UI itself.
  local out ec=0
  out="$(hts_mktemp gum-in)" || return 1
  if ! hts_gum input --value="" "$@" </dev/null >"$out"; then
    ec=$?
    hts_rm -f "$out"
    return "$ec"
  fi
  /bin/cat "$out"
  hts_rm -f "$out"
}

# Reliable line prompts for multi-field forms (no gum $(...) shifting).
# usage: hts_tty_ask <label> [required=1]
hts_tty_ask() {
  local label="$1" required="${2:-1}" val=""
  while true; do
    print -n -- "$label: " >/dev/tty 2>/dev/null || print -n -- "$label: "
    IFS= read -r val </dev/tty || return 1
    val="$(hts_trim "$val")"
    if [[ -n "$val" || "$required" != "1" ]]; then
      print -- "$val"
      return 0
    fi
    print -- "(required)" >/dev/tty 2>/dev/null || print -- "(required)"
  done
}

# Edit prompt: blank keeps current. For optional fields, "-" clears.
# usage: hts_tty_ask_keep <label> <current> [required=1]
# Prints the value to use (never empty when required unless current was set).
hts_tty_ask_keep() {
  local label="$1" current="${2:-}" required="${3:-1}" val=""
  local shown="${current:-(empty)}"
  while true; do
    print -n -- "$label [$shown]: " >/dev/tty 2>/dev/null || print -n -- "$label [$shown]: "
    IFS= read -r val </dev/tty || return 1
    val="$(hts_trim "$val")"
    if [[ -z "$val" ]]; then
      print -- "$current"
      return 0
    fi
    if [[ "$val" == "-" ]]; then
      if [[ "$required" == "1" ]]; then
        print -- "(required — enter a value, or leave blank to keep)" >/dev/tty 2>/dev/null \
          || print -- "(required — enter a value, or leave blank to keep)"
        continue
      fi
      print -- ""
      return 0
    fi
    print -- "$val"
    return 0
  done
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
        "Edit pipeline" \
        "List pipelines" \
        "Remove pipeline" \
        "Profiles" \
        "Settings" \
        "Quit"
    )" || { hts_tui_leave; trap - EXIT INT TERM; return 0; }

    case "$choice" in
      "Run test suite")   hts_tui_run_suite || true ;;
      "Add pipeline")     hts_tui_matrix_add || true ;;
      "Edit pipeline")    hts_tui_matrix_edit || true ;;
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

  local module add_alias add_org add_project add_pipeline add_trigger add_set add_branch
  module="$(hts_default_module)"

  hts_tui_clear
  {
    print -- "Add pipeline"
    print -- "profile=$profile  module=$module"
    print -- "Enter one field per line (branch optional)."
  } | hts_tui_show
  print -- "" >/dev/tty 2>/dev/null || print -- ""

  # Plain /dev/tty reads — gum input under $(...) was shifting field values.
  add_alias="$(hts_tty_ask "1/7 Alias")" || return 0
  add_org="$(hts_tty_ask "2/7 Org")" || return 0
  add_project="$(hts_tty_ask "3/7 Project")" || return 0
  add_pipeline="$(hts_tty_ask "4/7 Pipeline")" || return 0
  add_trigger="$(hts_tty_ask "5/7 Trigger (GitHub webhook id)")" || return 0
  add_branch="$(hts_tty_ask "6/7 Branch (e.g. main; resolves <+trigger.branch>)" 0)" || return 0
  add_set="$(hts_tty_ask "7/7 Set")" || return 0

  hts_tui_clear
  {
    print -- "Confirm — will save EXACTLY these fields:"
    print -- "  alias:    $add_alias"
    print -- "  org:      $add_org"
    print -- "  project:  $add_project"
    print -- "  pipeline: $add_pipeline"
    print -- "  trigger:  $add_trigger"
    print -- "  branch:   ${add_branch:-(none)}"
    print -- "  set:      $add_set"
  } | hts_tui_show
  print -- "" >/dev/tty 2>/dev/null || print -- ""
  hts_gum confirm "Save this entry?" || return 0

  hts_matrix_add "$profile" "$module" "$add_alias" "$add_trigger" "java" "$add_set" \
    "$add_org" "$add_project" "$add_pipeline" "github" "$add_branch" >/dev/null

  # Show what was actually persisted (catches write/mapping bugs immediately).
  local path saved
  path="$(hts_matrix_path "$profile" "$module")"
  saved="$(
    HTS_CHK_PATH="$path" HTS_CHK_ALIAS="$add_alias" hts_python <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.exit(0)
path, alias = os.environ["HTS_CHK_PATH"], os.environ["HTS_CHK_ALIAS"]
data = yaml.safe_load(open(path)) or {}
for e in data.get("entries") or []:
    if (e or {}).get("alias") == alias:
        p = e.get("pipeline") or {}
        print("org={} project={} pipeline={} trigger={} branch={} set={}".format(
            p.get("org") or "",
            p.get("project") or "",
            p.get("identifier") or "",
            e.get("trigger") or "",
            e.get("branch") or "(none)",
            e.get("set") or "",
        ))
        break
PY
  )"

  hts_tui_clear
  hts_gum_box \
    "Saved: $add_alias" \
    "${saved:-$add_org / $add_project / $add_pipeline}"
  hts_tui_pause "Enter — done"
}

hts_tui_pick_alias() {
  # usage: hts_tui_pick_alias profile module header
  # Prints selected alias. Choices show "alias — org/project/pipeline".
  local profile="$1" module="$2" header="${3:-Pick pipeline}"
  local labels=() label alias
  while IFS= read -r label; do
    [[ -n "$label" ]] && labels+=("$label")
  done < <(
    hts_matrix_entries_json "$profile" "$module" | hts_python -c '
import json,sys
for e in json.load(sys.stdin):
    al = e.get("alias") or ""
    if not al:
        continue
    p = e.get("pipeline") or {}
    pipe = "{}/{}/{}".format(p.get("org") or "-", p.get("project") or "-", p.get("identifier") or "-")
    br = e.get("branch") or ""
    extra = "  branch="+br if br else ""
    print("{} — {}{}".format(al, pipe, extra))
'
  )
  if (( ${#labels[@]} == 0 )); then
    return 1
  fi
  hts_tui_clear
  label="$(hts_gum_pick --height="$(hts_gum_choose_height)" --header "$header" "${labels[@]}")" || return 1
  # alias is everything before " — "
  alias="${label%% — *}"
  print -- "$alias"
}

hts_tui_matrix_edit() {
  local profile="${1:-}"
  if [[ -z "$profile" ]]; then
    profile="$(hts_tui_profile)" || return 1
  fi
  hts_profile_use "$profile" >/dev/null

  local module alias entry
  local cur_alias cur_org cur_project cur_pipeline cur_trigger cur_set cur_branch cur_tech cur_type
  local cur_repo cur_connector
  local new_alias new_org new_project new_pipeline new_trigger new_set new_branch

  hts_tui_clear
  module="$(hts_tui_pick_module "$profile" "Edit · module")" || {
    hts_gum_box "No pipelines yet."
    hts_tui_pause
    return 0
  }

  alias="$(hts_tui_pick_alias "$profile" "$module" "Edit · pick pipeline")" || {
    hts_gum_box "Matrix is empty."
    hts_tui_pause
    return 0
  }

  entry="$(hts_matrix_get_entry_json "$profile" "$module" "$alias")" || {
    hts_gum_box_error "Could not load: $alias"
    hts_tui_pause
    return 0
  }

  # Unpack fields
  eval "$(
    print -- "$entry" | hts_python -c '
import json,sys,shlex
e=json.load(sys.stdin)
p=e.get("pipeline") or {}
def q(k,v):
    print("{}={}".format(k, shlex.quote(str(v or ""))))
q("cur_alias", e.get("alias"))
q("cur_type", e.get("type") or "github")
q("cur_tech", e.get("tech") or "java")
q("cur_set", e.get("set") or "")
q("cur_trigger", e.get("trigger") or "")
q("cur_branch", e.get("branch") or "")
q("cur_repo", e.get("repo") or "")
q("cur_connector", e.get("connector") or "")
q("cur_org", p.get("org") or "")
q("cur_project", p.get("project") or "")
q("cur_pipeline", p.get("identifier") or "")
'
  )"

  hts_tui_clear
  {
    print -- "Edit pipeline — leave blank to keep current value"
    print -- "Optional: type - on Branch to clear it"
    print -- "profile=$profile  module=$module"
    print -- ""
    print -- "Current: $cur_alias"
    print -- "  $cur_org / $cur_project / $cur_pipeline"
    print -- "  trigger=${cur_trigger:-(none)}  branch=${cur_branch:-(none)}  set=${cur_set:-(none)}"
  } | hts_tui_show
  print -- "" >/dev/tty 2>/dev/null || print -- ""

  new_alias="$(hts_tty_ask_keep "1/7 Alias" "$cur_alias")" || return 0
  new_org="$(hts_tty_ask_keep "2/7 Org" "$cur_org")" || return 0
  new_project="$(hts_tty_ask_keep "3/7 Project" "$cur_project")" || return 0
  new_pipeline="$(hts_tty_ask_keep "4/7 Pipeline" "$cur_pipeline")" || return 0
  new_trigger="$(hts_tty_ask_keep "5/7 Trigger" "$cur_trigger")" || return 0
  new_branch="$(hts_tty_ask_keep "6/7 Branch (- to clear)" "$cur_branch" 0)" || return 0
  new_set="$(hts_tty_ask_keep "7/7 Set" "$cur_set")" || return 0

  hts_tui_clear
  {
    print -- "Confirm — will save:"
    print -- "  alias:    $new_alias"
    print -- "  org:      $new_org"
    print -- "  project:  $new_project"
    print -- "  pipeline: $new_pipeline"
    print -- "  trigger:  $new_trigger"
    print -- "  branch:   ${new_branch:-(none)}"
    print -- "  set:      $new_set"
  } | hts_tui_show
  print -- "" >/dev/tty 2>/dev/null || print -- ""
  hts_gum confirm "Save changes?" || return 0

  hts_matrix_update "$profile" "$module" "$alias" "$new_alias" "$new_trigger" \
    "${cur_tech:-java}" "$new_set" "$new_org" "$new_project" "$new_pipeline" \
    "${cur_type:-github}" "$new_branch" "$cur_repo" "$cur_connector" >/dev/null || {
    hts_gum_box_error "Update failed"
    hts_tui_pause
    return 0
  }

  hts_tui_clear
  hts_gum_box "Updated: $new_alias" "$new_org / $new_project / $new_pipeline"
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
  local profile module alias
  profile="$(hts_tui_profile)" || return 1
  hts_profile_use "$profile" >/dev/null

  hts_tui_clear
  module="$(hts_tui_pick_module "$profile" "Remove · module")" || {
    hts_gum_box "No pipelines yet."
    hts_tui_pause
    return 0
  }

  alias="$(hts_tui_pick_alias "$profile" "$module" "Remove · pick pipeline")" || {
    hts_gum_box "Matrix is empty."
    hts_tui_pause
    return 0
  }

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
