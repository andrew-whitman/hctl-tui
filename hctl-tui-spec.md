# hctl-tui

TUI orchestration layer for triggering Harness CI/CD pipeline test suites via [harness-cli (`hctl`)](https://github.com/ianmatson/harness-cli).

## What it does

One command (`hts`) to fire a configured test matrix across multiple pipelines, languages, and environments.

Default entry `type: github` **fetches** the GitHub/webhook trigger (`hctl triggers get-trigger`), resolves `inputYaml` / `<+trigger.*>`, converts PR builds to branch, and **executes** the pipeline via the Harness NG execute API with `--body @file`. Optional `type: custom` POSTs a Harness custom webhook trigger.

hctl-tui does **not** mutate templates, commit, or push.

## Core features

- Interactive TUI (gum-powered) with guided prompts for all inputs
- Auth via existing **hctl profiles** (multi-account); TUI wraps profile list/switch/init/doctor
- Configurable pipeline aliases and test matrices (add/edit/remove via TUI or CLI)
- Tech / set / alias filters to run subsets of the matrix
- Dry-run mode (preview resolved targets without POSTing)
- Optional browser open of execution `uiUrl`s after a successful trigger
- Optional **watch** after run: poll Harness until executions reach a terminal status
- Optional **log fetch** into `./hts-logs/<alias>/<planExecutionId>/` (zip + extracted NDJSON)

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
#     # trigger: github webhook trigger id (required for github execute)
#     # branch is prompted at run time (or hts run --branch) — not stored here
#     # repo / connector: optional overrides for --repo-identifier / connectorRef
#     pipeline:
#       org: YOUR_ORG
#       project: YOUR_PROJECT
#       identifier: YOUR_PIPELINE_ID
```

`type: github` fetches the webhook trigger (`hctl triggers get-trigger`), resolves `inputYaml`, and executes the pipeline. `type: custom` uses `trigger` as `triggerIdentifier` for the custom webhook API. Org/project/pipeline come from the entry; account and API key come from the selected hctl profile. At run time you choose the **application/source git branch** (the repo under test) per pipeline — or `hts run --branch` for all. This is not the pipeline-template / Git Experience branch.

Interactive branch prompts are single-line TTY reads (answers stay in scrollback). When history exists for that pipeline, a numbered recent list is printed above the prompt; Enter accepts the default (most recent), or type a number / any branch name. History lives in `~/.config/hctl-tui/branch-history.yaml`, keyed by profile/module/org/project/pipeline id (not matrix alias), and is updated after a successful execute. It is not part of the matrix file. Opt in with `hts export|import --with-branch-history` (TUI confirm) to copy/merge it between machines.

## TUI flow

Flat home menu (active hctl profile used by default — no per-action picker):

- Run test suite → module (skipped if one) → Run all / Dry-run all / **Select pipelines** (checklist) / Filter then run
  - After a real (non-dry-run) suite with at least one `planExecutionId`: prompt **Watch executions?** then **Fetch logs?**
- Add pipeline → module (pick existing or New module…) → alias, org, project, pipeline id, trigger id, set
- List pipelines / Remove pipeline (alias chooser)
- Export / Import → share matrices + redacted profile stubs across machines
- Profiles / Settings (looping submenus)
- **Help** → short in-TUI how-to (navigation, run flow, branches)

**Esc** on any gum chooser/input (or line prompt) cancels and returns to the home menu. Esc on the home menu quits.

**Select pipelines:** gum multi-select checklist (`space` toggle, `enter` confirm). Runs only the checked aliases (same as `hts run --alias a,b`).

## CLI (non-interactive)

```bash
# Interactive TUI (default when stdin is a TTY and no subcommand)
hts

# Run matrix
hts run --module ci [--tech java] [--set shared] [--alias a1,a2] [--dry-run] [--profile NAME] [--no-open]
hts run --module ci --watch [--fetch-logs] [--watch-interval 10] [--watch-timeout 3600]

# Download logs for one execution (PWD-relative ./hts-logs/ by default)
hts logs --execution-id ID --pipeline-org ORG --pipeline-project PROJ --pipeline-id ID \
  [--alias NAME] [--profile NAME] [--out DIR] [--force]

# Profiles (thin wrappers)
hts profile list
hts profile use NAME
hts profile init [--name NAME]   # interactive gum, or flags via env/hctl

# Matrix CRUD
hts matrix list --module ci [--profile NAME]
hts matrix add --module ci --alias A --trigger T --tech TECH --set SET \
  --pipeline-org ORG --pipeline-project PROJ --pipeline-id ID [--profile NAME]
hts matrix remove --module ci --alias A [--profile NAME]

# Export / import (portable bundle; API keys redacted by default)
hts export [--out DIR] [--profile NAME|all] [--include-secrets] [--no-config] [--with-branch-history]
hts import PATH [--as NAME] [--force] [--with-config] [--no-profiles] [--with-branch-history]

# Health
hts doctor
```

## Export bundle format

Directory layout produced by `hts export`:

```
manifest.yaml                 # format: hctl-tui-export, format_version: 1
matrices/<profile>/*.yaml     # copied matrix modules
profiles/<profile>.json       # host/account/org/project; api_key empty unless --include-secrets
hctl-tui-config.yaml          # optional local defaults (omit with --no-config)
branch-history.yaml           # optional recent branches (--with-branch-history)
```

`hts import` merges matrices into `~/.config/hctl-tui/matrices/` (skip existing unless `--force`), optionally merges hctl profile stubs (no blank key overwrite), and remaps a single-profile bundle with `--as NAME`. Pass `--with-branch-history` to merge `branch-history.yaml` (incoming branches preferred; `--force` replaces per-pipeline keys).

## Runner contract

1. Resolve active hctl profile (`--profile`, else `config.yaml` → `active_hctl_profile`, else hctl current).
2. Load `matrices/<profile>/<module>.yaml`; apply `--tech` / `--set` / `--alias` filters.
3. For each matching entry:
   - `type: github` (default):
     1. `hctl triggers get-trigger` (org/project/`--target-identifier` pipeline + `--trigger-identifier`)
     2. Prefer inline `inputYaml` (replace `<+trigger.*>` with the run-time branch / repo / connector; convert PR build → branch); else fall back to `inputSetRefs` → `--input-set-identifiers` (matrix `input_set:` can override)
     3. Prompt for a git branch per github entry (single-line TTY with optional numbered recent list, or `hts run --branch` for all); then `hctl pipeline-execute post-pipeline-execute-with-input-set-yaml` with `--body @file` and/or `--input-set-identifiers`, plus `--branch`, optional `--repo-identifier` / `connectorRef`. Record the branch in local history on SUCCESS.
   - `type: custom` → `POST /gateway/pipeline/api/webhook/custom/v2` with triggerIdentifier
4. Collect success/fail; print a summary table. For each successful fire, retain `planExecutionId` (when present) for optional watch/logs.
5. If `open_urls` / not `--no-open`, open returned `uiUrl`s (macOS `open`, Linux `xdg-open`).
6. If `--watch`: poll `get-execution-detail-v2` for each captured execution until terminal status (or `--watch-timeout`). With `--fetch-logs`, download full-pipeline logs via Log Service `blob/download` into `./hts-logs/<alias>/<planExecutionId>/` (`meta.json`, `logs.zip`, `extracted/`). Override root with `HTS_LOGS_DIR` or `hts logs --out`.
7. `--dry-run`: preflight each entry (auth, fetch trigger, resolve inputs) without POSTing; print one `SUCCESS` / `FAIL` line per alias; no watch/logs.

## Design principles

- Zero-config start: works after one `hctl` profile exists; empty matrix prompts to add entries
- TUI first, CLI second: all features accessible via both
- Matrices are portable YAML; share across a team by copying files
- No secrets in hctl-tui config — auth always delegated to `hctl`
