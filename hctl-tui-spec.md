# hctl-tui

TUI orchestration layer for triggering Harness CI/CD pipeline test suites via [harness-cli (`hctl`)](https://github.com/ianmatson/harness-cli).

## What it does

One command (`hts`) to fire a configured test matrix across multiple pipelines, languages, and environments.

Default entry `type: github` **executes** the pipeline via the Harness NG execute API (correct for pipelines that normally start from GitHub webhooks). Optional `type: custom` POSTs a Harness custom webhook trigger.

hctl-tui does **not** mutate templates, commit, or push.

## Core features

- Interactive TUI (gum-powered) with guided prompts for all inputs
- Auth via existing **hctl profiles** (multi-account); TUI wraps profile list/switch/init/doctor
- Configurable pipeline aliases and test matrices (add/edit/remove via TUI or CLI)
- Tech / set / alias filters to run subsets of the matrix
- Dry-run mode (preview resolved targets without POSTing)
- Optional browser open of execution `uiUrl`s after a successful trigger

## Dependencies

- `gum` (charmbracelet) — TUI prompts and styling
- `hctl` — Harness CLI for authenticated API calls and custom webhook triggers
- `yq` — YAML read/write for config and matrices
- `zsh` — shell runtime

## File structure

```
hctl-tui/
|-- bin/hts                     # Local checkout launcher → src/hctl_tui/share
|-- src/hctl_tui/
|   |-- cli.py                  # `hts` console script (uv / pip entrypoint)
|   `-- share/
|       |-- bin/hts             # zsh CLI/TUI entry
|       `-- lib/*.sh
|-- pyproject.toml              # enables: uv tool install git+…/hctl-tui.git
|-- setup.sh                    # Optional checkout installer (gum/hctl + PATH)
|-- config.example.yaml
|-- matrices.example.yaml
`-- README.md
```

### Install via uv

```bash
uv tool install git+https://github.com/andrew-whitman/hctl-tui.git
hts init    # installs hctl (via uv) and gum when missing, then hctl auth
```

Peer deps: `zsh` (required), `hctl` + `gum` (installed by `hts init` / `hts doctor --fix-deps`). Use `hts init --skip-deps` to skip installs.

## Config structure (`~/.config/hctl-tui/`)

```
~/.config/hctl-tui/
|-- config.yaml                 # Active hctl profile pointer + defaults
`-- matrices/
    |-- default/                # Matrices for hctl profile "default"
    |   |-- ci.yaml
    |   `-- cd.yaml
    `-- sandbox/
        `-- ci.yaml
```

Auth (host, account, API key, optional org/project defaults) lives in **`~/.config/hctl/config.json`**. hctl-tui never stores secrets.

### config.yaml

```yaml
active_hctl_profile: default
defaults:
  module: ci
  open_urls: true
```

### matrices/<profile>/ci.yaml

```yaml
module: ci
entries: []
# Example entry shape:
# entries:
#   - alias: my-alias
#     type: github          # default: pipeline execute
#     tech: java
#     set: shared
#     # trigger: optional input set id (github) or custom trigger id (custom)
#     pipeline:
#       org: YOUR_ORG
#       project: YOUR_PROJECT
#       identifier: YOUR_PIPELINE_ID
```

`type: github` executes the pipeline. `type: custom` uses `trigger` as `triggerIdentifier`. Org/project/pipeline come from the entry; account and API key come from the selected hctl profile.

## TUI flow

Flat home menu (active hctl profile used by default — no per-action picker):

- Run test suite → module (skipped if one) → Run / Dry-run / Filter then run
- Add pipeline → alias, org, project, pipeline id, trigger id, set, optional branch
- List pipelines / Remove pipeline (alias chooser)
- Profiles / Settings (looping submenus)

## CLI (non-interactive)

```bash
# Interactive TUI (default when stdin is a TTY and no subcommand)
hts

# Run matrix
hts run --module ci [--tech java] [--set shared] [--alias a1,a2] [--dry-run] [--profile NAME] [--no-open]

# Profiles (thin wrappers)
hts profile list
hts profile use NAME
hts profile init [--name NAME]   # interactive gum, or flags via env/hctl

# Matrix CRUD
hts matrix list --module ci [--profile NAME]
hts matrix add --module ci --alias A --trigger T --tech TECH --set SET \
  --pipeline-org ORG --pipeline-project PROJ --pipeline-id ID [--profile NAME]
hts matrix remove --module ci --alias A [--profile NAME]

# Health
hts doctor
```

## Runner contract

1. Resolve active hctl profile (`--profile`, else `config.yaml` → `active_hctl_profile`, else hctl current).
2. Load `matrices/<profile>/<module>.yaml`; apply `--tech` / `--set` / `--alias` filters.
3. For each matching entry:
   - `type: github` → `hctl pipeline-execute post-pipeline-execute-with-input-set-yaml`
     (`POST /pipeline/api/pipeline/execute/{identifier}`)
   - `type: custom` → `POST /gateway/pipeline/api/webhook/custom/v2` with triggerIdentifier
4. Collect success/fail; print a summary table.
5. If `open_urls` / not `--no-open`, open returned `uiUrl`s (macOS `open`, Linux `xdg-open`).
6. `--dry-run`: print resolved targets and `hctl … --dry-run --curl` without POSTing.

## Design principles

- Zero-config start: works after one `hctl` profile exists; empty matrix prompts to add entries
- TUI first, CLI second: all features accessible via both
- Matrices are portable YAML; share across a team by copying files
- No secrets in hctl-tui config — auth always delegated to `hctl`
